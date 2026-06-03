// Package credentials provides backends that resolve a policy-declared
// secret path to a secret value. Parity reference:
// src/claude_config/egress_broker/credentials.py.
package credentials

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// ErrFetch wraps any credential-fetch failure.
type ErrFetch struct{ Msg string }

func (e *ErrFetch) Error() string { return e.Msg }

func fetchErr(format string, args ...any) error {
	return &ErrFetch{Msg: fmt.Sprintf(format, args...)}
}

// Backend resolves a policy-declared path to a secret string.
type Backend interface {
	Name() string
	Fetch(path string) (string, error)
}

// PassBackend shells out to pass(1).
type PassBackend struct {
	Binary  string        // defaults to "pass"
	Timeout time.Duration // defaults to 10s
}

// NewPassBackend returns a PassBackend with sensible defaults.
func NewPassBackend() *PassBackend {
	return &PassBackend{Binary: "pass", Timeout: 10 * time.Second}
}

// Name implements Backend.
func (b *PassBackend) Name() string { return "pass" }

// Fetch implements Backend.
func (b *PassBackend) Fetch(path string) (string, error) {
	binary := b.Binary
	if binary == "" {
		binary = "pass"
	}
	timeout := b.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "show", path)
	out, err := cmd.Output()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "", fetchErr("pass(1) timed out fetching %s", path)
	}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return "", fetchErr("pass(1) failed for %s: exit %d: %s",
				path, ee.ExitCode(), strings.TrimSpace(string(ee.Stderr)))
		}
		if errors.Is(err, exec.ErrNotFound) {
			return "", fetchErr("pass(1) binary not found: %s", binary)
		}
		return "", fetchErr("pass(1) invocation failed: %s", err)
	}
	first := strings.SplitN(string(out), "\n", 2)[0]
	first = strings.TrimRight(first, " \t\r")
	if first == "" {
		return "", fetchErr("pass(1) returned empty secret for %s", path)
	}
	return first, nil
}

// StubBackend returns secrets from an in-memory map. Test-only.
type StubBackend struct {
	Secrets map[string]string
}

// Name implements Backend.
func (b *StubBackend) Name() string { return "stub" }

// Fetch implements Backend.
func (b *StubBackend) Fetch(path string) (string, error) {
	s, ok := b.Secrets[path]
	if !ok {
		return "", fetchErr("stub backend has no credential for %s", path)
	}
	return s, nil
}

// Select returns a backend instance by name.
// stubSecrets must be non-nil iff name == "stub".
func Select(name string, stubSecrets map[string]string) (Backend, error) {
	switch name {
	case "pass":
		return NewPassBackend(), nil
	case "stub":
		if stubSecrets == nil {
			return nil, fmt.Errorf("stub backend requires stubSecrets")
		}
		return &StubBackend{Secrets: stubSecrets}, nil
	default:
		return nil, fmt.Errorf("unknown credential backend: %q", name)
	}
}
