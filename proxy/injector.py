"""Inject real credentials into outbound requests.

A client requests a secret by embedding INJECT=<NAME> in a header value; we
substitute the real value in place, keeping whatever the client wrote around
it (e.g. "Bearer ..." or "token ..."). ALLOWED_SECRETS is the actual security
boundary: it pins which secret names each host may request, so a compromised
container can't ask for GITHUB_TOKEN on an api.anthropic.com request.

ALLOWED_SECRETS is configured entirely through the ALLOWED_SECRETS
environment variable, one "host=SECRET1,SECRET2" mapping per line, so this
script never needs to change to support a new host or secret.
"""
import os
import re
from pathlib import Path

from mitmproxy import ctx, http

SECRETS_DIR = Path("/run/secrets")


def _load_secrets() -> dict[str, str]:
    if not SECRETS_DIR.is_dir():
        return {}
    return {p.name: p.read_text().strip() for p in SECRETS_DIR.iterdir() if p.is_file()}


def _load_allowed_secrets() -> dict[str, set[str]]:
    allowed = {}
    for line in os.environ.get("ALLOWED_SECRETS", "").splitlines():
        host, _, names = line.partition("=")
        host = host.strip()
        if not host:
            continue
        allowed[host] = {name.strip() for name in names.split(",") if name.strip()}
    return allowed


SECRETS = _load_secrets()
ALLOWED_SECRETS = _load_allowed_secrets()

# A header value embeds this marker to request substitution, e.g. a client
# sends "token INJECT=GITHUB_TOKEN" and we replace just the marker text.
MARKER = re.compile(r"INJECT=([A-Z][A-Z0-9_]*)")


def load(loader) -> None:
    # Intercept (MITM) only the hosts ALLOWED_SECRETS configures; every other
    # host is transparently tunnelled, so nothing else needs to trust our CA.
    hosts = "|".join(re.escape(host) for host in ALLOWED_SECRETS)
    if hosts:
        ctx.options.update(allow_hosts=[rf"^({hosts})(:\d+)?$"])


def request(flow: http.HTTPFlow) -> None:
    allowed = ALLOWED_SECRETS.get(flow.request.pretty_host)
    if not allowed:
        return
    for name, value in list(flow.request.headers.items()):
        match = MARKER.search(value)
        if not match:
            continue
        secret_name = match.group(1)
        if secret_name in allowed and secret_name in SECRETS:
            flow.request.headers[name] = MARKER.sub(SECRETS[secret_name], value, count=1)
        else:
            # Unrecognized, or not authorized for this host — fail closed
            # rather than forward the marker text upstream.
            del flow.request.headers[name]
