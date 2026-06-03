package credentials

import (
	"errors"
	"strings"
	"testing"
)

func TestStubBackend(t *testing.T) {
	b := &StubBackend{Secrets: map[string]string{"k": "v"}}
	got, err := b.Fetch("k")
	if err != nil || got != "v" {
		t.Fatalf("Fetch(k) = %q, %v", got, err)
	}
	_, err = b.Fetch("missing")
	var fe *ErrFetch
	if !errors.As(err, &fe) || !strings.Contains(err.Error(), "missing") {
		t.Fatalf("expected ErrFetch for missing key, got %v", err)
	}
	if b.Name() != "stub" {
		t.Errorf("Name = %q", b.Name())
	}
}

func TestSelect(t *testing.T) {
	if _, err := Select("pass", nil); err != nil {
		t.Errorf("pass select failed: %v", err)
	}
	if _, err := Select("stub", nil); err == nil {
		t.Error("stub without secrets should fail")
	}
	if _, err := Select("stub", map[string]string{}); err != nil {
		t.Errorf("stub with empty secrets should succeed: %v", err)
	}
	if _, err := Select("nonsense", nil); err == nil {
		t.Error("nonsense backend should fail")
	}
}

func TestPassBackend_BinaryNotFound(t *testing.T) {
	b := &PassBackend{Binary: "/nonexistent/pass-binary"}
	_, err := b.Fetch("anything")
	var fe *ErrFetch
	if !errors.As(err, &fe) {
		t.Fatalf("expected ErrFetch, got %v", err)
	}
}
