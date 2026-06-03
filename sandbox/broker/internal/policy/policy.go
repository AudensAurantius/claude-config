// Package policy loads and validates per-alias YAML policy files for
// the egress broker. Parity reference:
// src/claude_config/egress_broker/policy.py and the schema at
// sandbox/egress-policy/README.md.
package policy

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	HardCapBytes      = 100 * 1024 * 1024
	defaultMaxBytes   = 10 * 1024 * 1024
	defaultTimeoutSec = 120
)

var (
	fqdnRE = regexp.MustCompile(`^(?i)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$`)
	// Path glob character allow-list — matches the Python _PATH_FORBIDDEN_RE inverse.
	pathAllowedCharRE = regexp.MustCompile(`^[A-Za-z0-9_\-./*?+%@:,~&=]+$`)

	alwaysStrippedHeaders = stringSet("host", "authorization", "cookie", "forwarded")
)

// Error is returned by every validation failure in this package.
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func policyErr(format string, args ...any) error {
	return &Error{Msg: fmt.Sprintf(format, args...)}
}

// Attach is how a credential is attached to the outbound request.
type Attach struct {
	Type string // header | bearer | query
	Name string
}

// Credential is where the secret comes from.
type Credential struct {
	Backend string // pass | stub
	Path    string
	Attach  Attach
}

// Upstream is the destination the broker forwards to.
type Upstream struct {
	Host   string
	Port   int
	Scheme string
}

// Constraints describe what shapes of request the sandbox may issue.
type Constraints struct {
	Methods             map[string]struct{}
	Paths               []string
	MaxRequestBytes     int
	TimeoutSeconds      int
	BlockRequestHeaders map[string]struct{} // lowercase keys
}

// Policy is a single per-alias policy.
type Policy struct {
	Alias       string
	Upstream    Upstream
	Credential  Credential
	Constraints Constraints
}

// PolicySet holds the loaded policies, keyed by alias.
type PolicySet struct {
	byAlias map[string]*Policy
}

// Get returns the named policy or nil if unknown.
func (s *PolicySet) Get(alias string) *Policy {
	if s == nil {
		return nil
	}
	return s.byAlias[alias]
}

// Len returns the number of loaded aliases.
func (s *PolicySet) Len() int {
	if s == nil {
		return 0
	}
	return len(s.byAlias)
}

// Aliases returns the loaded alias names in sorted order.
func (s *PolicySet) Aliases() []string {
	out := make([]string, 0, len(s.byAlias))
	for k := range s.byAlias {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// PathAllowed reports whether path matches any of the policy's globs.
// Glob semantics match Python's fnmatch.fnmatchcase: '*' matches any
// run of characters INCLUDING '/', '?' matches one character.
func (c *Constraints) PathAllowed(path string) bool {
	for _, pat := range c.Paths {
		if fnmatch(pat, path) {
			return true
		}
	}
	return false
}

func fnmatch(pattern, s string) bool {
	var b strings.Builder
	b.WriteByte('^')
	for _, r := range pattern {
		switch r {
		case '*':
			b.WriteString(".*")
		case '?':
			b.WriteByte('.')
		default:
			b.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	b.WriteByte('$')
	re, err := regexp.Compile(b.String())
	if err != nil {
		return false
	}
	return re.MatchString(s)
}

// StrippedHeaders returns the lowercase set of headers the broker must
// remove before forwarding (always-stripped + policy-blocked + the
// credential-attach header if attach type is header).
func (c *Constraints) StrippedHeaders(attach Attach) map[string]struct{} {
	out := make(map[string]struct{}, len(alwaysStrippedHeaders)+len(c.BlockRequestHeaders)+1)
	for k := range alwaysStrippedHeaders {
		out[k] = struct{}{}
	}
	for k := range c.BlockRequestHeaders {
		out[k] = struct{}{}
	}
	if attach.Type == "header" {
		out[strings.ToLower(attach.Name)] = struct{}{}
	}
	return out
}

// LoadDirectory validates every *.yaml under dir and returns a PolicySet.
// Transactional: any single failure aborts the load with no partial state.
func LoadDirectory(dir string) (*PolicySet, error) {
	info, err := os.Stat(dir)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("policy path is not a directory: %s", dir)
	}
	entries, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return nil, err
	}
	sort.Strings(entries)
	loaded := make(map[string]*Policy)
	for _, path := range entries {
		p, err := loadFile(path)
		if err != nil {
			return nil, err
		}
		if _, dup := loaded[p.Alias]; dup {
			return nil, policyErr("duplicate alias %q at %s", p.Alias, path)
		}
		loaded[p.Alias] = p
	}
	return &PolicySet{byAlias: loaded}, nil
}

type rawAttach struct {
	Type string `yaml:"type"`
	Name string `yaml:"name"`
}

type rawCredential struct {
	Backend string    `yaml:"backend"`
	Path    string    `yaml:"path"`
	Attach  rawAttach `yaml:"attach"`
}

type rawUpstream struct {
	Host   string `yaml:"host"`
	Port   *int   `yaml:"port"`
	Scheme string `yaml:"scheme"`
}

type rawConstraints struct {
	Methods             []string `yaml:"methods"`
	Paths               []string `yaml:"paths"`
	MaxRequestBytes     *int     `yaml:"max_request_bytes"`
	TimeoutSeconds      *int     `yaml:"timeout_seconds"`
	BlockRequestHeaders []string `yaml:"block_request_headers"`
}

type rawPolicy struct {
	Alias       string         `yaml:"alias"`
	Upstream    rawUpstream    `yaml:"upstream"`
	Credential  rawCredential  `yaml:"credential"`
	Constraints rawConstraints `yaml:"constraints"`
}

func loadFile(path string) (*Policy, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw rawPolicy
	dec := yaml.NewDecoder(strings.NewReader(string(data)))
	dec.KnownFields(false)
	if err := dec.Decode(&raw); err != nil {
		return nil, policyErr("%s: invalid YAML: %s", path, err)
	}

	expectedAlias := strings.TrimSuffix(filepath.Base(path), ".yaml")
	if raw.Alias != expectedAlias {
		return nil, policyErr("%s: alias %q must match filename stem %q", path, raw.Alias, expectedAlias)
	}

	upstream, err := parseUpstream(path, raw.Upstream)
	if err != nil {
		return nil, err
	}
	cred, err := parseCredential(path, raw.Credential)
	if err != nil {
		return nil, err
	}
	cons, err := parseConstraints(path, raw.Constraints, cred.Attach)
	if err != nil {
		return nil, err
	}
	return &Policy{
		Alias:       raw.Alias,
		Upstream:    upstream,
		Credential:  cred,
		Constraints: cons,
	}, nil
}

func parseUpstream(path string, r rawUpstream) (Upstream, error) {
	if r.Host == "" || !fqdnRE.MatchString(r.Host) {
		return Upstream{}, policyErr("%s: 'upstream.host' must be a valid FQDN, got %q", path, r.Host)
	}
	scheme := r.Scheme
	if scheme == "" {
		scheme = "https"
	}
	if scheme != "https" {
		return Upstream{}, policyErr("%s: 'upstream.scheme' must be 'https', got %q", path, scheme)
	}
	port := 443
	if r.Port != nil {
		port = *r.Port
	}
	if port < 1 || port > 65535 {
		return Upstream{}, policyErr("%s: 'upstream.port' must be int 1..65535, got %d", path, port)
	}
	return Upstream{Host: r.Host, Port: port, Scheme: scheme}, nil
}

func parseCredential(path string, r rawCredential) (Credential, error) {
	if r.Backend != "pass" && r.Backend != "stub" {
		return Credential{}, policyErr("%s: 'credential.backend' must be 'pass' or 'stub', got %q", path, r.Backend)
	}
	if r.Path == "" {
		return Credential{}, policyErr("%s: 'credential.path' must be a non-empty string", path)
	}
	t := r.Attach.Type
	if t != "header" && t != "bearer" && t != "query" {
		return Credential{}, policyErr("%s: 'credential.attach.type' must be header|bearer|query, got %q", path, t)
	}
	name := r.Attach.Name
	if t == "bearer" {
		name = "Authorization"
	} else if name == "" {
		return Credential{}, policyErr("%s: 'credential.attach.name' required for type=%s", path, t)
	}
	return Credential{
		Backend: r.Backend,
		Path:    r.Path,
		Attach:  Attach{Type: t, Name: name},
	}, nil
}

func parseConstraints(path string, r rawConstraints, attach Attach) (Constraints, error) {
	if len(r.Methods) == 0 {
		return Constraints{}, policyErr("%s: 'constraints.methods' must be a non-empty list", path)
	}
	methods := make(map[string]struct{}, len(r.Methods))
	for _, m := range r.Methods {
		if m == "" || m != strings.ToUpper(m) {
			return Constraints{}, policyErr("%s: method %q must be uppercase ASCII", path, m)
		}
		methods[m] = struct{}{}
	}
	if attach.Type == "query" {
		if _, ok := methods["GET"]; !ok || len(methods) != 1 {
			return Constraints{}, policyErr("%s: query-string credentials only permitted with methods=[GET]", path)
		}
	}
	if len(r.Paths) == 0 {
		return Constraints{}, policyErr("%s: 'constraints.paths' must be a non-empty list", path)
	}
	paths := make([]string, 0, len(r.Paths))
	for _, p := range r.Paths {
		if !strings.HasPrefix(p, "/") {
			return Constraints{}, policyErr("%s: path %q must be a string starting with '/'", path, p)
		}
		if strings.Contains(p, "..") {
			return Constraints{}, policyErr("%s: path %q contains forbidden '..'", path, p)
		}
		if !pathAllowedCharRE.MatchString(p) {
			return Constraints{}, policyErr("%s: path %q contains forbidden characters", path, p)
		}
		paths = append(paths, p)
	}
	maxBytes := defaultMaxBytes
	if r.MaxRequestBytes != nil {
		maxBytes = *r.MaxRequestBytes
	}
	if maxBytes <= 0 || maxBytes > HardCapBytes {
		return Constraints{}, policyErr("%s: 'max_request_bytes' must be int in (0, %d], got %d", path, HardCapBytes, maxBytes)
	}
	timeout := defaultTimeoutSec
	if r.TimeoutSeconds != nil {
		timeout = *r.TimeoutSeconds
	}
	if timeout <= 0 {
		return Constraints{}, policyErr("%s: 'timeout_seconds' must be positive int, got %d", path, timeout)
	}
	block := make(map[string]struct{}, len(r.BlockRequestHeaders))
	for _, h := range r.BlockRequestHeaders {
		if h == "" {
			return Constraints{}, policyErr("%s: blocked header must be a non-empty string", path)
		}
		block[strings.ToLower(h)] = struct{}{}
	}
	return Constraints{
		Methods:             methods,
		Paths:               paths,
		MaxRequestBytes:     maxBytes,
		TimeoutSeconds:      timeout,
		BlockRequestHeaders: block,
	}, nil
}

func stringSet(items ...string) map[string]struct{} {
	out := make(map[string]struct{}, len(items))
	for _, x := range items {
		out[x] = struct{}{}
	}
	return out
}
