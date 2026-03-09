# Template: auth.py

Cognito JWT authentication module for Python applications.

```python
"""
Cognito JWT authentication.

In production, AgentCore validates JWTs at the platform level.
This module provides optional container-level verification and
actor ID extraction from JWT tokens.
"""

import os
import json
import base64
import logging
from functools import lru_cache

logger = logging.getLogger(__name__)

COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
COGNITO_CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")


def decode_jwt_payload(token: str) -> dict | None:
    """Decode a JWT payload without verification.
    Safe because AgentCore's authorizer already validated the token."""
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(padded))
    except Exception:
        return None


def get_actor_id_from_token(token: str | None) -> str:
    """Extract actorId from a JWT token.
    Priority: sub > cognito:username > 'anonymous'."""
    if not token:
        return "anonymous"
    payload = decode_jwt_payload(token)
    if not payload:
        return "anonymous"
    return payload.get("sub") or payload.get("cognito:username") or "anonymous"


def extract_bearer_token(request) -> str | None:
    """Extract JWT from Authorization header (Bearer scheme)."""
    auth = None
    # Support different web frameworks
    if hasattr(request, "headers"):
        auth = request.headers.get("authorization", "")
    if not auth:
        return None
    parts = auth.split(" ")
    if len(parts) == 2 and parts[0] == "Bearer":
        return parts[1]
    return parts[0] if parts else None


# Optional: Full JWT verification using PyJWT
# Only needed if you want container-level auth (beyond AgentCore's platform auth)
try:
    import jwt
    import requests

    @lru_cache()
    def _get_jwks() -> dict | None:
        """Fetch Cognito JWKS for token verification."""
        if not COGNITO_USER_POOL_ID:
            return None
        url = (
            f"https://cognito-idp.{AWS_REGION}.amazonaws.com/"
            f"{COGNITO_USER_POOL_ID}/.well-known/jwks.json"
        )
        return requests.get(url, timeout=10).json()

    def verify_token(token: str) -> dict | None:
        """Verify a Cognito JWT token. Returns claims or None."""
        if not COGNITO_USER_POOL_ID or not COGNITO_CLIENT_ID:
            return {"sub": "anonymous", "email": "anonymous@example.com"}
        try:
            jwks = _get_jwks()
            if not jwks:
                return None
            header = jwt.get_unverified_header(token)
            key = next(k for k in jwks["keys"] if k["kid"] == header["kid"])
            public_key = jwt.algorithms.RSAAlgorithm.from_jwk(key)
            return jwt.decode(
                token,
                public_key,
                algorithms=["RS256"],
                audience=COGNITO_CLIENT_ID,
                issuer=(
                    f"https://cognito-idp.{AWS_REGION}.amazonaws.com/"
                    f"{COGNITO_USER_POOL_ID}"
                ),
            )
        except Exception as e:
            logger.error(f"[Auth] Token verification failed: {e}")
            return None

except ImportError:
    # PyJWT not installed — only decode (no verify) is available
    def verify_token(token: str) -> dict | None:
        """Fallback: decode without verification."""
        return decode_jwt_payload(token)
```
