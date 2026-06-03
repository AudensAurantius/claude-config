package wire

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func mustRaw(t *testing.T, obj any) map[string]json.RawMessage {
	t.Helper()
	b, err := json.Marshal(obj)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return m
}

func TestParseRequest_OK(t *testing.T) {
	raw := mustRaw(t, map[string]any{
		"alias":    "anthropic-api",
		"method":   "POST",
		"path":     "/v1/messages",
		"headers":  map[string][]string{"content-type": {"application/json"}},
		"body_b64": "aGVsbG8=", // "hello"
	})
	req, err := ParseRequest(raw)
	if err != nil {
		t.Fatalf("ParseRequest: %v", err)
	}
	if req.Alias != "anthropic-api" || req.Method != "POST" || req.Path != "/v1/messages" {
		t.Fatalf("bad request fields: %+v", req)
	}
	if string(req.Body) != "hello" {
		t.Fatalf("body = %q, want 'hello'", req.Body)
	}
}

func TestParseRequest_EmptyBody(t *testing.T) {
	raw := mustRaw(t, map[string]any{
		"alias":    "x",
		"method":   "GET",
		"path":     "/",
		"headers":  map[string][]string{},
		"body_b64": "",
	})
	req, err := ParseRequest(raw)
	if err != nil {
		t.Fatalf("ParseRequest: %v", err)
	}
	if len(req.Body) != 0 {
		t.Fatalf("body should be empty, got %d bytes", len(req.Body))
	}
}

func TestParseRequest_MissingFields(t *testing.T) {
	for _, missing := range []string{"alias", "method", "path", "headers", "body_b64"} {
		base := map[string]any{
			"alias": "x", "method": "GET", "path": "/",
			"headers": map[string][]string{}, "body_b64": "",
		}
		delete(base, missing)
		_, err := ParseRequest(mustRaw(t, base))
		if err == nil || !strings.Contains(err.Error(), missing) {
			t.Errorf("missing %s: expected error mentioning the field, got %v", missing, err)
		}
	}
}

func TestParseRequest_BadMethod(t *testing.T) {
	raw := mustRaw(t, map[string]any{
		"alias": "x", "method": "post", "path": "/",
		"headers": map[string][]string{}, "body_b64": "",
	})
	_, err := ParseRequest(raw)
	if err == nil {
		t.Fatal("expected uppercase-method error")
	}
}

func TestParseRequest_PathMustStartWithSlash(t *testing.T) {
	raw := mustRaw(t, map[string]any{
		"alias": "x", "method": "GET", "path": "v1",
		"headers": map[string][]string{}, "body_b64": "",
	})
	_, err := ParseRequest(raw)
	if err == nil {
		t.Fatal("expected path-prefix error")
	}
}

func TestParseRequest_BadBase64(t *testing.T) {
	raw := mustRaw(t, map[string]any{
		"alias": "x", "method": "GET", "path": "/",
		"headers": map[string][]string{}, "body_b64": "!!!not-base64!!!",
	})
	_, err := ParseRequest(raw)
	if err == nil {
		t.Fatal("expected base64 error")
	}
}

func TestRoundTripFrame(t *testing.T) {
	payload := map[string]any{"status": 200, "headers": map[string][]string{"x": {"y"}}, "body_b64": ""}
	frame, err := EncodeFrame(payload)
	if err != nil {
		t.Fatalf("EncodeFrame: %v", err)
	}
	obj, err := ReadFrame(bytes.NewReader(frame))
	if err != nil {
		t.Fatalf("ReadFrame: %v", err)
	}
	var status int
	if err := json.Unmarshal(obj["status"], &status); err != nil || status != 200 {
		t.Fatalf("status round-trip lost: %v / %v", status, err)
	}
}

func TestReadFrame_RejectsOversized(t *testing.T) {
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], MaxFrameBytes+1)
	_, err := ReadFrame(bytes.NewReader(hdr[:]))
	var w *ErrWire
	if !errors.As(err, &w) {
		t.Fatalf("expected ErrWire, got %v", err)
	}
}

func TestReadFrame_ShortBody(t *testing.T) {
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], 10)
	_, err := ReadFrame(bytes.NewReader(append(hdr[:], []byte("abc")...)))
	if err == nil {
		t.Fatal("expected short-body error")
	}
}

func TestEncodeError(t *testing.T) {
	got := EncodeError("policy-denied", "nope")
	if got["error"] != "policy-denied" || got["message"] != "nope" {
		t.Fatalf("unexpected envelope: %v", got)
	}
}
