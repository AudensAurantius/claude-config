"""Tests for the wire protocol framing and Request/Response shapes."""

from __future__ import annotations

import base64
import json
import socket

import pytest

from claude_config.egress_broker.wire import (
    Request,
    Response,
    WireError,
    encode_frame,
    read_frame,
)


def _socket_pair() -> tuple[socket.socket, socket.socket]:
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    return a, b


def test_encode_and_read_roundtrip() -> None:
    payload = {"hello": "world", "n": [1, 2, 3]}
    frame = encode_frame(payload)
    a, b = _socket_pair()
    try:
        a.sendall(frame)
        a.close()
        decoded = read_frame(b)
    finally:
        b.close()
    assert decoded == payload


def test_request_from_json_happy_path() -> None:
    obj = {
        "alias": "anthropic-api",
        "method": "POST",
        "path": "/v1/messages",
        "headers": {"content-type": ["application/json"]},
        "body_b64": base64.b64encode(b'{"x":1}').decode("ascii"),
    }
    req = Request.from_json(obj)
    assert req.alias == "anthropic-api"
    assert req.method == "POST"
    assert req.body == b'{"x":1}'


def test_request_rejects_lowercase_method() -> None:
    obj = {
        "alias": "x",
        "method": "post",
        "path": "/v1/messages",
        "headers": {},
        "body_b64": "",
    }
    with pytest.raises(WireError, match="uppercase"):
        Request.from_json(obj)


def test_request_rejects_path_without_slash() -> None:
    obj = {
        "alias": "x",
        "method": "POST",
        "path": "v1/messages",
        "headers": {},
        "body_b64": "",
    }
    with pytest.raises(WireError, match="starting with '/'"):
        Request.from_json(obj)


def test_request_rejects_missing_field() -> None:
    with pytest.raises(WireError, match="missing required field: alias"):
        Request.from_json({"method": "POST", "path": "/x", "headers": {}, "body_b64": ""})


def test_request_rejects_bad_base64() -> None:
    obj = {
        "alias": "x",
        "method": "POST",
        "path": "/x",
        "headers": {},
        "body_b64": "not!valid!base64!",
    }
    with pytest.raises(WireError, match="base64"):
        Request.from_json(obj)


def test_response_to_json_roundtrips_through_frame() -> None:
    resp = Response(status=200, headers={"x-foo": ["a", "b"]}, body=b"\x00\x01\x02")
    frame = encode_frame(resp.to_json())
    a, b = _socket_pair()
    try:
        a.sendall(frame)
        a.close()
        decoded = read_frame(b)
    finally:
        b.close()
    assert decoded["status"] == 200
    assert decoded["headers"] == {"x-foo": ["a", "b"]}
    assert base64.b64decode(decoded["body_b64"]) == b"\x00\x01\x02"


def test_read_frame_short_read_errors() -> None:
    a, b = _socket_pair()
    try:
        a.sendall(b"\x00\x00\x00\x05hi")  # claims 5 bytes; sends 2
        a.close()
        with pytest.raises(WireError, match="short read"):
            read_frame(b)
    finally:
        b.close()


def test_read_frame_invalid_json_errors() -> None:
    a, b = _socket_pair()
    try:
        bad = b"not json"
        a.sendall(len(bad).to_bytes(4, "big") + bad)
        a.close()
        with pytest.raises(WireError, match="not valid JSON"):
            read_frame(b)
    finally:
        b.close()


def test_read_frame_oversized_declared_length_errors() -> None:
    a, b = _socket_pair()
    try:
        a.sendall((200 * 1024 * 1024).to_bytes(4, "big"))
        a.close()
        with pytest.raises(WireError, match="MAX_FRAME_BYTES"):
            read_frame(b)
    finally:
        b.close()


def test_read_frame_requires_object_not_array() -> None:
    a, b = _socket_pair()
    try:
        body = json.dumps([1, 2, 3]).encode()
        a.sendall(len(body).to_bytes(4, "big") + body)
        a.close()
        with pytest.raises(WireError, match="must be a JSON object"):
            read_frame(b)
    finally:
        b.close()
