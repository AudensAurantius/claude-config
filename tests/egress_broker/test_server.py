"""End-to-end test: real UDS, real SO_PEERCRED, stubbed upstream.

The server runs in a thread; the test acts as the sandbox client.
Because the test process IS the peer, peer_uid == os.getuid(); we
configure the server with that UID so the auth gate passes.
"""

from __future__ import annotations

import contextlib
import http.client
import os
import socket
import threading
import time
from pathlib import Path
from textwrap import dedent
from typing import Any

import pytest

from claude_config.egress_broker.credentials import StubBackend
from claude_config.egress_broker.handler import Handler
from claude_config.egress_broker.policy import load_directory
from claude_config.egress_broker.server import ServerConfig, serve
from claude_config.egress_broker.wire import encode_frame, read_frame

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
"""


class _FakeResponse:
    status = 200

    def read(self) -> bytes:
        return b'{"ok":true}'

    def getheaders(self) -> list[tuple[str, str]]:
        return [("content-type", "application/json")]


class _FakeConn:
    def __init__(self, host: str, port: int = 443, timeout: int = 0, context: Any = None) -> None:
        pass

    def request(self, method: str, path: str, body: bytes, headers: dict[str, str]) -> None:
        pass

    def getresponse(self) -> _FakeResponse:
        return _FakeResponse()

    def close(self) -> None:
        pass


@pytest.fixture
def stubbed_upstream(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(http.client, "HTTPSConnection", _FakeConn)


def _start_server(socket_path: str, peer_uid: int, handler: Handler) -> threading.Thread:
    def runner() -> None:
        try:
            serve(ServerConfig(socket_path=socket_path, expected_peer_uid=peer_uid), handler)
        except OSError:
            return

    t = threading.Thread(target=runner, daemon=True)
    t.start()
    # wait for the socket to appear
    for _ in range(50):
        if os.path.exists(socket_path):
            return t
        time.sleep(0.01)
    raise TimeoutError("server did not bind socket in time")


def test_end_to_end_request(tmp_path: Path, stubbed_upstream: None) -> None:
    policy_dir = tmp_path / "policy"
    policy_dir.mkdir()
    (policy_dir / "anthropic-api.yaml").write_text(dedent(POLICY).lstrip())
    sock_path = str(tmp_path / "broker.sock")

    policies = load_directory(policy_dir)
    handler = Handler(
        policies=policies,
        credential_backend=StubBackend({"claude-egress/anthropic/api-key": "sk-test"}),
    )
    _start_server(sock_path, os.getuid(), handler)

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(sock_path)
    client.sendall(
        encode_frame(
            {
                "alias": "anthropic-api",
                "method": "POST",
                "path": "/v1/messages",
                "headers": {"content-type": ["application/json"]},
                "body_b64": "",
            }
        )
    )
    resp = read_frame(client)
    client.close()
    assert resp["status"] == 200


def test_peer_uid_mismatch_rejects(tmp_path: Path, stubbed_upstream: None) -> None:
    policy_dir = tmp_path / "policy"
    policy_dir.mkdir()
    (policy_dir / "anthropic-api.yaml").write_text(dedent(POLICY).lstrip())
    sock_path = str(tmp_path / "broker.sock")

    policies = load_directory(policy_dir)
    handler = Handler(
        policies=policies,
        credential_backend=StubBackend({"claude-egress/anthropic/api-key": "sk-test"}),
    )
    # Configure server to expect a different UID — the test process won't match.
    bogus_uid = os.getuid() + 12345
    _start_server(sock_path, bogus_uid, handler)

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(sock_path)
    # Server should close the connection without reading anything.
    # We try to send and read; the read returns EOF or RST before any frame.
    with contextlib.suppress(BrokenPipeError):
        client.sendall(
            encode_frame(
                {
                    "alias": "anthropic-api",
                    "method": "POST",
                    "path": "/v1/messages",
                    "headers": {},
                    "body_b64": "",
                }
            )
        )
    data = b""
    with contextlib.suppress(ConnectionResetError):
        data = client.recv(1)
    client.close()
    assert data == b""  # EOF/RST, no frame returned
