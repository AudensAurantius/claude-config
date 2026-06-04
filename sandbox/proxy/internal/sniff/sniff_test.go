package sniff

import (
	"crypto/tls"
	"io"
	"net"
	"testing"
	"time"
)

// TestPeekClientHello_RoundTrip starts a real tls.Dial against a pipe,
// peeks the ClientHello on the server side, and asserts that the
// captured ServerName plus the buffered bytes are what we expect.
func TestPeekClientHello_RoundTrip(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	go func() {
		// The client side speaks just enough TLS to emit a ClientHello.
		// We don't care about completion; we'll close after a brief read
		// attempt (which will return an error once the server hangs up).
		c := tls.Client(clientConn, &tls.Config{
			ServerName:         "api.anthropic.com",
			InsecureSkipVerify: true, //nolint:gosec // peek-only; no real upstream.
		})
		_ = c.Handshake()
		_ = c.Close()
	}()

	info, prefix, err := PeekClientHello(serverConn, 2*time.Second)
	if err != nil && !HandshakeAborted(err) && err != io.ErrClosedPipe {
		// Some platforms surface the closed-pipe write through Handshake.
		t.Logf("peek returned err=%v (tolerated)", err)
	}
	if info == nil {
		t.Fatalf("expected captured ClientHelloInfo, got nil (err=%v)", err)
	}
	if info.ServerName != "api.anthropic.com" {
		t.Errorf("ServerName: got %q, want %q", info.ServerName, "api.anthropic.com")
	}
	if len(prefix) == 0 {
		t.Error("expected buffered prefix bytes, got 0")
	}
	// TLS record header: type=0x16 (handshake), version major=0x03.
	if prefix[0] != 0x16 {
		t.Errorf("buffered prefix should start with TLS handshake record (0x16), got 0x%02x", prefix[0])
	}
}

func TestPeekClientHello_NonTLSTraffic(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	go func() {
		_, _ = clientConn.Write([]byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
		_ = clientConn.Close()
	}()

	info, _, err := PeekClientHello(serverConn, 500*time.Millisecond)
	if info != nil {
		t.Fatalf("expected no ClientHelloInfo for non-TLS traffic; got %+v", info)
	}
	if err == nil {
		t.Fatal("expected error for non-TLS bytes")
	}
}

func TestPeekClientHello_Timeout(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()
	// Client never writes — peek should hit the read deadline.
	info, _, err := PeekClientHello(serverConn, 100*time.Millisecond)
	if info != nil {
		t.Fatal("expected nil info on timeout")
	}
	if err == nil {
		t.Fatal("expected timeout error")
	}
}
