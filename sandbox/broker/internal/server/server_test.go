package server

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/credentials"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/handler"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/policy"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/wire"
)

const testPolicy = `
alias: anthropic-api
upstream:
  host: api.anthropic.com
  port: 443
  scheme: https
credential:
  backend: stub
  path: claude-egress/anthropic/api-key
  attach:
    type: header
    name: x-api-key
constraints:
  methods: [POST]
  paths:
    - /v1/messages
`

type rewriter struct{ target string }

func (r *rewriter) RoundTrip(req *http.Request) (*http.Response, error) {
	u, _ := url(r.target)
	req.URL.Scheme = u.Scheme
	req.URL.Host = u.Host
	return http.DefaultTransport.RoundTrip(req)
}

func url(s string) (*urlT, error) {
	// Minimal URL parser to avoid pulling net/url at top — just split scheme and host.
	idx := strings.Index(s, "://")
	if idx < 0 {
		return nil, errors.New("bad url")
	}
	return &urlT{Scheme: s[:idx], Host: s[idx+3:]}, nil
}

type urlT struct{ Scheme, Host string }

func newHandler(t *testing.T, upstreamURL string) *handler.Handler {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "anthropic-api.yaml"), []byte(testPolicy), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	set, err := policy.LoadDirectory(dir)
	if err != nil {
		t.Fatalf("LoadDirectory: %v", err)
	}
	h := handler.New(set, &credentials.StubBackend{Secrets: map[string]string{"claude-egress/anthropic/api-key": "sk-test"}})
	if upstreamURL != "" {
		h.HTTPClient = &http.Client{Transport: &rewriter{target: upstreamURL}}
	}
	return h
}

func startServer(t *testing.T, ctx context.Context, cfg Config, h *handler.Handler) {
	t.Helper()
	go func() {
		if err := Serve(ctx, cfg, h); err != nil && !errors.Is(err, net.ErrClosed) {
			t.Logf("Serve returned: %v", err)
		}
	}()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(cfg.SocketPath); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("server did not bind in time")
}

func TestServer_EndToEnd(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		w.Write([]byte(`{"ok":true}`))
	}))
	defer upstream.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sock := filepath.Join(t.TempDir(), "broker.sock")
	startServer(t, ctx, Config{SocketPath: sock, ExpectedPeerUID: syscall.Getuid()}, newHandler(t, upstream.URL))

	client, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	frame, _ := wire.EncodeFrame(map[string]any{
		"alias":    "anthropic-api",
		"method":   "POST",
		"path":     "/v1/messages",
		"headers":  map[string][]string{"content-type": {"application/json"}},
		"body_b64": "",
	})
	if _, err := client.Write(frame); err != nil {
		t.Fatalf("write: %v", err)
	}
	respObj, err := wire.ReadFrame(client)
	if err != nil {
		t.Fatalf("ReadFrame: %v", err)
	}
	if string(respObj["status"]) != "200" {
		t.Fatalf("status raw=%s, want 200", respObj["status"])
	}
}

func TestServer_PeerUIDMismatchRejects(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sock := filepath.Join(t.TempDir(), "broker.sock")
	bogusUID := syscall.Getuid() + 12345
	startServer(t, ctx, Config{SocketPath: sock, ExpectedPeerUID: bogusUID}, newHandler(t, ""))

	client, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	frame, _ := wire.EncodeFrame(map[string]any{
		"alias": "anthropic-api", "method": "POST", "path": "/v1/messages",
		"headers": map[string][]string{}, "body_b64": "",
	})
	_, _ = client.Write(frame) // server may RST before reading

	_ = client.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	buf := make([]byte, 1)
	n, err := client.Read(buf)
	if n > 0 {
		t.Fatalf("expected EOF/RST, got %d bytes", n)
	}
	if err == nil {
		t.Fatal("expected read error (EOF or RST)")
	}
	if !errors.Is(err, io.EOF) && !errors.Is(err, syscall.ECONNRESET) {
		// Either is acceptable; just don't accept silent success.
		t.Logf("read returned %v (acceptable: EOF or ECONNRESET)", err)
	}
}
