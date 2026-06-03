"""UDS server loop with SO_PEERCRED-based peer authentication.

One-connection-per-request, blocking I/O. The reference implementation
trades concurrency for clarity; production Go implementation will use
a connection pool and async I/O.

Authentication: every accepted connection has its peer credentials
inspected via ``SO_PEERCRED``. If the peer UID does not match the
configured ``expected_peer_uid`` (claude-session's UID in production),
the connection is closed without reading a single byte.

Socket activation: if started under systemd with ``LISTEN_FDS=1`` and
``LISTEN_FDNAMES`` available, the server adopts the inherited fd
(systemd convention: first inherited fd is fd 3) instead of binding
its own. Slice-3 caveat: socket-activation wiring lives here but the
``.socket`` unit lands in slice 5.
"""

from __future__ import annotations

import contextlib
import logging
import os
import socket
import struct
from dataclasses import dataclass

from .handler import Handler
from .wire import WireError, encode_frame, read_frame

logger = logging.getLogger(__name__)

_SO_PEERCRED_STRUCT = struct.Struct("iii")  # pid, uid, gid


@dataclass
class ServerConfig:
    """Server configuration."""

    socket_path: str | None  # None means socket-activation mode
    expected_peer_uid: int
    backlog: int = 16


def serve(config: ServerConfig, handler: Handler) -> None:
    """Run the broker accept loop. Returns when the listening socket closes."""
    listener = _bind_listener(config)
    try:
        _accept_loop(listener, config, handler)
    finally:
        listener.close()


def _bind_listener(config: ServerConfig) -> socket.socket:
    """Bind a fresh UDS or adopt a systemd-inherited fd."""
    inherited = _systemd_listen_fd()
    if inherited is not None:
        logger.info("adopting systemd-inherited fd=%d", inherited)
        sock = socket.fromfd(inherited, socket.AF_UNIX, socket.SOCK_STREAM)
        os.close(inherited)
        return sock

    if config.socket_path is None:
        raise RuntimeError("no socket_path configured and no systemd-inherited fd present")
    if os.path.exists(config.socket_path):
        os.unlink(config.socket_path)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(config.socket_path)
    os.chmod(config.socket_path, 0o660)
    sock.listen(config.backlog)
    logger.info("listening on %s (mode=0660)", config.socket_path)
    return sock


def _systemd_listen_fd() -> int | None:
    """Return the inherited fd if systemd socket-activated us; otherwise None.

    Implements the LISTEN_FDS protocol. Honors LISTEN_PID so we don't
    accidentally adopt fds that belonged to a parent.
    """
    listen_pid = os.environ.get("LISTEN_PID")
    listen_fds = os.environ.get("LISTEN_FDS")
    if not listen_pid or not listen_fds:
        return None
    if int(listen_pid) != os.getpid():
        logger.warning("LISTEN_PID=%s does not match our pid=%d; ignoring", listen_pid, os.getpid())
        return None
    n = int(listen_fds)
    if n != 1:
        raise RuntimeError(f"expected exactly 1 inherited fd, got {n}")
    return 3  # systemd convention: SD_LISTEN_FDS_START


def _accept_loop(listener: socket.socket, config: ServerConfig, handler: Handler) -> None:
    """Run the per-connection accept loop."""
    while True:
        try:
            conn, _addr = listener.accept()
        except OSError as e:
            logger.error("accept() failed: %s", e)
            return
        try:
            _handle_connection(conn, config, handler)
        except Exception:  # noqa: BLE001 — top-level isolation per connection
            logger.exception("connection handler raised")
        finally:
            conn.close()


def _handle_connection(conn: socket.socket, config: ServerConfig, handler: Handler) -> None:
    """Authenticate, read one frame, dispatch, write one frame, close."""
    peer_uid = _peer_uid(conn)
    if peer_uid != config.expected_peer_uid:
        logger.warning(
            "rejecting connection: peer_uid=%d expected=%d", peer_uid, config.expected_peer_uid
        )
        return

    try:
        req_obj = read_frame(conn)
    except WireError as e:
        logger.warning("invalid request frame: %s", e)
        _send_error(conn, "bad-request", str(e))
        return

    try:
        from .wire import Request

        req = Request.from_json(req_obj)
    except WireError as e:
        logger.warning("malformed request: %s", e)
        _send_error(conn, "bad-request", str(e))
        return

    resp_obj = handler.handle(req)
    try:
        conn.sendall(encode_frame(resp_obj))
    except OSError as e:
        logger.warning("response send failed: %s", e)


def _peer_uid(conn: socket.socket) -> int:
    """Read the peer UID via SO_PEERCRED."""
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, _SO_PEERCRED_STRUCT.size)
    _pid, uid, _gid = _SO_PEERCRED_STRUCT.unpack(raw)
    return int(uid)


def _send_error(conn: socket.socket, code: str, message: str) -> None:
    """Best-effort send of an error envelope; ignore secondary I/O failures."""
    with contextlib.suppress(OSError):
        conn.sendall(encode_frame({"error": code, "message": message}))
