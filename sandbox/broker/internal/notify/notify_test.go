package notify

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSend_NoEnv_NoOp(t *testing.T) {
	t.Setenv("NOTIFY_SOCKET", "")
	if err := Send("READY=1"); err != nil {
		t.Errorf("Send with unset NOTIFY_SOCKET should be no-op, got %v", err)
	}
}

func TestSend_RoundTrip(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "notify.sock")
	addr, err := net.ResolveUnixAddr("unixgram", sock)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	conn, err := net.ListenUnixgram("unixgram", addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer conn.Close()
	defer os.Remove(sock)

	t.Setenv("NOTIFY_SOCKET", sock)
	if err := Ready(); err != nil {
		t.Fatalf("Ready: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 64)
	n, _, err := conn.ReadFromUnix(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got := string(buf[:n]); got != "READY=1" {
		t.Fatalf("got %q, want READY=1", got)
	}
}
