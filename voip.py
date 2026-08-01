"""VoIP pushes, so the phone can ring without ATARU being open.

A VoIP push is not a notification. It wakes the app in the background with no
UI at all, and the app is then *required* to report an incoming call to
CallKit. From iOS 13 an app that takes a VoIP push and does not report a call
gets terminated, and a repeat offender loses the entitlement altogether. That
contract shapes this module: it only ever sends a push when the intent really
is "ring this phone now".

Why this direction is safe for a machine that refuses inbound connections:
the Orin opens an *outbound* HTTPS connection to Apple. Nothing here listens on
the public internet, so no port forward and no Tailscale Funnel is needed, and
the no-public-exposure rule stays intact.

Credentials come from a token-signing key (.p8) downloaded once from the Apple
developer account. It is a secret: keep it out of the repo and out of the
image, and mount it at run time.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass, asdict
from pathlib import Path

import config


# --- Device registry ---------------------------------------------------------
#
# Deliberately a small JSON file rather than a table in the vector store: this
# is a handful of rows of operational state, it has nothing to do with the
# documents, and it needs to survive a re-index.

@dataclass(frozen=True)
class Device:
    token: str
    # "sandbox" for anything Xcode installed, "production" for TestFlight or
    # the App Store. Sending to the wrong host fails with BadDeviceToken, which
    # is the single most common reason a correct-looking setup never rings.
    environment: str
    name: str = ""
    registered_at: float = 0.0


def _registry_path() -> Path:
    return Path(config.DATA_DIR) / "voip_devices.json"


def load_devices() -> list[Device]:
    path = _registry_path()
    if not path.exists():
        return []
    try:
        raw = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return []
    return [Device(**row) for row in raw if "token" in row]


def save_device(token: str, environment: str = "sandbox", name: str = "") -> Device:
    """Adds or replaces a device. Re-registering is normal: iOS issues a new
    token after a reinstall or a restore, and the old one silently stops
    working, so the token is the identity and a repeat registration replaces."""
    device = Device(
        token=token,
        environment=environment if environment in ("sandbox", "production") else "sandbox",
        name=name,
        registered_at=time.time(),
    )
    others = [d for d in load_devices() if d.token != token]
    path = _registry_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps([asdict(d) for d in others + [device]], indent=2))
    return device


def forget_device(token: str) -> bool:
    remaining = [d for d in load_devices() if d.token != token]
    if len(remaining) == len(load_devices()):
        return False
    _registry_path().write_text(json.dumps([asdict(d) for d in remaining], indent=2))
    return True


# --- APNs --------------------------------------------------------------------

def configuration_status() -> dict:
    """Whether this host is able to ring anything, checkable before a phone has
    ever registered.

    Without this the only way to find out is to send a real push, which needs a
    registered device — so a misconfigured key stays invisible until the moment
    you actually want the phone to ring. Reports presence and readability
    separately because the container runs as a different uid than the user who
    copied the key in, and "the file is there but I cannot read it" is the
    failure that actually happens.
    """
    key = Path(config.APNS_KEY_PATH) if config.APNS_KEY_PATH else None
    exists = bool(key and key.exists())
    return {
        "key_path": config.APNS_KEY_PATH or None,
        "key_present": exists,
        # os.access as the container's own uid — the honest question is not
        # what the mode bits say but whether this process can open it.
        "key_readable": exists and os.access(key, os.R_OK),
        "key_id_set": bool(config.APNS_KEY_ID),
        "team_id_set": bool(config.APNS_TEAM_ID),
        "topic": f"{config.APNS_BUNDLE_ID}.voip" if config.APNS_BUNDLE_ID else None,
        "ready": bool(
            exists
            and os.access(key, os.R_OK)
            and config.APNS_KEY_ID
            and config.APNS_TEAM_ID
            and config.APNS_BUNDLE_ID
        ),
    }


class PushError(RuntimeError):
    """Raised with Apple's own reason string where there is one — 'BadDeviceToken'
    and 'TopicDisallowed' each point at a specific misconfiguration, and
    flattening them into 'push failed' throws away the diagnosis."""


_token_cache: tuple[str, float] | None = None


def _auth_token() -> str:
    """Signs the JWT APNs wants. Cached: Apple rejects tokens regenerated more
    than once every 20 minutes, and they stay valid for an hour."""
    global _token_cache
    if _token_cache and time.time() - _token_cache[1] < 30 * 60:
        return _token_cache[0]

    # Local imports, and the failure is translated rather than allowed to
    # escape: an ImportError here surfaces as a bare 500 with no body, which is
    # the least diagnosable failure this service can produce.
    try:
        import jwt
    except ImportError as exc:
        raise PushError(
            "PyJWT is not installed in this image. It is in "
            "requirements-docker.txt — rebuild with "
            "`docker compose up -d --build api`."
        ) from exc

    key_path = Path(config.APNS_KEY_PATH) if config.APNS_KEY_PATH else None
    if not key_path or not key_path.exists():
        raise PushError(
            f"No APNs signing key. Set RAG_APNS_KEY_PATH to the .p8 file "
            f"(currently {config.APNS_KEY_PATH or 'unset'})."
        )
    if not config.APNS_KEY_ID or not config.APNS_TEAM_ID:
        raise PushError("RAG_APNS_KEY_ID and RAG_APNS_TEAM_ID must both be set.")

    token = jwt.encode(
        {"iss": config.APNS_TEAM_ID, "iat": int(time.time())},
        key_path.read_text(),
        algorithm="ES256",
        headers={"kid": config.APNS_KEY_ID},
    )
    _token_cache = (token, time.time())
    return token


def _host(environment: str) -> str:
    return (
        "https://api.push.apple.com"
        if environment == "production"
        else "https://api.sandbox.push.apple.com"
    )


def ring(reason: str = "", devices: list[Device] | None = None) -> list[dict]:
    """Rings every registered phone. Returns one result row per device.

    Failures are collected rather than raised, so one dead token — a phone that
    was wiped, say — does not stop the others from ringing.
    """
    try:
        import httpx
    except ImportError as exc:
        raise PushError(
            "httpx is not installed in this image. Rebuild with "
            "`docker compose up -d --build api`."
        ) from exc

    targets = devices if devices is not None else load_devices()
    if not targets:
        raise PushError(
            "No devices registered. Open ATARU on the phone once with the "
            "server reachable; it registers itself on launch."
        )

    payload = {
        "caller": "ATARU",
        "reason": reason,
        # Lets the client tie a push to a call and ignore a duplicate, since
        # APNs makes no delivery-exactly-once promise.
        "callId": str(uuid.uuid4()),
    }
    headers_base = {
        "authorization": f"bearer {_auth_token()}",
        "apns-topic": f"{config.APNS_BUNDLE_ID}.voip",  # the .voip suffix is required
        "apns-push-type": "voip",
        "apns-priority": "10",
        "apns-expiration": "0",  # ring now or not at all; a late call is worse than none
    }

    results = []
    # http2 is not optional: APNs speaks nothing else. httpx raises ImportError
    # here, not at import time, when the h2 package is absent.
    try:
        client_cm = httpx.Client(http2=True, timeout=10.0)
    except ImportError as exc:
        raise PushError(
            "HTTP/2 support is missing (the `h2` package). APNs accepts nothing "
            "else. Rebuild with `docker compose up -d --build api`."
        ) from exc

    with client_cm as client:
        for device in targets:
            url = f"{_host(device.environment)}/3/device/{device.token}"
            try:
                response = client.post(url, json=payload, headers=headers_base)
                ok = response.status_code == 200
                detail = "" if ok else _explain(response)
                results.append({
                    "token": device.token[:12] + "…",
                    "environment": device.environment,
                    "ok": ok,
                    "status": response.status_code,
                    "detail": detail,
                })
            except httpx.HTTPError as exc:
                results.append({
                    "token": device.token[:12] + "…",
                    "environment": device.environment,
                    "ok": False,
                    "status": 0,
                    "detail": str(exc),
                })
    return results


def _explain(response) -> str:
    try:
        reason = response.json().get("reason", "")
    except (json.JSONDecodeError, ValueError):
        return response.text[:200]

    hints = {
        "BadDeviceToken": (
            "the token is for the other APNs environment — an Xcode build is "
            "'sandbox', TestFlight and the App Store are 'production'"
        ),
        "TopicDisallowed": "apns-topic must be the bundle id with '.voip' appended",
        "ExpiredProviderToken": "the signing JWT aged out; it is refreshed every 30 minutes",
        "InvalidProviderToken": "the .p8 key, key id and team id do not agree",
        "DeviceTokenNotForTopic": "this token belongs to a different app",
        "Unregistered": "the app was removed from that device",
    }
    hint = hints.get(reason)
    return f"{reason} — {hint}" if hint else reason
