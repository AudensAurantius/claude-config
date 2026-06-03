// Package handler bridges the wire layer, policy set, and credential
// backend. It does NOT bind to the socket — that belongs to the server
// package, so policy logic stays unit-testable without spinning up UDS.
// Parity reference: src/claude_config/egress_broker/handler.py.
package handler

import (
	"bytes"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/credentials"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/policy"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/wire"
)

// Handler enforces policy and forwards to the upstream.
type Handler struct {
	Policies   *policy.PolicySet
	Backend    credentials.Backend
	HTTPClient *http.Client // nil = construct per-request with policy timeout
	Logger     *slog.Logger
}

// New returns a Handler with a default logger if Logger is nil.
func New(policies *policy.PolicySet, backend credentials.Backend) *Handler {
	return &Handler{Policies: policies, Backend: backend, Logger: slog.Default()}
}

// Handle processes one request and returns a wire payload.
func (h *Handler) Handle(req *wire.Request) map[string]any {
	pol := h.Policies.Get(req.Alias)
	if pol == nil {
		return wire.EncodeError("policy-denied", fmt.Sprintf("unknown alias: %q", req.Alias))
	}
	if denial := checkPolicy(req, pol); denial != "" {
		return wire.EncodeError("policy-denied", denial)
	}
	secret, err := h.Backend.Fetch(pol.Credential.Path)
	if err != nil {
		h.Logger.Error("credential fetch failed", "alias", req.Alias, "err", err)
		return wire.EncodeError("upstream-failed", "credential backend failure")
	}
	outURL, outHeaders, outBody := buildOutbound(req, pol, secret)
	resp, err := h.doUpstream(pol, req.Method, outURL, outHeaders, outBody)
	if err != nil {
		h.Logger.Error("upstream call failed", "alias", req.Alias, "err", err)
		return wire.EncodeError("upstream-failed", err.Error())
	}
	return wire.EncodeResponse(resp)
}

func checkPolicy(req *wire.Request, pol *policy.Policy) string {
	if _, ok := pol.Constraints.Methods[req.Method]; !ok {
		return fmt.Sprintf("method %q not in allowed methods", req.Method)
	}
	pathOnly := req.Path
	if i := strings.IndexByte(pathOnly, '?'); i >= 0 {
		pathOnly = pathOnly[:i]
	}
	if !pol.Constraints.PathAllowed(pathOnly) {
		return fmt.Sprintf("path %q not in allowed paths", pathOnly)
	}
	if len(req.Body) > pol.Constraints.MaxRequestBytes {
		return fmt.Sprintf("request body %d bytes exceeds max_request_bytes %d",
			len(req.Body), pol.Constraints.MaxRequestBytes)
	}
	return ""
}

// buildOutbound returns the full upstream URL, header map, and body to send.
func buildOutbound(req *wire.Request, pol *policy.Policy, secret string) (string, http.Header, []byte) {
	stripped := pol.Constraints.StrippedHeaders(pol.Credential.Attach)
	out := make(http.Header, len(req.Headers)+2)
	for name, values := range req.Headers {
		if _, drop := stripped[strings.ToLower(name)]; drop {
			continue
		}
		// Preserve multi-value semantics: net/http represents repeats as a slice.
		for _, v := range values {
			out.Add(name, v)
		}
	}
	out.Set("Host", pol.Upstream.Host)

	attach := pol.Credential.Attach
	path := req.Path
	switch attach.Type {
	case "header":
		out.Set(attach.Name, secret)
	case "bearer":
		out.Set("Authorization", "Bearer "+secret)
	case "query":
		path = appendQuery(path, attach.Name, secret)
	}
	upstreamURL := fmt.Sprintf("%s://%s:%d%s", pol.Upstream.Scheme, pol.Upstream.Host, pol.Upstream.Port, path)
	return upstreamURL, out, req.Body
}

func appendQuery(path, key, value string) string {
	u, err := url.Parse(path)
	if err != nil {
		// Should never happen — wire already validated leading '/'.
		return path
	}
	q := u.Query()
	q.Add(key, value)
	u.RawQuery = q.Encode()
	return u.String()
}

func (h *Handler) doUpstream(pol *policy.Policy, method, fullURL string, headers http.Header, body []byte) (*wire.Response, error) {
	var bodyReader io.Reader
	if len(body) > 0 {
		bodyReader = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, fullURL, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header = headers
	// net/http sets Host from URL.Host by default; honor an explicit Host header.
	if h := headers.Get("Host"); h != "" {
		req.Host = h
	}

	client := h.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: time.Duration(pol.Constraints.TimeoutSeconds) * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read upstream body: %w", err)
	}
	// Group multi-value response headers faithfully.
	grouped := make(map[string][]string, len(resp.Header))
	for k, vs := range resp.Header {
		grouped[k] = append([]string(nil), vs...)
	}
	return &wire.Response{Status: resp.StatusCode, Headers: grouped, Body: respBody}, nil
}
