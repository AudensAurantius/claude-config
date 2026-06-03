"""Egress-broker policy file loader and validator.

Loads per-alias YAML policy files from a directory (typically
``/etc/claude-config/egress-policy/``) and exposes them as a typed
in-memory ``PolicySet`` the request handler can query.

Validation matches ``sandbox/egress-policy/README.md`` exactly. The
loader is transactional: any single invalid file aborts the load
without mutating prior state.
"""

from __future__ import annotations

import fnmatch
import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

_FQDN_RE = re.compile(
    r"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))+$",
    re.IGNORECASE,
)
_PATH_FORBIDDEN_RE = re.compile(r"[^A-Za-z0-9_\-./*?+%@:,~&=]")
_HARD_CAP_BYTES = 100 * 1024 * 1024
_ALWAYS_STRIPPED_HEADERS = frozenset({"host", "authorization", "cookie", "forwarded"})


class PolicyError(ValueError):
    """A policy file failed validation."""


@dataclass(frozen=True)
class AttachSpec:
    """How a credential is attached to the upstream request."""

    type: str  # header | bearer | query
    name: str  # header name (type=header) or query key (type=query); unused for bearer


@dataclass(frozen=True)
class CredentialSpec:
    """Where to fetch the credential from."""

    backend: str  # pass | stub
    path: str
    attach: AttachSpec


@dataclass(frozen=True)
class UpstreamSpec:
    """Upstream destination the broker forwards to."""

    host: str
    port: int = 443
    scheme: str = "https"


@dataclass(frozen=True)
class Constraints:
    """Request-shape constraints the sandbox must satisfy."""

    methods: frozenset[str]
    paths: tuple[str, ...]
    max_request_bytes: int = 10 * 1024 * 1024
    timeout_seconds: int = 120
    block_request_headers: frozenset[str] = field(default_factory=frozenset)

    def path_allowed(self, path: str) -> bool:
        """Return True if ``path`` matches any allow-listed glob."""
        return any(fnmatch.fnmatchcase(path, pat) for pat in self.paths)

    def stripped_headers(self, attach: AttachSpec) -> frozenset[str]:
        """Lowercase set of header names the broker must strip before forwarding."""
        always = set(_ALWAYS_STRIPPED_HEADERS)
        always.update(h.lower() for h in self.block_request_headers)
        if attach.type == "header":
            always.add(attach.name.lower())
        # X-Forwarded-* family
        return frozenset(always)


@dataclass(frozen=True)
class Policy:
    """A single per-alias policy."""

    alias: str
    upstream: UpstreamSpec
    credential: CredentialSpec
    constraints: Constraints


@dataclass(frozen=True)
class PolicySet:
    """Collection of loaded policies, keyed by alias."""

    by_alias: dict[str, Policy]

    def get(self, alias: str) -> Policy | None:
        """Return the policy for ``alias`` or None if unknown."""
        return self.by_alias.get(alias)


def load_directory(path: Path) -> PolicySet:
    """Load and validate every ``*.yaml`` file under ``path``.

    Args:
        path: Directory containing per-alias YAML files.

    Returns:
        A populated ``PolicySet``.

    Raises:
        PolicyError: If any file fails validation. No partial state is loaded.
        FileNotFoundError: If ``path`` does not exist.
    """
    if not path.is_dir():
        raise FileNotFoundError(f"policy directory does not exist: {path}")

    loaded: dict[str, Policy] = {}
    for yaml_path in sorted(path.glob("*.yaml")):
        policy = _load_file(yaml_path)
        if policy.alias in loaded:
            raise PolicyError(f"duplicate alias '{policy.alias}' at {yaml_path}")
        loaded[policy.alias] = policy
    return PolicySet(by_alias=loaded)


def _load_file(path: Path) -> Policy:
    """Load and validate a single policy file."""
    with path.open("rb") as fp:
        raw = yaml.safe_load(fp)
    if not isinstance(raw, dict):
        raise PolicyError(f"{path}: top-level YAML must be a mapping")

    expected_alias = path.stem
    alias = raw.get("alias")
    if alias != expected_alias:
        raise PolicyError(f"{path}: alias '{alias!r}' must match filename stem '{expected_alias}'")

    upstream = _parse_upstream(path, raw.get("upstream"))
    credential = _parse_credential(path, raw.get("credential"))
    constraints = _parse_constraints(path, raw.get("constraints"), credential.attach)

    return Policy(
        alias=alias,
        upstream=upstream,
        credential=credential,
        constraints=constraints,
    )


def _parse_upstream(path: Path, raw: object) -> UpstreamSpec:
    if not isinstance(raw, dict):
        raise PolicyError(f"{path}: missing or invalid 'upstream' mapping")
    host = raw.get("host")
    if not isinstance(host, str) or not _FQDN_RE.match(host):
        raise PolicyError(f"{path}: 'upstream.host' must be a valid FQDN, got {host!r}")
    scheme = raw.get("scheme", "https")
    if scheme != "https":
        raise PolicyError(f"{path}: 'upstream.scheme' must be 'https', got {scheme!r}")
    port_raw = raw.get("port", 443)
    if not isinstance(port_raw, int) or not (1 <= port_raw <= 65535):
        raise PolicyError(f"{path}: 'upstream.port' must be int 1..65535, got {port_raw!r}")
    return UpstreamSpec(host=host, port=port_raw, scheme=scheme)


def _parse_credential(path: Path, raw: object) -> CredentialSpec:
    if not isinstance(raw, dict):
        raise PolicyError(f"{path}: missing or invalid 'credential' mapping")
    backend = raw.get("backend")
    if backend not in ("pass", "stub"):
        raise PolicyError(f"{path}: 'credential.backend' must be 'pass' or 'stub', got {backend!r}")
    cred_path = raw.get("path")
    if not isinstance(cred_path, str) or not cred_path:
        raise PolicyError(f"{path}: 'credential.path' must be a non-empty string")
    attach_raw = raw.get("attach")
    if not isinstance(attach_raw, dict):
        raise PolicyError(f"{path}: missing or invalid 'credential.attach' mapping")
    attach_type = attach_raw.get("type")
    if attach_type not in ("header", "bearer", "query"):
        raise PolicyError(
            f"{path}: 'credential.attach.type' must be header|bearer|query, got {attach_type!r}"
        )
    attach_name: str
    if attach_type == "bearer":
        attach_name = "Authorization"
    else:
        raw_name = attach_raw.get("name")
        if not isinstance(raw_name, str) or not raw_name:
            raise PolicyError(f"{path}: 'credential.attach.name' required for type={attach_type}")
        attach_name = raw_name
    return CredentialSpec(
        backend=backend,
        path=cred_path,
        attach=AttachSpec(type=attach_type, name=attach_name),
    )


def _parse_constraints(path: Path, raw: object, attach: AttachSpec) -> Constraints:
    if not isinstance(raw, dict):
        raise PolicyError(f"{path}: missing or invalid 'constraints' mapping")
    methods_raw = raw.get("methods")
    if not isinstance(methods_raw, list) or not methods_raw:
        raise PolicyError(f"{path}: 'constraints.methods' must be a non-empty list")
    methods: set[str] = set()
    for m in methods_raw:
        if not isinstance(m, str) or m != m.upper():
            raise PolicyError(f"{path}: method {m!r} must be uppercase ASCII")
        methods.add(m)
    if attach.type == "query" and methods != {"GET"}:
        raise PolicyError(f"{path}: query-string credentials only permitted with methods=[GET]")

    paths_raw = raw.get("paths")
    if not isinstance(paths_raw, list) or not paths_raw:
        raise PolicyError(f"{path}: 'constraints.paths' must be a non-empty list")
    paths: list[str] = []
    for p in paths_raw:
        if not isinstance(p, str) or not p.startswith("/"):
            raise PolicyError(f"{path}: path {p!r} must be a string starting with '/'")
        if ".." in p:
            raise PolicyError(f"{path}: path {p!r} contains forbidden '..'")
        if _PATH_FORBIDDEN_RE.search(p):
            raise PolicyError(f"{path}: path {p!r} contains forbidden characters")
        paths.append(p)

    max_bytes = raw.get("max_request_bytes", 10 * 1024 * 1024)
    if not isinstance(max_bytes, int) or max_bytes <= 0 or max_bytes > _HARD_CAP_BYTES:
        raise PolicyError(
            f"{path}: 'max_request_bytes' must be int in (0, {_HARD_CAP_BYTES}], got {max_bytes!r}"
        )

    timeout = raw.get("timeout_seconds", 120)
    if not isinstance(timeout, int) or timeout <= 0:
        raise PolicyError(f"{path}: 'timeout_seconds' must be positive int, got {timeout!r}")

    block_raw = raw.get("block_request_headers", [])
    if not isinstance(block_raw, list):
        raise PolicyError(f"{path}: 'block_request_headers' must be a list")
    block: set[str] = set()
    for h in block_raw:
        if not isinstance(h, str) or not h:
            raise PolicyError(f"{path}: blocked header {h!r} must be a non-empty string")
        block.add(h.lower())

    return Constraints(
        methods=frozenset(methods),
        paths=tuple(paths),
        max_request_bytes=max_bytes,
        timeout_seconds=timeout,
        block_request_headers=frozenset(block),
    )
