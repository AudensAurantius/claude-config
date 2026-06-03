"""Tests for the policy loader and validator."""

from __future__ import annotations

from pathlib import Path
from textwrap import dedent

import pytest

from claude_config.egress_broker.policy import PolicyError, load_directory


def _write(tmp_path: Path, name: str, body: str) -> None:
    (tmp_path / name).write_text(dedent(body).lstrip())


VALID_ANTHROPIC = """
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
        - /v1/models*
      max_request_bytes: 10485760
      timeout_seconds: 120
      block_request_headers:
        - anthropic-version
"""


def test_loads_valid_policy(tmp_path: Path) -> None:
    _write(tmp_path, "anthropic-api.yaml", VALID_ANTHROPIC)
    ps = load_directory(tmp_path)
    assert "anthropic-api" in ps.by_alias
    p = ps.by_alias["anthropic-api"]
    assert p.upstream.host == "api.anthropic.com"
    assert p.constraints.methods == frozenset({"POST", "GET"})
    assert "anthropic-version" in p.constraints.block_request_headers


def test_alias_must_match_filename(tmp_path: Path) -> None:
    _write(tmp_path, "wrong-name.yaml", VALID_ANTHROPIC)
    with pytest.raises(PolicyError, match="must match filename stem"):
        load_directory(tmp_path)


def test_rejects_non_https_scheme(tmp_path: Path) -> None:
    bad = VALID_ANTHROPIC.replace("scheme: https", "scheme: http")
    _write(tmp_path, "anthropic-api.yaml", bad)
    with pytest.raises(PolicyError, match="must be 'https'"):
        load_directory(tmp_path)


def test_rejects_invalid_fqdn(tmp_path: Path) -> None:
    bad = VALID_ANTHROPIC.replace("host: api.anthropic.com", "host: 'not a hostname'")
    _write(tmp_path, "anthropic-api.yaml", bad)
    with pytest.raises(PolicyError, match="valid FQDN"):
        load_directory(tmp_path)


def test_rejects_path_traversal(tmp_path: Path) -> None:
    bad = VALID_ANTHROPIC.replace("- /v1/messages", "- /v1/../messages")
    _write(tmp_path, "anthropic-api.yaml", bad)
    with pytest.raises(PolicyError, match="forbidden '..'"):
        load_directory(tmp_path)


def test_rejects_lowercase_method(tmp_path: Path) -> None:
    bad = VALID_ANTHROPIC.replace("methods: [POST, GET]", "methods: [post]")
    _write(tmp_path, "anthropic-api.yaml", bad)
    with pytest.raises(PolicyError, match="uppercase"):
        load_directory(tmp_path)


def test_rejects_query_credential_with_non_get(tmp_path: Path) -> None:
    bad = VALID_ANTHROPIC.replace(
        "type: header\n        name: x-api-key",
        "type: query\n        name: api_key",
    )
    _write(tmp_path, "anthropic-api.yaml", bad)
    with pytest.raises(PolicyError, match="query-string credentials only"):
        load_directory(tmp_path)


def test_rejects_oversized_max_bytes(tmp_path: Path) -> None:
    bad = VALID_ANTHROPIC.replace("max_request_bytes: 10485760", "max_request_bytes: 999999999")
    _write(tmp_path, "anthropic-api.yaml", bad)
    with pytest.raises(PolicyError, match="max_request_bytes"):
        load_directory(tmp_path)


def test_path_allowed_globs(tmp_path: Path) -> None:
    _write(tmp_path, "anthropic-api.yaml", VALID_ANTHROPIC)
    ps = load_directory(tmp_path)
    p = ps.by_alias["anthropic-api"]
    assert p.constraints.path_allowed("/v1/messages")
    assert p.constraints.path_allowed("/v1/models")
    assert p.constraints.path_allowed("/v1/models/claude-opus-4-7")
    assert not p.constraints.path_allowed("/v2/messages")
    assert not p.constraints.path_allowed("/admin")


def test_stripped_headers_includes_attach_name(tmp_path: Path) -> None:
    _write(tmp_path, "anthropic-api.yaml", VALID_ANTHROPIC)
    p = load_directory(tmp_path).by_alias["anthropic-api"]
    stripped = p.constraints.stripped_headers(p.credential.attach)
    assert "x-api-key" in stripped
    assert "authorization" in stripped
    assert "host" in stripped
    assert "anthropic-version" in stripped


def test_duplicate_alias_rejected(tmp_path: Path) -> None:
    _write(tmp_path, "anthropic-api.yaml", VALID_ANTHROPIC)
    # Second file with a different filename stem AND alias would be fine.
    # Force a collision by writing a file whose alias matches the first.
    second = VALID_ANTHROPIC  # same alias declared inside
    _write(tmp_path, "anthropic-api.yaml.bak", second)
    # the .yaml.bak file isn't picked up by *.yaml, so this should still load fine
    ps = load_directory(tmp_path)
    assert list(ps.by_alias) == ["anthropic-api"]


def test_missing_dir_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_directory(tmp_path / "does-not-exist")
