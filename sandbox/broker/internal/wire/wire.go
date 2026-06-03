// Package wire implements the egress broker's UDS framing protocol.
//
// Each request/response is a single length-prefixed JSON frame:
//
//	+--------+--------------------------------+
//	| u32 BE | JSON bytes (max 100 MiB)       |
//	+--------+--------------------------------+
//
// Bodies are carried base64-encoded in the JSON payload; no streaming.
// Parity reference: src/claude_config/egress_broker/wire.py.
package wire

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

const MaxFrameBytes = 100 * 1024 * 1024

// ErrWire wraps any wire-format violation.
type ErrWire struct{ Msg string }

func (e *ErrWire) Error() string { return e.Msg }

func wireErr(format string, args ...any) error {
	return &ErrWire{Msg: fmt.Sprintf(format, args...)}
}

// Request is a parsed sandbox request.
type Request struct {
	Alias   string
	Method  string
	Path    string
	Headers map[string][]string
	Body    []byte
}

// Response is a broker response to forward back to the sandbox.
type Response struct {
	Status  int
	Headers map[string][]string
	Body    []byte
}

// requestJSON / responseJSON / errorJSON are the wire envelopes.
type requestJSON struct {
	Alias   string              `json:"alias"`
	Method  string              `json:"method"`
	Path    string              `json:"path"`
	Headers map[string][]string `json:"headers"`
	BodyB64 string              `json:"body_b64"`
}

type responseJSON struct {
	Status  int                 `json:"status"`
	Headers map[string][]string `json:"headers"`
	BodyB64 string              `json:"body_b64"`
}

// ErrorEnvelope is the wire shape for negative responses.
type ErrorEnvelope struct {
	Code    string `json:"error"`
	Message string `json:"message"`
}

// ParseRequest validates a raw JSON object and returns a Request.
func ParseRequest(raw map[string]json.RawMessage) (*Request, error) {
	var rj requestJSON
	// Re-marshal then unmarshal into the typed struct so error messages
	// stay close to the Python reference's "missing required field" form.
	for _, k := range []string{"alias", "method", "path", "headers", "body_b64"} {
		if _, ok := raw[k]; !ok {
			return nil, wireErr("missing required field: %s", k)
		}
	}
	buf, _ := json.Marshal(raw)
	if err := json.Unmarshal(buf, &rj); err != nil {
		return nil, wireErr("invalid request shape: %s", err)
	}
	if rj.Alias == "" {
		return nil, wireErr("'alias' must be a non-empty string")
	}
	if rj.Method == "" || rj.Method != strings.ToUpper(rj.Method) {
		return nil, wireErr("'method' must be uppercase ASCII")
	}
	if !strings.HasPrefix(rj.Path, "/") {
		return nil, wireErr("'path' must be a string starting with '/'")
	}
	if rj.Headers == nil {
		return nil, wireErr("'headers' must be an object")
	}
	var body []byte
	if rj.BodyB64 != "" {
		b, err := base64.StdEncoding.DecodeString(rj.BodyB64)
		if err != nil {
			return nil, wireErr("'body_b64' is not valid base64: %s", err)
		}
		body = b
	}
	hdrs := make(map[string][]string, len(rj.Headers))
	for k, v := range rj.Headers {
		hdrs[k] = append([]string(nil), v...)
	}
	return &Request{
		Alias:   rj.Alias,
		Method:  rj.Method,
		Path:    rj.Path,
		Headers: hdrs,
		Body:    body,
	}, nil
}

// EncodeResponse serializes a Response into a wire-ready JSON payload.
func EncodeResponse(r *Response) map[string]any {
	hdrs := r.Headers
	if hdrs == nil {
		hdrs = map[string][]string{}
	}
	return map[string]any{
		"status":   r.Status,
		"headers":  hdrs,
		"body_b64": base64.StdEncoding.EncodeToString(r.Body),
	}
}

// EncodeError serializes an error envelope into a wire payload.
func EncodeError(code, message string) map[string]any {
	return map[string]any{"error": code, "message": message}
}

// EncodeFrame serializes a payload as a length-prefixed JSON frame.
func EncodeFrame(payload any) ([]byte, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, wireErr("json marshal failed: %s", err)
	}
	if len(body) > MaxFrameBytes {
		return nil, wireErr("frame body %d exceeds MAX_FRAME_BYTES=%d", len(body), MaxFrameBytes)
	}
	out := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(out[:4], uint32(len(body)))
	copy(out[4:], body)
	return out, nil
}

// ReadFrame reads one length-prefixed JSON frame from r as a raw map.
func ReadFrame(r io.Reader) (map[string]json.RawMessage, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return nil, wireErr("short read: wanted 4 bytes, hit EOF")
		}
		return nil, wireErr("frame header read failed: %s", err)
	}
	length := binary.BigEndian.Uint32(hdr[:])
	if int(length) > MaxFrameBytes {
		return nil, wireErr("declared frame length %d exceeds MAX_FRAME_BYTES", length)
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, wireErr("short read: wanted %d body bytes: %s", length, err)
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(body, &obj); err != nil {
		return nil, wireErr("frame body is not valid JSON object: %s", err)
	}
	if obj == nil {
		return nil, wireErr("frame body must be a JSON object")
	}
	return obj, nil
}
