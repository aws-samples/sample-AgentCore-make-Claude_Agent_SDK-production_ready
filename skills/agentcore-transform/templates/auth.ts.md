# Template: auth.ts

Cognito JWT authentication module for TypeScript applications.

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

/**
 * Verify token for WebSocket upgrade requests.
 * In dev mode (no Cognito config), returns anonymous user.
 */
export async function verifyWebSocketToken(token: string): Promise<any> {
  if (!COGNITO_USER_POOL_ID || !COGNITO_CLIENT_ID) {
    console.warn("[Auth] Cognito not configured, skipping WebSocket authentication");
    return { sub: "anonymous", email: "anonymous@example.com", username: "anonymous" };
  }

  const v = getVerifier();
  if (!v) throw new Error("Authentication service not configured");

  try {
    const payload = await v.verify(token);
    return {
      sub: payload.sub,
      email: payload.email,
      username: payload["cognito:username"],
    };
  } catch (error) {
    console.error("[Auth] WebSocket token verification failed:", error);
    throw new Error("Invalid or expired token");
  }
}

/**
 * Express middleware to verify Cognito JWT tokens.
 * Skips auth if Cognito is not configured (dev mode).
 */
export async function authMiddleware(
  req: any,
  res: any,
  next: any,
): Promise<void> {
  if (!COGNITO_USER_POOL_ID || !COGNITO_CLIENT_ID) {
    next();
    return;
  }

  try {
    const authHeader = req.headers.authorization;
    if (!authHeader) {
      res.status(401).json({ error: "Missing authorization token" });
      return;
    }

    const parts = authHeader.split(" ");
    const token = parts.length === 2 && parts[0] === "Bearer" ? parts[1] : parts[0];

    const v = getVerifier();
    if (!v) {
      res.status(500).json({ error: "Authentication service not configured" });
      return;
    }

    const payload = await v.verify(token);
    req.user = {
      sub: payload.sub,
      email: payload.email,
      username: payload["cognito:username"],
    };

    next();
  } catch (error) {
    console.error("[Auth] Token verification failed:", error);
    res.status(401).json({ error: "Invalid or expired token" });
  }
}
```
