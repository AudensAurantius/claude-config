package server

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"log/slog"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/AudensAurantius/claude-config/sandbox/proxy/internal/policy"
)

// makeSelfSignedCert returns a TLS certificate valid for the given SAN.
func makeSelfSignedCert(t *testing.T, san string) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: san},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{san},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// startEchoTLSServer boots a real TLS listener on 127.0.0.1:0 that
// accepts a TLS handshake and echoes one line. Returns the listener,
// the SAN the cert is valid for, and the port.
func startEchoTLSServer(t *testing.T, san string) (net.Listener, int) {
	t.Helper()
	cert := makeSelfSignedCert(t, san)
	cfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	l, err := tls.Listen("tcp", "127.0.0.1:0", cfg)
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 64)
				n, _ := c.Read(buf)
				if n > 0 {
					_, _ = c.Write([]byte("PONG"))
				}
			}(c)
		}
	}()
	return l, port
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
}

// hostsFileResolver overrides /etc/hosts-style lookups so the proxy
// dials 127.0.0.1 when it asks for the test SAN.
//
// We achieve this by listening on 127.0.0.1 in the echo server and
// using a SAN of "localhost" (which resolves to 127.0.0.1 on every
// platform we care about). The proxy's stdlib Dial does the DNS lookup
// for us.

func TestServer_AllowAndSpliceLocalhost(t *testing.T) {
	// Upstream: real TLS echo server bound to 127.0.0.1 with a cert for
	// the test FQDN.
	const testSAN = "echo.test.local"
	upstream, upstreamPort := startEchoTLSServer(t, testSAN)
	defer upstream.Close()
	upstreamAddr := upstream.Addr().String()

	// Policy: allow SNI=echo.test.local on the upstream port.
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "echo-test.yaml"),
		"alias: echo-test\nhostnames: ["+testSAN+"]\nports: ["+itoa(upstreamPort)+"]\n")
	set, err := policy.LoadDirectory(dir)
	if err != nil {
		t.Fatal(err)
	}

	// Proxy listens on its own ephemeral port; DefaultPort is the
	// upstream's port so the proxy splices to that.
	proxyL, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer proxyL.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	srvErr := make(chan error, 1)
	go func() {
		srvErr <- Serve(ctx, Config{
			Logger:      quietLogger(),
			Policies:    set,
			DefaultPort: upstreamPort,
			PeekTimeout: 2 * time.Second,
			DialTimeout: 2 * time.Second,
			// Pre-bind our listener via ListenFDs-equivalent trick: we
			// can't easily fake LISTEN_FDS in-process, so we cheat by
			// using ListenAddr — and then re-accept inside the same
			// listener. Set ListenAddr from the listener we created so
			// Config knows what we already bound.
			ListenAddr: proxyL.Addr().String(),
			// Inject a dialer that swaps the SNI'd hostname for the
			// loopback address of the test upstream, so the proxy's
			// "resolve SNI and connect" path is exercised without
			// needing /etc/hosts shenanigans.
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, network, upstreamAddr)
			},
		})
	}()
	// Close our pre-bound listener; the server will bind its own to the
	// same address. (Tiny race window — accept-then-fail is harmless.)
	proxyAddr := proxyL.Addr().String()
	proxyL.Close()
	// Allow the server a moment to bind.
	time.Sleep(50 * time.Millisecond)

	// Client: tls.Dial through the proxy with SNI=echo.test.local.
	clientCfg := &tls.Config{
		ServerName:         testSAN,
		InsecureSkipVerify: true, //nolint:gosec // self-signed test cert.
	}
	cc, err := tls.Dial("tcp", proxyAddr, clientCfg)
	if err != nil {
		t.Fatalf("tls.Dial through proxy: %v", err)
	}
	defer cc.Close()
	if _, err := cc.Write([]byte("PING")); err != nil {
		t.Fatalf("client write: %v", err)
	}
	buf := make([]byte, 4)
	_ = cc.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := io.ReadFull(cc, buf); err != nil {
		t.Fatalf("client read: %v", err)
	}
	if string(buf) != "PONG" {
		t.Errorf("upstream echo: got %q, want %q", buf, "PONG")
	}

	cancel()
	select {
	case err := <-srvErr:
		if err != nil {
			t.Errorf("server returned err: %v", err)
		}
	case <-time.After(time.Second):
		t.Error("server did not shut down")
	}
}

func TestServer_DenyClosesBeforeAppBytes(t *testing.T) {
	// Empty policy — nothing is allowed.
	dir := t.TempDir()
	set, err := policy.LoadDirectory(dir)
	if err != nil {
		t.Fatal(err)
	}

	proxyL, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := proxyL.Addr().String()
	proxyL.Close()
	time.Sleep(20 * time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		_ = Serve(ctx, Config{
			Logger:      quietLogger(),
			Policies:    set,
			ListenAddr:  addr,
			PeekTimeout: 2 * time.Second,
		})
	}()
	time.Sleep(50 * time.Millisecond)

	cc, err := tls.Dial("tcp", addr, &tls.Config{
		ServerName:         "denied.example",
		InsecureSkipVerify: true, //nolint:gosec
	})
	if err == nil {
		_ = cc.Close()
		t.Fatal("expected handshake failure for denied SNI; got success")
	}
}

func itoa(n int) string {
	return strconv.Itoa(n)
}
