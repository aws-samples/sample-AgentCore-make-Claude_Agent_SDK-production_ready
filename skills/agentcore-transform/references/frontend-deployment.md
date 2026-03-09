# Frontend Deployment Reference

Patterns for deploying a frontend to S3 + CloudFront with AgentCore backend routing.

## Architecture

```
Browser
  |
  v
CloudFront Distribution
  ├── /* (default)         -> S3 Bucket (static frontend)
  ├── /invocations*        -> AgentCore Runtime (REST API)
  └── /ws*                 -> AgentCore Runtime (WebSocket)
```

CloudFront serves everything from a single domain, eliminating CORS issues.
A CloudFront Function handles WebSocket token-to-header injection.

## CloudFormation Template

The `infra/template.yaml` creates:
1. S3 bucket (private, with OAC access policy).
2. CloudFront Origin Access Control (OAC).
3. CloudFront Function for token injection.
4. CloudFront distribution with 3 origins and cache behaviors.

### Template Structure

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: "Frontend hosting with AgentCore backend routing"

Parameters:
  EncodedAgentArn:
    Type: String
    Description: "URL-encoded AgentCore agent ARN"
  AwsRegion:
    Type: String
    Default: "us-east-1"

Resources:
  # S3 Bucket for static files
  FrontendBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${AWS::StackName}-frontend-${AWS::AccountId}"
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true

  # Bucket policy for OAC
  FrontendBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref FrontendBucket
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: cloudfront.amazonaws.com
            Action: s3:GetObject
            Resource: !Sub "${FrontendBucket.Arn}/*"
            Condition:
              StringEquals:
                AWS:SourceArn: !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${CloudFrontDistribution}"

  # Origin Access Control
  OAC:
    Type: AWS::CloudFront::OriginAccessControl
    Properties:
      OriginAccessControlConfig:
        Name: !Sub "${AWS::StackName}-oac"
        OriginAccessControlOriginType: s3
        SigningBehavior: always
        SigningProtocol: sigv4

  # CloudFront Function for WebSocket token injection
  TokenInjectionFunction:
    Type: AWS::CloudFront::Function
    Properties:
      Name: !Sub "${AWS::StackName}-token-inject"
      AutoPublish: true
      FunctionCode: |
        function handler(event) {
          var request = event.request;
          var qs = request.querystring;
          if (qs.token && qs.token.value) {
            request.headers['authorization'] = { value: 'Bearer ' + qs.token.value };
          }
          return request;
        }
      FunctionConfig:
        Comment: "Inject token query param as Authorization header for WebSocket"
        Runtime: cloudfront-js-2.0

  # CloudFront Distribution
  CloudFrontDistribution:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Enabled: true
        DefaultRootObject: index.html
        HttpVersion: http2and3

        Origins:
          # S3 origin for static files
          - Id: S3Origin
            DomainName: !GetAtt FrontendBucket.RegionalDomainName
            OriginAccessControlId: !Ref OAC
            S3OriginConfig:
              OriginAccessIdentity: ""

          # AgentCore origin for REST API
          - Id: AgentCoreRestOrigin
            DomainName: !Sub "bedrock-agentcore.${AwsRegion}.amazonaws.com"
            OriginPath: !Sub "/runtimes/${EncodedAgentArn}"
            CustomOriginConfig:
              OriginProtocolPolicy: https-only
              HTTPSPort: 443
              OriginSSLProtocols: [TLSv1.2]

          # AgentCore origin for WebSocket
          - Id: AgentCoreWsOrigin
            DomainName: !Sub "bedrock-agentcore.${AwsRegion}.amazonaws.com"
            OriginPath: !Sub "/runtimes/${EncodedAgentArn}"
            CustomOriginConfig:
              OriginProtocolPolicy: https-only
              HTTPSPort: 443
              OriginSSLProtocols: [TLSv1.2]

        # Default: S3 frontend
        DefaultCacheBehavior:
          TargetOriginId: S3Origin
          ViewerProtocolPolicy: redirect-to-https
          CachePolicyId: 658327ea-f89d-4fab-a63d-7e88639e58f6  # CachingOptimized
          Compress: true

        CacheBehaviors:
          # /invocations* -> AgentCore REST
          - PathPattern: "/invocations*"
            TargetOriginId: AgentCoreRestOrigin
            ViewerProtocolPolicy: https-only
            AllowedMethods: [GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE]
            CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # CachingDisabled
            OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3  # AllViewer
            Compress: false

          # /ws* -> AgentCore WebSocket
          - PathPattern: "/ws*"
            TargetOriginId: AgentCoreWsOrigin
            ViewerProtocolPolicy: https-only
            AllowedMethods: [GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE]
            CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # CachingDisabled
            OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3  # AllViewer
            FunctionAssociations:
              - EventType: viewer-request
                FunctionARN: !GetAtt TokenInjectionFunction.FunctionARN
            Compress: false

        # SPA fallback: serve index.html for 403/404
        CustomErrorResponses:
          - ErrorCode: 403
            ResponseCode: 200
            ResponsePagePath: /index.html
          - ErrorCode: 404
            ResponseCode: 200
            ResponsePagePath: /index.html

Outputs:
  BucketName:
    Value: !Ref FrontendBucket
  DistributionId:
    Value: !Ref CloudFrontDistribution
  DistributionDomain:
    Value: !GetAtt CloudFrontDistribution.DomainName
```

## CloudFront Function for Token Injection

Separate file at `infra/cloudfront-function.js` (also inline in the template):

```javascript
function handler(event) {
  var request = event.request;
  var qs = request.querystring;

  // If token is in query string, inject as Authorization header
  // This handles WebSocket connections where browsers can't set headers
  if (qs.token && qs.token.value) {
    request.headers['authorization'] = {
      value: 'Bearer ' + qs.token.value
    };
  }

  return request;
}
```

## Frontend Build and Deploy

### Build step

For React + Vite:
```bash
# .env.production — empty means same-origin (production via CloudFront)
VITE_API_BASE=
VITE_WS_BASE=
VITE_COGNITO_POOL_ID=<pool-id>
VITE_COGNITO_CLIENT_ID=<client-id>

npm run build   # outputs to dist/
```

### S3 sync with cache headers

```bash
# index.html: no-cache (always fetch latest)
aws s3 cp dist/index.html "s3://$BUCKET/index.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html" \
  --region "$REGION"

# Assets (hashed filenames): immutable long cache
aws s3 sync dist/ "s3://$BUCKET/" \
  --exclude "index.html" \
  --cache-control "public, max-age=31536000, immutable" \
  --region "$REGION"
```

### CloudFront invalidation

```bash
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --region "$REGION"
```

## WebSocket Proxy (Local Dev)

For local development, a proxy bridges browser connections to AgentCore:

- Browser connects to `ws://localhost:3001/ws?token=<jwt>`
- Proxy connects to `wss://bedrock-agentcore.<region>.amazonaws.com/runtimes/<encoded-arn>/ws`
  with `Authorization: Bearer <jwt>` header
- Messages are forwarded bidirectionally

The proxy also handles REST:
- Browser POSTs to `http://localhost:3001/invocations`
- Proxy forwards to AgentCore REST endpoint with auth headers

This is needed because:
1. Browsers can't set custom headers on WebSocket connections.
2. Cross-origin REST calls need the session ID header forwarded.

## Frontend Environment Variables

**Production (via CloudFront):** Empty API/WS base = use same origin.
```
VITE_API_BASE=
VITE_WS_BASE=
VITE_COGNITO_POOL_ID=<pool-id>
VITE_COGNITO_CLIENT_ID=<client-id>
VITE_AWS_REGION=<region>
```

**Local dev (via proxy):** Point to the local proxy.
```
VITE_API_BASE=http://localhost:3001
VITE_WS_BASE=ws://localhost:3001
VITE_COGNITO_POOL_ID=<pool-id>
VITE_COGNITO_CLIENT_ID=<client-id>
VITE_AWS_REGION=<region>
```

**CRITICAL:** `VITE_AWS_REGION` is required for the frontend Cognito auth to
construct the IDP endpoint URL. Without it, login fails silently.

### Production routing detection (CRITICAL)

The frontend MUST detect production mode and use `/invocations` instead of `/api`.
CloudFront only routes `/invocations*` and `/ws*` to AgentCore; all other paths
fall through to S3 and return `index.html` (causing JSON parse errors).

```typescript
// Detect production via Cognito config presence (set by deploy.sh)
const HAS_COGNITO = !!import.meta.env.VITE_COGNITO_POOL_ID;

const API_BASE = import.meta.env.VITE_API_BASE
  ? `${import.meta.env.VITE_API_BASE}/invocations`
  : HAS_COGNITO ? "/invocations" : "/api";

const WS_BASE = import.meta.env.VITE_WS_BASE
  || `${window.location.protocol === "https:" ? "wss:" : "ws:"}//${window.location.host}`;

const USE_INVOCATIONS = !!import.meta.env.VITE_API_BASE || HAS_COGNITO;
```

### Cognito login form (CRITICAL)

The frontend MUST include a Cognito login form for production. Without auth,
all API calls return 401/403. Use the Cognito IDP API directly via `fetch` —
no extra SDK dependency needed:

```typescript
async function cognitoAuth(username: string, password: string): Promise<string> {
  const region = import.meta.env.VITE_AWS_REGION || "us-east-1";
  const clientId = import.meta.env.VITE_COGNITO_CLIENT_ID;
  const res = await fetch(`https://cognito-idp.${region}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-amz-json-1.1",
      "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth",
    },
    body: JSON.stringify({
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: clientId,
      AuthParameters: { USERNAME: username, PASSWORD: password },
    }),
  });
  const data = await res.json();
  if (data.AuthenticationResult?.IdToken) return data.AuthenticationResult.IdToken;
  throw new Error(data.message || "Authentication failed");
}
```

The token must be:
- Stored in React state (component-level, not localStorage)
- Included as `Authorization: Bearer <token>` header on all REST calls
- Passed as `?token=<jwt>` query param for WebSocket connections
- WebSocket URL should be `null` until authenticated (prevents premature connections)

```typescript
function getWsUrl(): string | null {
  if (needsAuth && !token) return null;  // Don't connect before auth
  const base = `${WS_BASE}/ws`;
  return token ? `${base}?token=${token}` : base;
}
```

## No Frontend Case

If the application is API-only (no frontend), skip:
- S3 bucket creation
- CloudFront distribution
- Frontend build and deploy steps
- CloudFront Function

The deploy script should still deploy to AgentCore Runtime and output
the REST/WS endpoints for direct API access.
