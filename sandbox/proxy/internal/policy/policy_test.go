package policy

import (
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestLoadDirectory_Valid(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "anthropic-cdn.yaml"), `
alias: anthropic-cdn
hostnames:
  - api.anthropic.com
  - "*.cdn.anthropic.com"
ports: [443]
`)
	writeFile(t, filepath.Join(dir, "registry.yaml"), `
alias: registry
hostnames:
  - registry.npmjs.org
`)
	set, err := LoadDirectory(dir)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if set.Len() != 2 {
		t.Fatalf("expected 2 aliases, got %d (%v)", set.Len(), set.Aliases())
	}

	cases := []struct {
		sni       string
		port      int
		wantAlias string
		wantOK    bool
	}{
		{"api.anthropic.com", 443, "anthropic-cdn", true},
		{"a.cdn.anthropic.com", 443, "anthropic-cdn", true},
		{"deep.a.cdn.anthropic.com", 443, "", false},
		{"cdn.anthropic.com", 443, "", false},
		{"api.anthropic.com", 8443, "", false},
		{"registry.npmjs.org", 443, "registry", true},
		{"REGISTRY.NPMJS.ORG", 443, "registry", true},
		{"registry.npmjs.org.", 443, "registry", true},
		{"evil.example", 443, "", false},
	}
	for _, c := range cases {
		alias, ok := set.Match(c.sni, c.port)
		if alias != c.wantAlias || ok != c.wantOK {
			t.Errorf("Match(%q, %d) = (%q, %v); want (%q, %v)",
				c.sni, c.port, alias, ok, c.wantAlias, c.wantOK)
		}
	}
}

func TestLoadDirectory_InvalidCases(t *testing.T) {
	cases := map[string]string{
		"alias-mismatch.yaml": `
alias: not-the-filename
hostnames: [example.com]
`,
		"empty-hostnames.yaml": `
alias: empty-hostnames
hostnames: []
`,
		"bad-wildcard.yaml": `
alias: bad-wildcard
hostnames: ["*foo.example.com"]
`,
		"embedded-wildcard.yaml": `
alias: embedded-wildcard
hostnames: ["a.*.example.com"]
`,
		"single-label.yaml": `
alias: single-label
hostnames: ["localhost"]
`,
		"bad-port.yaml": `
alias: bad-port
hostnames: ["a.example.com"]
ports: [70000]
`,
		"unknown-field.yaml": `
alias: unknown-field
hostnames: ["a.example.com"]
bogus_extra: true
`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			writeFile(t, filepath.Join(dir, name), body)
			if _, err := LoadDirectory(dir); err == nil {
				t.Fatalf("expected error for %s, got nil", name)
			}
		})
	}
}

func TestLoadDirectory_DuplicateAlias(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a.yaml"), `alias: a
hostnames: [one.example.com]
`)
	writeFile(t, filepath.Join(dir, "b.yaml"), `alias: a
hostnames: [two.example.com]
`)
	if _, err := LoadDirectory(dir); err == nil {
		t.Fatal("expected duplicate-alias error")
	}
}

func TestLoadDirectory_DefaultPort(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "noport.yaml"), `alias: noport
hostnames: [a.example.com]
`)
	set, err := LoadDirectory(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := set.Match("a.example.com", 443); !ok {
		t.Fatal("default port 443 should match")
	}
	if _, ok := set.Match("a.example.com", 80); ok {
		t.Fatal("port 80 should not match (default is 443 only)")
	}
}

func TestLoadDirectory_NotADirectory(t *testing.T) {
	f := filepath.Join(t.TempDir(), "file.txt")
	writeFile(t, f, "hi")
	if _, err := LoadDirectory(f); err == nil {
		t.Fatal("expected error for non-directory path")
	}
}

func TestPolicySet_NilSafe(t *testing.T) {
	var s *PolicySet
	if s.Len() != 0 {
		t.Fatal("nil PolicySet Len should be 0")
	}
	if alias, ok := s.Match("a.example.com", 443); ok || alias != "" {
		t.Fatal("nil PolicySet Match should be (empty, false)")
	}
}
