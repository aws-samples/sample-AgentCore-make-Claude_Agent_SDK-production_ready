# Identity Integration Reference

Patterns for integrating AgentCore Identity (Cognito) authentication.

## Overview

AgentCore Identity uses Amazon Cognito for user authentication:

1. **Runtime User Pool** — Validates JWTs at the AgentCore platform level.
   The `customJWTAuthorizer` in `.bedrock_agentcore.yaml` points to this pool.
2. **Identity User Pool** — Optional, for credential vending (not always needed).
3. **Test Users** — Created by `agentcore identity setup-cognito` for development.

The container itself does NOT need to verify tokens (AgentCore does that),
but it decodes them to extract user identity (`actorId`).

## Cognito JWT Verifier (Optional Container-Level Auth)

For local dev or extra security, the container can verify tokens:

### TypeScript

```typescript
import { CognitoJwtVerifier } from "aws-jwt-verify";

const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID || "";
const COGNITO_CLIENT_ID = process.env.COGNITO_CLIENT_ID || "";

let verifier: ReturnType<typeof CognitoJwtVerifier.create> | null = null;

function getVerifier() {
  if (!verifier && COGNITO_USER_POOL_ID && COGNITO_CLIENT_ID) {
    verifier = CognitoJwtVerifier.create({
      userPoolId: COGNITO_USER_POOL_ID,
      tokenUse: "id",
      clientId: COGNITO_CLIENT_ID,
    });
  }
  return verifier;
}

export async function verifyWebSocketToken(token: string): Promise<any> {
  if (!COGNITO_USER_POOL_ID || !COGNITO_CLIENT_ID) {
    // Dev mode: skip verification
    return { sub: "anonymous", email: "anonymous@example.com", username: "anonymous" };
  }
  const verifier = getVerifier();
  if (!verifier) throw new Error("Auth service not configured");
  const payload = await verifier.verify(token);
  return {
    sub: payload.sub,
    email: payload.email,
    username: payload["cognito:username"],
  };
}
```

### Python

```python
import os
import jwt  # PyJWT
import requests
from functools import lru_cache

COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
COGNITO_CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID", "")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

@lru_cache()
def get_jwks():
    """Fetch Cognito JWKS for token verification."""
    if not COGNITO_USER_POOL_ID:
        return None
    url = f"https://cognito-idp.{AWS_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}/.well-known/jwks.json"
    return requests.get(url).json()

def verify_token(token: str) -> dict | None:
    """Verify a Cognito JWT token. Returns claims dict or None."""
    if not COGNITO_USER_POOL_ID or not COGNITO_CLIENT_ID:
        return {"sub": "anonymous", "email": "anonymous@example.com"}
    try:
        jwks = get_jwks()
        header = jwt.get_unverified_header(token)
        key = next(k for k in jwks["keys"] if k["kid"] == header["kid"])
        public_key = jwt.algorithms.RSAAlgorithm.from_jwk(key)
        return jwt.decode(
            token,
            public_key,
            algorithms=["RS256"],
            audience=COGNITO_CLIENT_ID,
            issuer=f"https://cognito-idp.{AWS_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}",
        )
    except Exception as e:
        print(f"[Auth] Token verification failed: {e}")
        return None
```

## ActorId Extraction

The `actorId` is the user's unique identifier, extracted from the JWT:

**Priority order:**
1. `sub` claim (Cognito user ID, most reliable)
2. `cognito:username` claim (human-readable username)
3. `"anonymous"` fallback

This actorId is passed to all Memory API calls to isolate data per user.

## WebSocket Authentication

Browsers cannot set custom headers on WebSocket connections. Two approaches:

**Approach 1: Token in query parameter (recommended for local dev)**
```
ws://host/ws?token=<jwt>
```

**Approach 2: CloudFront Function injection (recommended for production)**
CloudFront Function reads `token` from query string and injects it as
the `Authorization` header before the request reaches AgentCore.

### Token Extraction from Request

```typescript
// From Authorization header
function extractBearerToken(req: any): string | null {
  const auth = req?.headers?.authorization;
  if (!auth) return null;
  const parts = auth.split(" ");
  return parts.length === 2 && parts[0] === "Bearer" ? parts[1] : parts[0] || null;
}

// From WebSocket URL query parameter
const url = new URL(request.url || "", `http://${request.headers.host}`);
const token = url.searchParams.get("token");
```

```python
# From Authorization header
def extract_bearer_token(request) -> str | None:
    auth = request.headers.get("authorization", "")
    if not auth:
        return None
    parts = auth.split(" ")
    if len(parts) == 2 and parts[0] == "Bearer":
        return parts[1]
    return parts[0] if parts else None

# From WebSocket query parameter
token = websocket.query_params.get("token")
```

## Cognito Token Retrieval (for testing / frontend)

To get a JWT token from Cognito (used in tests and frontend login):

```bash
# Using AWS CLI
# IMPORTANT: Double-quote the entire --auth-parameters value.
# Cognito passwords often contain special chars (%, *, =, !) that get
# mangled by shell expansion if only individual values are quoted.
TOKEN=$(aws cognito-idp initiate-auth \
  --client-id "$CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USERNAME,PASSWORD=$PASSWORD" \
  --region "$REGION" \
  --query 'AuthenticationResult.IdToken' \
  --output text)
```

```typescript
// Using AWS SDK in frontend
const response = await fetch(
  `https://cognito-idp.${region}.amazonaws.com/`,
  {
    method: "POST",
    headers: { "Content-Type": "application/x-amz-json-1.1", "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth" },
    body: JSON.stringify({
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: clientId,
      AuthParameters: { USERNAME: username, PASSWORD: password },
    }),
  }
);
const data = await response.json();
const token = data.AuthenticationResult.IdToken;
```

## .bedrock_agentcore.yaml Configuration

The JWT authorizer is configured in the AgentCore YAML config:

```yaml
agents:
  my_agent:
    authorizer_configuration:
      customJWTAuthorizer:
        allowedAudience:
          - "<COGNITO_CLIENT_ID>"
        discoveryUrl: "https://cognito-idp.<REGION>.amazonaws.com/<POOL_ID>/.well-known/openid-configuration"
    request_header_configuration:
      requestHeaderAllowlist:
        - "Authorization"
```

Key notes:
- `allowedAudience` (singular, not plural) is an array of client IDs.
- `discoveryUrl` points to the OIDC discovery endpoint.
- `requestHeaderAllowlist` must include `Authorization` for the token to reach the container.

## Dependencies

**TypeScript:**
```json
{ "aws-jwt-verify": "^5.1.1" }
```

**Python:**
```
pyjwt[crypto]
requests
```
