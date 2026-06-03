"""Credential backends for the egress broker.

Implements the ``CredentialBackend`` protocol with two concrete backends:

* ``PassBackend`` — production. Reads from ``pass(1)`` under
  ``/home/claude-egress/.password-store``. Requires ``gpg-agent`` to be
  unlocked (typically at broker boot via ``systemd-ask-password``).
* ``StubBackend`` — testing only. Reads from a dict supplied at
  construction. Refuses to instantiate unless explicitly requested.

The reference broker resolves a backend per-policy at request time so
policy reloads can change the backend without restarting the broker.
"""

from __future__ import annotations

import subprocess
from typing import Protocol


class CredentialError(RuntimeError):
    """Credential lookup failed."""


class CredentialBackend(Protocol):
    """Fetches a credential by its policy-declared path."""

    name: str

    def fetch(self, path: str) -> str:
        """Return the credential secret for ``path``, stripped of trailing whitespace."""
        ...


class PassBackend:
    """Production backend: shells out to ``pass show <path>``."""

    name = "pass"

    def __init__(self, pass_binary: str = "pass", timeout_seconds: int = 10) -> None:
        """Initialize with optional binary path override (defaults to ``pass`` on PATH)."""
        self._binary = pass_binary
        self._timeout = timeout_seconds

    def fetch(self, path: str) -> str:
        """Run ``pass show <path>`` and return its first line."""
        try:
            result = subprocess.run(  # noqa: S603 — controlled args, no shell
                [self._binary, "show", path],
                check=False,
                capture_output=True,
                text=True,
                timeout=self._timeout,
            )
        except subprocess.TimeoutExpired as e:
            raise CredentialError(f"pass(1) timed out fetching {path}") from e
        except FileNotFoundError as e:
            raise CredentialError(f"pass(1) binary not found: {self._binary}") from e
        if result.returncode != 0:
            raise CredentialError(
                f"pass(1) failed for {path}: exit {result.returncode}: {result.stderr.strip()}"
            )
        first_line = result.stdout.split("\n", 1)[0].rstrip()
        if not first_line:
            raise CredentialError(f"pass(1) returned empty secret for {path}")
        return first_line


class StubBackend:
    """Testing backend: returns credentials from an in-memory mapping."""

    name = "stub"

    def __init__(self, secrets: dict[str, str]) -> None:
        """Initialize with a ``{path: secret}`` mapping."""
        self._secrets = dict(secrets)

    def fetch(self, path: str) -> str:
        """Return the secret for ``path`` or raise CredentialError."""
        try:
            return self._secrets[path]
        except KeyError as e:
            raise CredentialError(f"stub backend has no credential for {path}") from e


def select_backend(
    backend_name: str, *, stub_secrets: dict[str, str] | None = None
) -> CredentialBackend:
    """Return a backend instance by name.

    Args:
        backend_name: Matches ``credential.backend`` in policy files.
        stub_secrets: Required when ``backend_name == 'stub'``.

    Raises:
        ValueError: For unknown backends or missing stub_secrets.
    """
    if backend_name == "pass":
        return PassBackend()
    if backend_name == "stub":
        if stub_secrets is None:
            raise ValueError("stub backend requires stub_secrets")
        return StubBackend(stub_secrets)
    raise ValueError(f"unknown credential backend: {backend_name!r}")
