package handler

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/credentials"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/policy"
	"github.com/AudensAurantius/claude-config/sandbox/broker/internal/wire"
)

const policyYAML = `
alias: anthropic-api
upstream:
  host: %s
  port: %d
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
  max_request_bytes: 1024
  timeout_seconds: 30
  block_request_headers:
    - anthropic-version
`

// newPolicySet writes a policy file pointing at the test server and loads it.
func newPolicySet(t *testing.T, host string, port int) *policy.PolicySet {
	t.Helper()
	dir := t.TempDir()
	body := strings.Replace(policyYAML, "%s", host, 1)
	body = strings.Replace(body, "%d", itoa(port), 1)
	// Policy validator enforces FQDN — relax via direct manipulation: tests
	// instead use httptest with an HTTPS upstream whose Host header is
	// "api.anthropic.com" matched against an FQDN policy, with the test
	// server reached via a custom HTTPClient. So write the policy with a
	// real FQDN and override the URL via HTTPClient.
	_ = body
	pinned := strings.NewReplacer("%s", "api.anthropic.com", "%d", "443").Replace(policyYAML)
	if err := os.WriteFile(filepath.Join(dir, "anthropic-api.yaml"), []byte(pinned), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	set, err := policy.LoadDirectory(dir)
	if err != nil {
		t.Fatalf("LoadDirectory: %v", err)
	}
	return set
}

func itoa(n int) string {
	// Avoid pulling strconv via a separate import — tiny helper.
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}

// redirectClient rewrites the request URL to the httptest server's URL
// (plain HTTP), preserving the Host header from policy. This lets us
// exercise the full code path with httptest.NewServer (no TLS hassle).
func redirectClient(serverURL string) *http.Client {
	return &http.Client{Transport: &rewriter{target: serverURL}}
}

type rewriter struct{ target string }

func (r *rewriter) RoundTrip(req *http.Request) (*http.Response, error) {
	// Override scheme/host/port but preserve path + raw query.
	u, _ := http.NewRequest(req.Method, r.target+req.URL.Path, nil)
	req.URL.Scheme = u.URL.Scheme
	req.URL.Host = u.URL.Host
	if req.URL.RawQuery != "" {
		// Keep RawQuery as-is.
	}
	return http.DefaultTransport.RoundTrip(req)
}

func newReq(t *testing.T, overrides map[string]any) *wire.Request {
	t.Helper()
	base := map[string]any{
		"alias":   "anthropic-api",
		"method":  "POST",
		"path":    "/v1/messages",
		"headers": map[string][]string{"content-type": {"application/json"}, "anthropic-version": {"2023-06-01"}},
		"body":    []byte{},
	}
	for k, v := range overrides {
		base[k] = v
	}
	hdrs := base["headers"].(map[string][]string)
	body := base["body"].([]byte)
	return &wire.Request{
		Alias:   base["alias"].(string),
		Method:  base["method"].(string),
		Path:    base["path"].(string),
		Headers: hdrs,
		Body:    body,
	}
}

func TestHandle_UnknownAliasDenied(t *testing.T) {
	set := newPolicySet(t, "", 0)
	h := New(set, &credentials.StubBackend{Secrets: map[string]string{"claude-egress/anthropic/api-key": "sk"}})
	resp := h.Handle(newReq(t, map[string]any{"alias": "unknown"}))
	if resp["error"] != "policy-denied" {
		t.Fatalf("expected policy-denied, got %v", resp)
	}
}

func TestHandle_MethodNotInPolicy(t *testing.T) {
	set := newPolicySet(t, "", 0)
	h := New(set, &credentials.StubBackend{Secrets: map[string]string{"claude-egress/anthropic/api-key": "sk"}})
	resp := h.Handle(newReq(t, map[string]any{"method": "GET"}))
	if resp["error"] != "policy-denied" || !strings.Contains(resp["message"].(string), "GET") {
		t.Fatalf("expected GET-denied, got %v", resp)
	}
}

func TestHandle_PathNotInPolicy(t *testing.T) {
	set := newPolicySet(t, "", 0)
	h := New(set, &credentials.StubBackend{Secrets: map[string]string{"claude-egress/anthropic/api-key": "sk"}})
	resp := h.Handle(newReq(t, map[string]any{"path": "/v2/messages"}))
	if resp["error"] != "policy-denied" || !strings.Contains(resp["message"].(string), "/v2/messages") {
		t.Fatalf("expected /v2/messages denied, got %v", resp)
	}
}

func TestHandle_OversizedBodyDenied(t *testing.T) {
	set := newPolicySet(t, "", 0)
	h := New(set, &credentials.StubBackend{Secrets: map[string]string{"claude-egress/anthropic/api-key": "sk"}})
	big := make([]byte, 2048)
	resp := h.Handle(newReq(t, map[string]any{"body": big}))
	if resp["error"] != "policy-denied" || !strings.Contains(resp["message"].(string), "max_request_bytes") {
		t.Fatalf("expected size-denied, got %v", resp)
	}
}

func TestHandle_HappyPathAttachesCredential(t *testing.T) {
	var seen *http.Request
	var seenBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r
		seenBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Add("X-Multi", "a")
		w.Header().Add("X-Multi", "b")
		w.WriteHeader(200)
		w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	set := newPolicySet(t, "", 0)
	h := New(set, &credentials.StubBackend{Secrets: map[string]string{"claude-egress/anthropic/api-key": "sk-test-secret"}})
	h.HTTPClient = redirectClient(srv.URL)

	resp := h.Handle(newReq(t, map[string]any{"body": []byte(`{}`)}))
	if resp["status"] != 200 {
		t.Fatalf("status=%v, resp=%v", resp["status"], resp)
	}
	if seen == nil {
		t.Fatal("upstream not called")
	}
	if got := seen.Header.Get("x-api-key"); got != "sk-test-secret" {
		t.Errorf("x-api-key=%q, want sk-test-secret", got)
	}
	if seen.Header.Get("anthropic-version") != "" {
		t.Errorf("anthropic-version should be stripped, got %q", seen.Header.Get("anthropic-version"))
	}
	if seen.Header.Get("content-type") != "application/json" {
		t.Errorf("content-type passthrough lost: %q", seen.Header.Get("content-type"))
	}
	if string(seenBody) != "{}" {
		t.Errorf("body=%q, want {}", seenBody)
	}
	gotHdrs := resp["headers"].(map[string][]string)
	if v := gotHdrs["X-Multi"]; len(v) != 2 || v[0] != "a" || v[1] != "b" {
		t.Errorf("X-Multi grouping lost: %v", v)
	}
}

func TestHandle_SandboxCannotInjectCredentialHeader(t *testing.T) {
	var seen *http.Request
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r
		w.WriteHeader(200)
	}))
	defer srv.Close()

	set := newPolicySet(t, "", 0)
	h := New(set, &credentials.StubBackend{Secrets: map[string]string{"claude-egress/anthropic/api-key": "sk-real"}})
	h.HTTPClient = redirectClient(srv.URL)

	req := newReq(t, map[string]any{
		"headers": map[string][]string{
			"content-type": {"application/json"},
			"x-api-key":    {"sandbox-attempt-to-set-credential"},
		},
	})
	h.Handle(req)
	if got := seen.Header.Get("x-api-key"); got != "sk-real" {
		t.Errorf("sandbox-supplied credential leaked: x-api-key=%q", got)
	}
}

func TestHandle_CredentialFetchFailure(t *testing.T) {
	set := newPolicySet(t, "", 0)
	h := New(set, &credentials.StubBackend{Secrets: map[string]string{}}) // no secret
	resp := h.Handle(newReq(t, nil))
	if resp["error"] != "upstream-failed" {
		t.Fatalf("expected upstream-failed, got %v", resp)
	}
}
