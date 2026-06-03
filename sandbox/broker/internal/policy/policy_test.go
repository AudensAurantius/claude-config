package policy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const validAnthropic = `
alias: anthropic-api
upstream:
  host: api.anthropic.com
  port: 443
  scheme: https
credential:
  backend: pass
  path: claude-egress/anthropic/api-key
  attach:
    type: header
    name: x-api-key
constraints:
  methods: [POST, GET]
  paths:
    - /v1/messages
    - /v1/messages/batches*
  max_request_bytes: 1024
  timeout_seconds: 30
  block_request_headers:
    - anthropic-version
`

func writePolicy(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func TestLoadDirectory_OK(t *testing.T) {
	dir := t.TempDir()
	writePolicy(t, dir, "anthropic-api.yaml", validAnthropic)
	set, err := LoadDirectory(dir)
	if err != nil {
		t.Fatalf("LoadDirectory: %v", err)
	}
	if set.Len() != 1 {
		t.Fatalf("got %d policies, want 1", set.Len())
	}
	p := set.Get("anthropic-api")
	if p == nil {
		t.Fatal("missing anthropic-api")
	}
	if p.Upstream.Host != "api.anthropic.com" || p.Upstream.Port != 443 {
		t.Errorf("upstream wrong: %+v", p.Upstream)
	}
	if p.Credential.Attach.Type != "header" || p.Credential.Attach.Name != "x-api-key" {
		t.Errorf("attach wrong: %+v", p.Credential.Attach)
	}
	if !p.Constraints.PathAllowed("/v1/messages") {
		t.Error("expected /v1/messages to match")
	}
	if !p.Constraints.PathAllowed("/v1/messages/batches/abc") {
		t.Error("expected /v1/messages/batches* glob to match")
	}
	if p.Constraints.PathAllowed("/v2/messages") {
		t.Error("expected /v2/messages to NOT match")
	}
	stripped := p.Constraints.StrippedHeaders(p.Credential.Attach)
	for _, h := range []string{"host", "authorization", "cookie", "forwarded", "anthropic-version", "x-api-key"} {
		if _, ok := stripped[h]; !ok {
			t.Errorf("expected %q in stripped headers", h)
		}
	}
}

func TestLoadDirectory_AliasFilenameMismatch(t *testing.T) {
	dir := t.TempDir()
	writePolicy(t, dir, "wrong.yaml", validAnthropic)
	_, err := LoadDirectory(dir)
	if err == nil || !strings.Contains(err.Error(), "filename stem") {
		t.Fatalf("expected filename-stem error, got %v", err)
	}
}

func TestLoadDirectory_DuplicateAlias(t *testing.T) {
	dir := t.TempDir()
	writePolicy(t, dir, "anthropic-api.yaml", validAnthropic)
	writePolicy(t, dir, "anthropic-api.yaml.bak", validAnthropic) // not *.yaml — should be ignored
	set, err := LoadDirectory(dir)
	if err != nil {
		t.Fatalf("LoadDirectory: %v", err)
	}
	if set.Len() != 1 {
		t.Fatalf("expected only .yaml loaded, got %d", set.Len())
	}
}

func TestLoadDirectory_InvalidYAMLFailsTransactionally(t *testing.T) {
	dir := t.TempDir()
	writePolicy(t, dir, "anthropic-api.yaml", validAnthropic)
	writePolicy(t, dir, "broken.yaml", "alias: broken\nupstream: not-a-mapping")
	_, err := LoadDirectory(dir)
	if err == nil {
		t.Fatal("expected error on broken policy")
	}
}

func TestParseUpstream_BadHost(t *testing.T) {
	dir := t.TempDir()
	bad := strings.Replace(validAnthropic, "host: api.anthropic.com", "host: not_a_host", 1)
	writePolicy(t, dir, "anthropic-api.yaml", bad)
	_, err := LoadDirectory(dir)
	if err == nil || !strings.Contains(err.Error(), "FQDN") {
		t.Fatalf("expected FQDN error, got %v", err)
	}
}

func TestParseUpstream_BadScheme(t *testing.T) {
	dir := t.TempDir()
	bad := strings.Replace(validAnthropic, "scheme: https", "scheme: http", 1)
	writePolicy(t, dir, "anthropic-api.yaml", bad)
	_, err := LoadDirectory(dir)
	if err == nil {
		t.Fatal("expected scheme error")
	}
}

func TestParseConstraints_LowercaseMethodRejected(t *testing.T) {
	dir := t.TempDir()
	bad := strings.Replace(validAnthropic, "methods: [POST, GET]", "methods: [post]", 1)
	writePolicy(t, dir, "anthropic-api.yaml", bad)
	_, err := LoadDirectory(dir)
	if err == nil || !strings.Contains(err.Error(), "uppercase") {
		t.Fatalf("expected uppercase-method error, got %v", err)
	}
}

func TestParseConstraints_PathTraversalRejected(t *testing.T) {
	dir := t.TempDir()
	bad := strings.Replace(validAnthropic, "- /v1/messages", "- /v1/../etc/passwd", 1)
	writePolicy(t, dir, "anthropic-api.yaml", bad)
	_, err := LoadDirectory(dir)
	if err == nil || !strings.Contains(err.Error(), "..") {
		t.Fatalf("expected '..' rejection, got %v", err)
	}
}

func TestParseConstraints_MaxBytesCap(t *testing.T) {
	dir := t.TempDir()
	bad := strings.Replace(validAnthropic, "max_request_bytes: 1024", "max_request_bytes: 200000000", 1)
	writePolicy(t, dir, "anthropic-api.yaml", bad)
	_, err := LoadDirectory(dir)
	if err == nil {
		t.Fatal("expected hard-cap rejection")
	}
}

func TestParseCredential_QueryAttachRequiresGETOnly(t *testing.T) {
	dir := t.TempDir()
	bad := `
alias: q
upstream:
  host: example.com
credential:
  backend: stub
  path: x
  attach:
    type: query
    name: token
constraints:
  methods: [POST]
  paths: [/x]
`
	writePolicy(t, dir, "q.yaml", bad)
	_, err := LoadDirectory(dir)
	if err == nil || !strings.Contains(err.Error(), "query-string") {
		t.Fatalf("expected query/GET-only error, got %v", err)
	}
}

func TestParseCredential_BearerSetsAuthorizationName(t *testing.T) {
	dir := t.TempDir()
	yamlSrc := `
alias: b
upstream:
  host: example.com
credential:
  backend: stub
  path: x
  attach:
    type: bearer
constraints:
  methods: [GET]
  paths: [/x]
`
	writePolicy(t, dir, "b.yaml", yamlSrc)
	set, err := LoadDirectory(dir)
	if err != nil {
		t.Fatalf("LoadDirectory: %v", err)
	}
	if got := set.Get("b").Credential.Attach.Name; got != "Authorization" {
		t.Errorf("bearer attach.Name = %q, want Authorization", got)
	}
}
