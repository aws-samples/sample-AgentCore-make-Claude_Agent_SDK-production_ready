import { CognitoJwtVerifier } from "aws-jwt-verify";
import type { Request, Response, NextFunction } from "express";

/**
 * Cognito authentication middleware for AgentCore Runtime
 * Verifies JWT tokens from Cognito User Pool
 */

// Environment variables for Cognito configuration
// These will be set during deployment via the toolkit
const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID || "";
const COGNITO_CLIENT_ID = process.env.COGNITO_CLIENT_ID || "";
const AWS_REGION = process.env.AWS_REGION || "us-east-1";

// Create JWT verifier instance
let verifier: ReturnType<typeof CognitoJwtVerifier.create> | null = null;

/**
 * Initialize the Cognito JWT verifier
 */
function getVerifier() {
  if (!verifier && COGNITO_USER_POOL_ID && COGNITO_CLIENT_ID) {
    verifier = CognitoJwtVerifier.create({
      userPoolId: COGNITO_USER_POOL_ID,
      tokenUse: "id", // or "access" depending on your use case
      clientId: COGNITO_CLIENT_ID,
    });
  }
  return verifier;
}

/**
 * Extract JWT token from Authorization header
 */
function extractToken(req: Request): string | null {
  const authHeader = req.headers.authorization;
  if (!authHeader) {
    return null;
  }

  // Support both "Bearer <token>" and just "<token>"
  const parts = authHeader.split(" ");
  if (parts.length === 2 && parts[0] === "Bearer") {
    return parts[1];
  } else if (parts.length === 1) {
    return parts[0];
  }

  return null;
}

/**
 * Express middleware to verify Cognito JWT tokens
 */
export async function authMiddleware(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  // Skip auth in development if Cognito is not configured
  if (!COGNITO_USER_POOL_ID || !COGNITO_CLIENT_ID) {
    console.warn("[Auth] Cognito not configured, skipping authentication");
    next();
    return;
  }

  try {
    const token = extractToken(req);
    if (!token) {
      res.status(401).json({ error: "Missing authorization token" });
      return;
    }

    const verifier = getVerifier();
    if (!verifier) {
      res.status(500).json({ error: "Authentication service not configured" });
      return;
    }

    // Verify the JWT token
    const payload = await verifier.verify(token);

    // Attach user info to request for downstream handlers
    (req as any).user = {
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

/**
 * Express middleware to verify Cognito JWT tokens from query parameter
 * Used for WebSocket connections where headers are not easily accessible
 */
export async function authMiddlewareQuery(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  // Skip auth in development if Cognito is not configured
  if (!COGNITO_USER_POOL_ID || !COGNITO_CLIENT_ID) {
    console.warn("[Auth] Cognito not configured, skipping authentication");
    next();
    return;
  }

  try {
    const token = req.query.token as string;
    if (!token) {
      res.status(401).json({ error: "Missing authorization token" });
      return;
    }

    const verifier = getVerifier();
    if (!verifier) {
      res.status(500).json({ error: "Authentication service not configured" });
      return;
    }

    // Verify the JWT token
    const payload = await verifier.verify(token);

    // Attach user info to request for downstream handlers
    (req as any).user = {
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

/**
 * Verify token for WebSocket upgrade requests
 */
export async function verifyWebSocketToken(token: string): Promise<any> {
  if (!COGNITO_USER_POOL_ID || !COGNITO_CLIENT_ID) {
    console.warn("[Auth] Cognito not configured, skipping WebSocket authentication");
    return { sub: "anonymous", email: "anonymous@example.com", username: "anonymous" };
  }

  const verifier = getVerifier();
  if (!verifier) {
    throw new Error("Authentication service not configured");
  }

  try {
    const payload = await verifier.verify(token);
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
