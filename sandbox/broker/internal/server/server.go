// Package server implements the UDS accept loop with SO_PEERCRED-based
// peer authentication and systemd socket-activation adoption. Parity
// reference: src/claude_config/egress_broker/server.py.
package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strconv"
	"sync"
	"syscall"

	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/handler"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/wire"
)

// systemd SD_LISTEN_FDS_START is conventionally 3.
const sdListenFDsStart = 3

// Config controls the listener and peer-auth gate.
type Config struct {
	SocketPath       string // empty = require socket activation
	ExpectedPeerUID  int
	Backlog          int
	Logger           *slog.Logger
	SocketMode       os.FileMode // mode set after binding; defaults to 0660
}

// Serve runs the accept loop until ctx is cancelled or the listener errors.
func Serve(ctx context.Context, cfg Config, h *handler.Handler) error {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.SocketMode == 0 {
		cfg.SocketMode = 0o660
	}
	listener, err := bindListener(cfg)
	if err != nil {
		return err
	}
	defer listener.Close()

	// Close the listener when ctx is cancelled so Accept() returns.
	go func() {
		<-ctx.Done()
		_ = listener.Close()
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
		go func(c net.Conn) {
			defer wg.Done()
			defer c.Close()
			if err := handleConnection(c, cfg, h); err != nil {
				cfg.Logger.Warn("connection handler error", "err", err)
			}
		}(conn)
	}
}

// bindListener returns a *net.UnixListener — either adopted from
// systemd or freshly bound.
func bindListener(cfg Config) (net.Listener, error) {
	if fd, ok := systemdListenFD(cfg.Logger); ok {
		f := os.NewFile(uintptr(fd), "systemd-socket")
		l, err := net.FileListener(f)
		// FileListener dup's the fd; close the wrapper.
		_ = f.Close()
		if err != nil {
			return nil, fmt.Errorf("adopt systemd fd: %w", err)
		}
		cfg.Logger.Info("adopted systemd-inherited fd", "fd", fd)
		return l, nil
	}
	if cfg.SocketPath == "" {
		return nil, fmt.Errorf("no socket path configured and no systemd-inherited fd present")
	}
	if _, err := os.Stat(cfg.SocketPath); err == nil {
		_ = os.Remove(cfg.SocketPath)
	}
	l, err := net.Listen("unix", cfg.SocketPath)
	if err != nil {
		return nil, fmt.Errorf("bind %s: %w", cfg.SocketPath, err)
	}
	if err := os.Chmod(cfg.SocketPath, cfg.SocketMode); err != nil {
		_ = l.Close()
		return nil, fmt.Errorf("chmod %s: %w", cfg.SocketPath, err)
	}
	cfg.Logger.Info("listening on UDS", "path", cfg.SocketPath, "mode", fmt.Sprintf("%#o", cfg.SocketMode))
	return l, nil
}

// systemdListenFD reports whether systemd passed us a socket fd and
// returns its number (typically 3).
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

func handleConnection(conn net.Conn, cfg Config, h *handler.Handler) error {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return fmt.Errorf("expected *net.UnixConn, got %T", conn)
	}
	peerUID, err := peerUID(uc)
	if err != nil {
		return fmt.Errorf("peer-uid lookup: %w", err)
	}
	if peerUID != cfg.ExpectedPeerUID {
		cfg.Logger.Warn("rejecting connection: peer uid mismatch",
			"peer_uid", peerUID, "expected", cfg.ExpectedPeerUID)
		return nil
	}

	raw, err := wire.ReadFrame(conn)
	if err != nil {
		sendError(conn, "bad-request", err.Error())
		return err
	}
	req, err := wire.ParseRequest(raw)
	if err != nil {
		sendError(conn, "bad-request", err.Error())
		return err
	}
	resp := h.Handle(req)
	frame, err := wire.EncodeFrame(resp)
	if err != nil {
		return fmt.Errorf("encode response: %w", err)
	}
	if _, err := conn.Write(frame); err != nil {
		return fmt.Errorf("write response: %w", err)
	}
	return nil
}

func peerUID(uc *net.UnixConn) (int, error) {
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, err
	}
	var ucred *syscall.Ucred
	var sockErr error
	err = raw.Control(func(fd uintptr) {
		ucred, sockErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	})
	if err != nil {
		return 0, err
	}
	if sockErr != nil {
		return 0, sockErr
	}
	return int(ucred.Uid), nil
}

func sendError(conn net.Conn, code, message string) {
	frame, err := wire.EncodeFrame(wire.EncodeError(code, message))
	if err != nil {
		return
	}
	_, _ = conn.Write(frame)
}
