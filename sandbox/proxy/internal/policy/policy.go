// Package policy loads and validates per-alias YAML allowlist files for
// the egress SNI-passthrough proxy. Schema reference:
// sandbox/egress-proxy/README.md.
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

const defaultPort = 443

// fqdnRE matches an absolute domain name (no leading dot, no wildcard).
// Used both for upstream hostnames and as the body of a wildcard pattern.
var fqdnRE = regexp.MustCompile(`^(?i)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$`)

// labelRE matches a single DNS label (no dot).
var labelRE = regexp.MustCompile(`^(?i)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)

// Error is returned by every validation failure in this package.
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func policyErr(format string, args ...any) error {
	return &Error{Msg: fmt.Sprintf(format, args...)}
}

// Allowlist is a single per-alias entry: a set of hostnames (literal or
// leftmost-wildcard) and the TCP ports they may be reached on.
type Allowlist struct {
	Alias     string
	Hostnames []HostPattern
	Ports     map[int]struct{}
}

// HostPattern is either an exact FQDN or a leftmost-wildcard pattern.
// Wildcards match exactly one DNS label: "*.cdn.anthropic.com" matches
// "a.cdn.anthropic.com" but NOT "a.b.cdn.anthropic.com" and NOT
// "cdn.anthropic.com" itself. This is the same semantic browsers apply
// to TLS-cert wildcard SANs.
type HostPattern struct {
	Raw      string // as written in the YAML
	Wildcard bool
	Suffix   string // the part after "*." for wildcard patterns; the literal FQDN otherwise
}

// Match reports whether host satisfies the pattern.
func (p HostPattern) Match(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if !p.Wildcard {
		return host == p.Suffix
	}
	if !strings.HasSuffix(host, "."+p.Suffix) {
		return false
	}
	prefix := host[:len(host)-len(p.Suffix)-1]
	// Exactly one label — no embedded dots.
	return prefix != "" && !strings.Contains(prefix, ".")
}

// PolicySet holds the loaded allowlists keyed by alias.
type PolicySet struct {
	byAlias map[string]*Allowlist
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

// Match reports whether (sni, port) is permitted by any loaded alias.
// On hit, it returns the matching alias for audit logging.
func (s *PolicySet) Match(sni string, port int) (alias string, ok bool) {
	if s == nil {
		return "", false
	}
	for _, a := range sortedAllowlists(s.byAlias) {
		if _, portOK := a.Ports[port]; !portOK {
			continue
		}
		for _, h := range a.Hostnames {
			if h.Match(sni) {
				return a.Alias, true
			}
		}
	}
	return "", false
}

func sortedAllowlists(m map[string]*Allowlist) []*Allowlist {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]*Allowlist, 0, len(keys))
	for _, k := range keys {
		out = append(out, m[k])
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
	loaded := make(map[string]*Allowlist)
	for _, path := range entries {
		a, err := loadFile(path)
		if err != nil {
			return nil, err
		}
		if _, dup := loaded[a.Alias]; dup {
			return nil, policyErr("duplicate alias %q at %s", a.Alias, path)
		}
		loaded[a.Alias] = a
	}
	return &PolicySet{byAlias: loaded}, nil
}

type rawPolicy struct {
	Alias     string   `yaml:"alias"`
	Hostnames []string `yaml:"hostnames"`
	Ports     []int    `yaml:"ports"`
}

func loadFile(path string) (*Allowlist, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw rawPolicy
	dec := yaml.NewDecoder(strings.NewReader(string(data)))
	dec.KnownFields(true)
	if err := dec.Decode(&raw); err != nil {
		return nil, policyErr("%s: invalid YAML: %s", path, err)
	}

	expectedAlias := strings.TrimSuffix(filepath.Base(path), ".yaml")
	if raw.Alias != expectedAlias {
		return nil, policyErr("%s: alias %q must match filename stem %q", path, raw.Alias, expectedAlias)
	}

	if len(raw.Hostnames) == 0 {
		return nil, policyErr("%s: 'hostnames' must be a non-empty list", path)
	}
	patterns := make([]HostPattern, 0, len(raw.Hostnames))
	for _, h := range raw.Hostnames {
		p, err := parseHost(path, h)
		if err != nil {
			return nil, err
		}
		patterns = append(patterns, p)
	}

	rawPorts := raw.Ports
	if len(rawPorts) == 0 {
		rawPorts = []int{defaultPort}
	}
	ports := make(map[int]struct{}, len(rawPorts))
	for _, p := range rawPorts {
		if p < 1 || p > 65535 {
			return nil, policyErr("%s: port %d out of range (1..65535)", path, p)
		}
		ports[p] = struct{}{}
	}

	return &Allowlist{
		Alias:     raw.Alias,
		Hostnames: patterns,
		Ports:     ports,
	}, nil
}

func parseHost(path, raw string) (HostPattern, error) {
	h := strings.ToLower(strings.TrimSpace(raw))
	if h == "" {
		return HostPattern{}, policyErr("%s: empty hostname entry", path)
	}
	if strings.HasPrefix(h, "*.") {
		suffix := h[2:]
		if !fqdnRE.MatchString(suffix) {
			return HostPattern{}, policyErr("%s: wildcard %q must be of the form *.<fqdn>", path, raw)
		}
		// Embedded '*' anywhere else is forbidden.
		if strings.Contains(suffix, "*") {
			return HostPattern{}, policyErr("%s: wildcard %q may only appear as the leftmost label", path, raw)
		}
		return HostPattern{Raw: raw, Wildcard: true, Suffix: suffix}, nil
	}
	if strings.Contains(h, "*") {
		return HostPattern{}, policyErr("%s: wildcard %q may only appear as the leftmost label (use *.example.com)", path, raw)
	}
	if !fqdnRE.MatchString(h) {
		// Single-label hostnames are also rejected — proxy targets must be FQDNs.
		if labelRE.MatchString(h) {
			return HostPattern{}, policyErr("%s: hostname %q must be an FQDN (got a single label)", path, raw)
		}
		return HostPattern{}, policyErr("%s: hostname %q is not a valid FQDN", path, raw)
	}
	return HostPattern{Raw: raw, Wildcard: false, Suffix: h}, nil
}
