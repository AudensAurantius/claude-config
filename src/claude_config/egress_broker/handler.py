"""Request handler — policy enforcement and upstream HTTPS forwarding.

The handler is the integration point between the wire protocol, the
policy set, and the credential backend. It does NOT bind to the socket
(see ``server.py``) — that decoupling keeps the policy logic unit-testable
without spinning up a UDS.
"""

from __future__ import annotations

import http.client
import logging
import ssl
import urllib.parse
from dataclasses import dataclass
from typing import Any

from .credentials import CredentialBackend, CredentialError
from .policy import Policy, PolicySet
from .wire import Request, Response

logger = logging.getLogger(__name__)


@dataclass
class Handler:
    """Stateful handler bundling policy + credential backend."""

    policies: PolicySet
    credential_backend: CredentialBackend
    ssl_context: ssl.SSLContext | None = None

    def __post_init__(self) -> None:
        """Build an SSLContext if the caller didn't supply one."""
        if self.ssl_context is None:
            self.ssl_context = ssl.create_default_context()

    def handle(self, req: Request) -> dict[str, Any]:
        """Process a single sandbox request and return a wire response JSON.

        Returns a JSON object suitable for ``encode_frame``. The returned
        object is either a successful ``Response.to_json()`` or an error
        envelope ``{"error": <code>, "message": <detail>}``.
        """
        policy = self.policies.get(req.alias)
        if policy is None:
            return _err("policy-denied", f"unknown alias: {req.alias!r}")

        denial = _check_policy(req, policy)
        if denial is not None:
            return _err("policy-denied", denial)

        try:
            secret = self.credential_backend.fetch(policy.credential.path)
        except CredentialError as e:
            logger.error("credential fetch failed for alias=%s: %s", req.alias, e)
            return _err("upstream-failed", "credential backend failure")

        headers, path = _build_outbound(req, policy, secret)

        try:
            resp = _do_upstream(
                policy=policy,
                method=req.method,
                path=path,
                headers=headers,
                body=req.body,
                ssl_context=self.ssl_context,
            )
        except (OSError, http.client.HTTPException, ssl.SSLError) as e:
            logger.error("upstream call failed for alias=%s: %s", req.alias, e)
            return _err("upstream-failed", f"{type(e).__name__}: {e}")

        return resp.to_json()


def _check_policy(req: Request, policy: Policy) -> str | None:
    """Return a denial reason or None if the request is allowed."""
    if req.method not in policy.constraints.methods:
        return f"method {req.method!r} not in allowed methods {sorted(policy.constraints.methods)}"
    # path may include a querystring; check the path portion only against globs
    parsed = urllib.parse.urlsplit(req.path)
    if not policy.constraints.path_allowed(parsed.path):
        return f"path {parsed.path!r} not in allowed paths {list(policy.constraints.paths)}"
    if len(req.body) > policy.constraints.max_request_bytes:
        return (
            f"request body {len(req.body)} bytes exceeds max_request_bytes "
            f"{policy.constraints.max_request_bytes}"
        )
    return None


def _build_outbound(req: Request, policy: Policy, secret: str) -> tuple[dict[str, str], str]:
    """Construct the outbound header dict and path with credential attached."""
    stripped = policy.constraints.stripped_headers(policy.credential.attach)
    out_headers: dict[str, str] = {}
    for name, values in req.headers.items():
        if name.lower() in stripped:
            continue
        # http.client accepts a flat dict; collapse multi-value with comma per RFC 7230.
        out_headers[name] = ", ".join(values)
    out_headers["Host"] = policy.upstream.host

    attach = policy.credential.attach
    path = req.path
    if attach.type == "header":
        out_headers[attach.name] = secret
    elif attach.type == "bearer":
        out_headers["Authorization"] = f"Bearer {secret}"
    elif attach.type == "query":
        path = _append_query(path, attach.name, secret)
    return out_headers, path


def _append_query(path: str, key: str, value: str) -> str:
    """Append ``key=value`` to ``path``'s querystring."""
    parts = urllib.parse.urlsplit(path)
    query = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    query.append((key, value))
    new_query = urllib.parse.urlencode(query)
    return urllib.parse.urlunsplit(("", "", parts.path, new_query, parts.fragment))


def _do_upstream(
    *,
    policy: Policy,
    method: str,
    path: str,
    headers: dict[str, str],
    body: bytes,
    ssl_context: ssl.SSLContext | None,
) -> Response:
    """Issue the upstream HTTPS request synchronously and return a ``Response``."""
    conn = http.client.HTTPSConnection(
        policy.upstream.host,
        port=policy.upstream.port,
        timeout=policy.constraints.timeout_seconds,
        context=ssl_context,
    )
    try:
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        body_out = resp.read()
        # http.client gives us a flat list of (name, value) pairs; group by name
        # so the wire response can carry multi-valued headers faithfully.
        grouped: dict[str, list[str]] = {}
        for name, value in resp.getheaders():
            grouped.setdefault(name, []).append(value)
        return Response(status=resp.status, headers=grouped, body=body_out)
    finally:
        conn.close()


def _err(code: str, message: str) -> dict[str, str]:
    """Build an error envelope for the wire."""
    return {"error": code, "message": message}
