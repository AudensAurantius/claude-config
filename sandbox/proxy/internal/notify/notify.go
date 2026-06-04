// Package notify is a minimal sd_notify implementation — enough to send
// READY=1 and STOPPING=1 over the systemd notify socket without pulling
// a third-party dependency. No-ops if NOTIFY_SOCKET is unset.
//
// Duplicated from sandbox/broker/internal/notify until a third user
// justifies a shared module.
package notify

import (
	"net"
	"os"
)

// Send writes state to $NOTIFY_SOCKET. Returns nil if NOTIFY_SOCKET is
// unset (i.e. not running under systemd Type=notify); errors only on a
// real send failure when the socket IS set.
func Send(state string) error {
	addr := os.Getenv("NOTIFY_SOCKET")
	if addr == "" {
		return nil
	}
	conn, err := net.Dial("unixgram", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = conn.Write([]byte(state))
	return err
}

// Ready signals that the service has finished starting.
func Ready() error { return Send("READY=1") }

// Stopping signals that the service is starting shutdown.
func Stopping() error { return Send("STOPPING=1") }
