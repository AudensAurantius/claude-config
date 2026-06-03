"""Wire protocol for the egress broker UDS.

Each request/response is a single length-prefixed JSON frame:

    +--------+--------------------------------+
    | u32 BE | JSON bytes (max 100 MiB)       |
    +--------+--------------------------------+

The reference implementation does NOT stream bodies — a request is read
whole, the upstream call is made whole, the response is returned whole.
This is adequate for the request shapes the sandbox makes (chat
completions are kilobytes; the broker is not in the data-plane for
large transfers). Production Go implementation may add streaming.

Request JSON shape (sandbox -> broker)::

    {
      "alias":   "anthropic-api",
      "method":  "POST",
      "path":    "/v1/messages",
      "headers": {"content-type": ["application/json"], ...},
      "body_b64": "<base64-encoded body, may be empty string>"
    }

Response JSON shape (broker -> sandbox)::

    {
      "status":  200,
      "headers": {"content-type": ["application/json"], ...},
      "body_b64": "<base64-encoded body>"
    }

Error response (broker -> sandbox)::

    {
      "error":   "policy-denied" | "upstream-failed" | "bad-request",
      "message": "human-readable detail"
    }
"""

from __future__ import annotations

import base64
import json
import socket
import struct
from dataclasses import dataclass
from typing import Any

MAX_FRAME_BYTES = 100 * 1024 * 1024
_LEN_STRUCT = struct.Struct("!I")


class WireError(ValueError):
    """A wire-format violation."""


@dataclass(frozen=True)
class Request:
    """A parsed sandbox request."""

    alias: str
    method: str
    path: str
    headers: dict[str, list[str]]
    body: bytes

    @classmethod
    def from_json(cls, obj: dict[str, Any]) -> Request:
        """Validate-and-construct from a parsed JSON object."""
        try:
            alias = obj["alias"]
            method = obj["method"]
            path = obj["path"]
            headers_raw = obj["headers"]
            body_b64 = obj["body_b64"]
        except KeyError as e:
            raise WireError(f"missing required field: {e.args[0]}") from None
        if not isinstance(alias, str) or not alias:
            raise WireError("'alias' must be a non-empty string")
        if not isinstance(method, str) or method != method.upper():
            raise WireError("'method' must be uppercase ASCII")
        if not isinstance(path, str) or not path.startswith("/"):
            raise WireError("'path' must be a string starting with '/'")
        if not isinstance(headers_raw, dict):
            raise WireError("'headers' must be an object")
        headers: dict[str, list[str]] = {}
        for k, v in headers_raw.items():
            if not isinstance(k, str):
                raise WireError("header names must be strings")
            if not isinstance(v, list) or not all(isinstance(s, str) for s in v):
                raise WireError(f"header values for {k!r} must be a list of strings")
            headers[k] = list(v)
        if not isinstance(body_b64, str):
            raise WireError("'body_b64' must be a string")
        try:
            body = base64.b64decode(body_b64, validate=True) if body_b64 else b""
        except ValueError as e:
            raise WireError(f"'body_b64' is not valid base64: {e}") from None
        return cls(alias=alias, method=method, path=path, headers=headers, body=body)


@dataclass(frozen=True)
class Response:
    """A broker response to forward back to the sandbox."""

    status: int
    headers: dict[str, list[str]]
    body: bytes

    def to_json(self) -> dict[str, Any]:
        """Serialize to the wire JSON shape."""
        return {
            "status": self.status,
            "headers": self.headers,
            "body_b64": base64.b64encode(self.body).decode("ascii"),
        }


def encode_frame(payload: dict[str, Any]) -> bytes:
    """Encode a JSON payload as a length-prefixed frame."""
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if len(body) > MAX_FRAME_BYTES:
        raise WireError(f"frame body {len(body)} exceeds MAX_FRAME_BYTES={MAX_FRAME_BYTES}")
    return _LEN_STRUCT.pack(len(body)) + body


def read_frame(sock: socket.socket) -> dict[str, Any]:
    """Read one length-prefixed JSON frame from ``sock``.

    Raises:
        WireError: On short read, oversized frame, or invalid JSON.
    """
    header = _recv_exact(sock, _LEN_STRUCT.size)
    (length,) = _LEN_STRUCT.unpack(header)
    if length > MAX_FRAME_BYTES:
        raise WireError(f"declared frame length {length} exceeds MAX_FRAME_BYTES")
    body = _recv_exact(sock, length)
    try:
        obj = json.loads(body)
    except json.JSONDecodeError as e:
        raise WireError(f"frame body is not valid JSON: {e}") from None
    if not isinstance(obj, dict):
        raise WireError("frame body must be a JSON object")
    return obj


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    """Read exactly ``n`` bytes from ``sock`` or raise WireError."""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise WireError(f"short read: wanted {n} bytes, got {len(buf)} before EOF")
        buf.extend(chunk)
    return bytes(buf)
