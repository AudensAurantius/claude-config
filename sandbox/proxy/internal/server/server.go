// Package server implements the SNI-passthrough accept loop. For each
// inbound connection it peeks the ClientHello, checks the SNI against
// the allowlist, dials the upstream using the SNI itself (defeating
// SO_ORIGINAL_DST lies), and splices the two pipes via io.Copy in both
// directions.
package server

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/AudensAurantius/claude-config/sandbox/proxy/internal/policy"
	"github.com/AudensAurantius/claude-config/sandbox/proxy/internal/sniff"
)

// systemd SD_LISTEN_FDS_START is conventionally 3.
const sdListenFDsStart = 3

// DialFunc is the upstream dial hook. Defaults to the stdlib dialer.
// Tests inject custom resolvers; production paths leave it nil.
type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

// Config controls the listener, policy, and dial timing knobs.
type Config struct {
	ListenAddr  string        // e.g. 127.0.0.1:8443; ignored when ListenFDs is true
	ListenFDs   bool          // adopt fd 3 from systemd socket activation
	PeekTimeout time.Duration // max time to wait for ClientHello bytes
	DialTimeout time.Duration // upstream connect timeout
	DefaultPort int           // port used when SNI has no implicit port; we always splice 443
	Logger      *slog.Logger
	Policies    *policy.PolicySet
	DialContext DialFunc // optional; default = (&net.Dialer{Timeout: DialTimeout}).DialContext
}

// Serve runs the accept loop until ctx is cancelled or the listener
// errors fatally. Returns nil on clean shutdown.
func Serve(ctx context.Context, cfg Config) error {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.PeekTimeout <= 0 {
		cfg.PeekTimeout = 5 * time.Second
	}
	if cfg.DialTimeout <= 0 {
		cfg.DialTimeout = 5 * time.Second
	}
	if cfg.DefaultPort == 0 {
		cfg.DefaultPort = 443
	}
	listener, err := bindListener(cfg)
	if err != nil {
		return err
	}
	defer listener.Close()

	active := newConnSet()
	go func() {
		<-ctx.Done()
		_ = listener.Close()
		active.closeAll()
	}()

	var wg sync.WaitGroup
	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) || ctx.Err() != nil {
				wg.Wait()
				return nil
			}
			cfg.Logger.Error("accept failed", "err", err)
			wg.Wait()
			return err
		}
		wg.Add(1)
		active.add(conn)
		go func(c net.Conn) {
			defer wg.Done()
			defer active.remove(c)
			handleConn(ctx, cfg, c, active)
		}(conn)
	}
}

// connSet tracks open connections so shutdown can force-close them.
type connSet struct {
	mu    sync.Mutex
	conns map[net.Conn]struct{}
}

func newConnSet() *connSet { return &connSet{conns: make(map[net.Conn]struct{})} }

func (s *connSet) add(c net.Conn) {
	s.mu.Lock()
	s.conns[c] = struct{}{}
	s.mu.Unlock()
}

func (s *connSet) remove(c net.Conn) {
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
}

func (s *connSet) closeAll() {
	s.mu.Lock()
	for c := range s.conns {
		_ = c.Close()
	}
	s.mu.Unlock()
}

func bindListener(cfg Config) (net.Listener, error) {
	if cfg.ListenFDs {
		fd, ok := systemdListenFD(cfg.Logger)
		if !ok {
			return nil, fmt.Errorf("--listen-fds set but no systemd-inherited fd present")
		}
		f := os.NewFile(uintptr(fd), "systemd-socket")
		l, err := net.FileListener(f)
		_ = f.Close()
		if err != nil {
			return nil, fmt.Errorf("adopt systemd fd: %w", err)
		}
		cfg.Logger.Info("adopted systemd-inherited fd", "fd", fd)
		return l, nil
	}
	if cfg.ListenAddr == "" {
		return nil, fmt.Errorf("no listen address configured and --listen-fds not set")
	}
	l, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return nil, fmt.Errorf("bind %s: %w", cfg.ListenAddr, err)
	}
	cfg.Logger.Info("listening on TCP", "addr", cfg.ListenAddr)
	return l, nil
}

func systemdListenFD(log *slog.Logger) (int, bool) {
	pidStr := os.Getenv("LISTEN_PID")
	fdsStr := os.Getenv("LISTEN_FDS")
	if pidStr == "" || fdsStr == "" {
		return 0, false
	}
	pid, err := strconv.Atoi(pidStr)
	if err != nil || pid != os.Getpid() {
		log.Warn("LISTEN_PID mismatch; ignoring inherited fds", "pid", pidStr, "self", os.Getpid())
		return 0, false
	}
	n, err := strconv.Atoi(fdsStr)
	if err != nil || n != 1 {
		log.Warn("LISTEN_FDS not exactly 1; ignoring", "count", fdsStr)
		return 0, false
	}
	return sdListenFDsStart, true
}

// handleConn implements the full peek → match → dial → splice flow for
// one inbound TCP connection. It closes the inbound connection on exit.
// If the upstream connect succeeds, the upstream conn is added to active
// so shutdown can force-close it too.
func handleConn(ctx context.Context, cfg Config, in net.Conn, active *connSet) {
	defer in.Close()
	remote := in.RemoteAddr().String()

	info, prefix, err := sniff.PeekClientHello(in, cfg.PeekTimeout)
	if err != nil && !sniff.HandshakeAborted(err) {
		// We may have captured info anyway on a "remote error" path; let
		// the nil-check below decide.
		cfg.Logger.Debug("peek returned err", "remote", remote, "err", err)
	}
	if info == nil || info.ServerName == "" {
		cfg.Logger.Warn("no SNI present; dropping", "remote", remote)
		return
	}

	port := cfg.DefaultPort
	alias, ok := cfg.Policies.Match(info.ServerName, port)
	if !ok {
		cfg.Logger.Warn("denied: SNI not in allowlist",
			"remote", remote, "sni", info.ServerName, "port", port)
		return
	}

	dial := cfg.DialContext
	if dial == nil {
		dial = (&net.Dialer{Timeout: cfg.DialTimeout}).DialContext
	}
	upstream, err := dial(ctx, "tcp",
		net.JoinHostPort(info.ServerName, strconv.Itoa(port)))
	if err != nil {
		cfg.Logger.Warn("upstream dial failed",
			"remote", remote, "sni", info.ServerName, "port", port,
			"alias", alias, "err", err)
		return
	}
	defer upstream.Close()
	active.add(upstream)
	defer active.remove(upstream)

	cfg.Logger.Info("spliced",
		"remote", remote,
		"sni", info.ServerName,
		"port", port,
		"alias", alias,
		"upstream", upstream.RemoteAddr().String(),
	)

	// Replay the buffered ClientHello bytes to the upstream first, then
	// fall through to bidirectional copy.
	if len(prefix) > 0 {
		if _, err := upstream.Write(prefix); err != nil {
			cfg.Logger.Warn("upstream replay failed", "err", err)
			return
		}
	}
	splice(in, upstream, cfg.Logger)
}

// splice runs io.Copy in both directions until either side closes.
// CloseWrite (half-close) is used when available so an EOF from one
// peer cleanly flushes the other side's pending bytes.
func splice(a, b net.Conn, log *slog.Logger) {
	var wg sync.WaitGroup
	wg.Add(2)
	go copyHalf(&wg, a, b, log)
	go copyHalf(&wg, b, a, log)
	wg.Wait()
}

func copyHalf(wg *sync.WaitGroup, dst, src net.Conn, log *slog.Logger) {
	defer wg.Done()
	_, err := io.Copy(dst, src)
	if err != nil && !errors.Is(err, net.ErrClosed) && !errors.Is(err, io.EOF) {
		log.Debug("splice direction ended", "err", err)
	}
	// Half-close dst's write side so the other goroutine sees EOF after
	// flushing any remaining bytes. Falls back to a full close for
	// connections that don't expose CloseWrite (e.g. tls.Conn wrappers).
	type closeWriter interface{ CloseWrite() error }
	if cw, ok := dst.(closeWriter); ok {
		_ = cw.CloseWrite()
	} else {
		_ = dst.Close()
	}
}

// Compile-time assertion: tls.Conn satisfies net.Conn, which is what we
// embed everywhere. (Sanity check, not used at runtime.)
var _ net.Conn = (*tls.Conn)(nil)
