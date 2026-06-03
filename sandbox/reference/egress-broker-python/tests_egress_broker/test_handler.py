"""Tests for the request handler — policy enforcement + credential attachment.

These tests stub the upstream HTTPS call (via monkeypatch of
http.client.HTTPSConnection) so they run hermetically.
"""

from __future__ import annotations

import http.client
from pathlib import Path
from textwrap import dedent
from typing import Any

import pytest

from claude_config.egress_broker.credentials import StubBackend
from claude_config.egress_broker.handler import Handler
from claude_config.egress_broker.policy import load_directory
from claude_config.egress_broker.wire import Request

POLICY = """
    alias: anthropic-api
    upstream:
      host: api.anthropic.com
      port: 443
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
"""


@pytest.fixture
def policies(tmp_path: Path) -> Any:
    (tmp_path / "anthropic-api.yaml").write_text(dedent(POLICY).lstrip())
    return load_directory(tmp_path)


@pytest.fixture
def handler(policies: Any) -> Handler:
    return Handler(
        policies=policies,
        credential_backend=StubBackend({"claude-egress/anthropic/api-key": "sk-test-secret"}),
    )


class _FakeResponse:
    def __init__(self, status: int = 200, body: bytes = b"ok") -> None:
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body

    def getheaders(self) -> list[tuple[str, str]]:
        return [("Content-Type", "application/json"), ("X-Multi", "a"), ("X-Multi", "b")]


class _FakeConn:
    last: _FakeConn | None = None

    def __init__(self, host: str, port: int, timeout: int, context: Any) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.requested: dict[str, Any] = {}
        _FakeConn.last = self

    def request(self, method: str, path: str, body: bytes, headers: dict[str, str]) -> None:
        self.requested = {"method": method, "path": path, "body": body, "headers": headers}

    def getresponse(self) -> _FakeResponse:
        return _FakeResponse()

    def close(self) -> None:
        pass


@pytest.fixture
def fake_https(monkeypatch: pytest.MonkeyPatch) -> Any:
    def factory(host: str, port: int = 443, timeout: int = 0, context: Any = None) -> _FakeConn:
        return _FakeConn(host, port, timeout, context)

    monkeypatch.setattr(http.client, "HTTPSConnection", factory)
    _FakeConn.last = None
    return _FakeConn


def _req(**overrides: Any) -> Request:
    base = {
        "alias": "anthropic-api",
        "method": "POST",
        "path": "/v1/messages",
        "headers": {"content-type": ["application/json"], "anthropic-version": ["2023-06-01"]},
        "body_b64": "",
    }
    base.update(overrides)
    return Request.from_json(base)


def test_unknown_alias_denied(handler: Handler) -> None:
    resp = handler.handle(_req(alias="unknown"))
    assert resp == {"error": "policy-denied", "message": "unknown alias: 'unknown'"}


def test_method_not_in_policy_denied(handler: Handler) -> None:
    resp = handler.handle(_req(method="GET"))
    assert resp["error"] == "policy-denied"
    assert "GET" in resp["message"]


def test_path_not_in_policy_denied(handler: Handler) -> None:
    resp = handler.handle(_req(path="/v2/messages"))
    assert resp["error"] == "policy-denied"
    assert "/v2/messages" in resp["message"]


def test_oversized_body_denied(handler: Handler) -> None:
    import base64

    big = base64.b64encode(b"x" * 2048).decode()
    resp = handler.handle(_req(body_b64=big))
    assert resp["error"] == "policy-denied"
    assert "max_request_bytes" in resp["message"]


def test_happy_path_attaches_credential(handler: Handler, fake_https: type[_FakeConn]) -> None:
    resp = handler.handle(_req())
    assert resp["status"] == 200
    assert fake_https.last is not None
    sent_headers = fake_https.last.requested["headers"]
    assert sent_headers["x-api-key"] == "sk-test-secret"
    assert sent_headers["Host"] == "api.anthropic.com"
    # anthropic-version must be stripped per block_request_headers
    assert "anthropic-version" not in {k.lower() for k in sent_headers}
    # content-type passes through
    assert sent_headers["content-type"] == "application/json"


def test_credential_not_leaked_in_request_to_sandbox(
    handler: Handler, fake_https: type[_FakeConn]
) -> None:
    # If sandbox tried to send its own x-api-key, broker must strip it before re-attaching.
    req = _req(
        headers={
            "content-type": ["application/json"],
            "x-api-key": ["sandbox-attempt-to-set-credential"],
        }
    )
    resp = handler.handle(req)
    assert resp["status"] == 200
    sent = fake_https.last.requested["headers"]  # type: ignore[union-attr]
    assert sent["x-api-key"] == "sk-test-secret"  # not the sandbox's attempt


def test_response_groups_multi_value_headers(handler: Handler, fake_https: type[_FakeConn]) -> None:
    resp = handler.handle(_req())
    # _FakeResponse emits X-Multi twice; ensure both values come back
    assert resp["headers"]["X-Multi"] == ["a", "b"]
