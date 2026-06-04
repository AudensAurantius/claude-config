// Package sniff peeks the SNI from a freshly accepted TLS connection
// without terminating the handshake. It drives crypto/tls.Server with a
// GetConfigForClient callback that captures the *tls.ClientHelloInfo
// and then deliberately aborts the handshake, while a wrapping reader
// preserves every byte the parser consumed so the original ClientHello
// can be replayed to the upstream.
//
// Reference: Andrew Ayer, "Writing an SNI Proxy in 115 Lines of Go"
// (https://www.agwa.name/blog/post/writing_an_sni_proxy_in_go).
package sniff

import (
	"bytes"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"time"
)

// errAbortHandshake is returned from GetConfigForClient to deliberately
// stop crypto/tls.Server before it sends a ServerHello. It is matched
// against err.Error() == handshakeAborted in PeekClientHello and
// suppressed.
var errAbortHandshake = errors.New("sniff: handshake aborted after ClientHello peek")

// PeekClientHello reads enough of conn to extract the ClientHello, then
// returns the parsed info plus the raw bytes that were consumed so the
// caller can replay them when splicing to the upstream.
//
// On success: info is non-nil and prefix holds the bytes already drained
// from conn. On failure: prefix may still hold partial bytes — callers
// should close the connection rather than try to recover.
func PeekClientHello(conn net.Conn, timeout time.Duration) (info *tls.ClientHelloInfo, prefix []byte, err error) {
	if timeout > 0 {
		if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
			return nil, nil, err
		}
		defer func() { _ = conn.SetReadDeadline(time.Time{}) }()
	}

	pc := newPeekConn(conn)
	var captured *tls.ClientHelloInfo
	cfg := &tls.Config{
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			// Copy the fields we care about — the underlying buffer can
			// be reused by crypto/tls once we return.
			captured = &tls.ClientHelloInfo{
				ServerName:        hello.ServerName,
				SupportedVersions: append([]uint16(nil), hello.SupportedVersions...),
				SupportedProtos:   append([]string(nil), hello.SupportedProtos...),
			}
			return nil, errAbortHandshake
		},
	}

	// Drive the handshake. We expect this to fail — either with our own
	// abort sentinel or a "remote error" because crypto/tls relays the
	// nil-cfg from GetConfigForClient as a handshake-failure alert.
	hsErr := tls.Server(readOnlyConn{Conn: pc}, cfg).Handshake()
	if captured == nil {
		// We never got far enough for the callback to fire.
		return nil, pc.buffered(), hsErr
	}
	return captured, pc.buffered(), nil
}

// peekConn wraps a net.Conn so every byte read is also recorded for
// later replay. Writes are not allowed during ClientHello peek; they
// would correspond to a half-completed handshake we do not want to
// produce. (We use readOnlyConn to enforce that downstream.)
type peekConn struct {
	net.Conn
	buf bytes.Buffer
}

func newPeekConn(c net.Conn) *peekConn { return &peekConn{Conn: c} }

func (p *peekConn) Read(b []byte) (int, error) {
	n, err := p.Conn.Read(b)
	if n > 0 {
		p.buf.Write(b[:n])
	}
	return n, err
}

func (p *peekConn) buffered() []byte {
	out := make([]byte, p.buf.Len())
	copy(out, p.buf.Bytes())
	return out
}

// readOnlyConn shadows the Write method of an embedded net.Conn so
// crypto/tls cannot accidentally send a ServerHello during the abort
// path. Returns io.ErrClosedPipe on any write attempt — crypto/tls
// treats this as a transport error and stops.
type readOnlyConn struct{ net.Conn }

func (readOnlyConn) Write(_ []byte) (int, error) { return 0, io.ErrClosedPipe }

// HandshakeAborted reports whether err is the synthetic abort sentinel
// we return from GetConfigForClient. Callers can ignore this specific
// error after a successful capture.
func HandshakeAborted(err error) bool {
	return errors.Is(err, errAbortHandshake)
}
