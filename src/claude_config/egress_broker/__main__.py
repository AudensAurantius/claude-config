r"""Command-line entry point for the Python reference egress broker.

Usage::

    claude-egress-broker-py \
        --policy-dir /etc/claude-config/egress-policy \
        --socket /run/claude-egress/broker.sock \
        --peer-uid $(id -u claude-session)

When systemd-activated, ``--socket`` is ignored and the listening fd is
inherited from systemd via the LISTEN_FDS protocol.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .credentials import select_backend
from .handler import Handler
from .policy import PolicyError, load_directory
from .server import ServerConfig, serve

logger = logging.getLogger("claude_config.egress_broker")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        prog="claude-egress-broker-py",
        description="Python reference egress broker (claude-config ciw.2).",
    )
    parser.add_argument(
        "--policy-dir",
        type=Path,
        default=Path("/etc/claude-config/egress-policy"),
        help="Directory of per-alias YAML policy files.",
    )
    parser.add_argument(
        "--socket",
        type=str,
        default=None,
        help="UDS path to bind (ignored under systemd socket activation).",
    )
    parser.add_argument(
        "--peer-uid",
        type=int,
        required=True,
        help="Expected peer UID (claude-session). Connections from other UIDs are dropped.",
    )
    parser.add_argument(
        "--loglevel",
        default="INFO",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
        help="Log verbosity.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """CLI main. Returns a process exit code."""
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(
        level=args.loglevel,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        policies = load_directory(args.policy_dir)
    except (FileNotFoundError, PolicyError) as e:
        logger.error("policy load failed: %s", e)
        return 1

    if not policies.by_alias:
        logger.error("policy directory %s contains no aliases; refusing to start", args.policy_dir)
        return 1

    # Slice 3 ships with the pass backend wired by default. Stub is reserved
    # for tests, which inject a Handler directly without going through main().
    backend = select_backend("pass")

    config = ServerConfig(socket_path=args.socket, expected_peer_uid=args.peer_uid)
    handler = Handler(policies=policies, credential_backend=backend)
    logger.info(
        "starting broker: %d aliases loaded; backend=%s; expected_peer_uid=%d",
        len(policies.by_alias),
        backend.name,
        args.peer_uid,
    )
    try:
        serve(config, handler)
    except KeyboardInterrupt:
        logger.info("interrupted; shutting down")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
