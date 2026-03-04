#!/bin/bash

# AgentCore Runtime Deployment Script
# Deploys the chat application to AWS Bedrock AgentCore Runtime
# Uses AgentCore Starter Toolkit (CodeBuild, no local Docker required)
#
# Usage:
#   ./deploy.sh             # Deploy everything (AgentCore + S3/CloudFront frontend)
#   ./deploy.sh --destroy   # Tear down ALL resources and clean up config files
#
# Prerequisites:
#   - AWS CLI configured with credentials
#   - Python 3.10+ with pip (for agentcore toolkit)
#   - Node.js 20+ and npm
#   - No local Docker required (CodeBuild handles ARM64 builds remotely)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="us-east-1"
AGENT_NAME="claude_simple_chatapp"
STACK_NAME="chatapp-frontend"

# ──────────────────────────────────────────────
# --destroy: Tear down all resources
# ──────────────────────────────────────────────
if [ "$1" = "--destroy" ]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}Destroying ALL Resources${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    echo "This will remove:"
    echo "  - CloudFront distribution + S3 bucket (CloudFormation stack: $STACK_NAME)"
    echo "  - AgentCore runtime (agent: $AGENT_NAME)"
    echo "  - Cognito User Pools"
    echo "  - Local config files (.env, client/.env, .bedrock_agentcore.yaml, etc.)"
    echo ""
    read -p "Are you sure? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 0
    fi
    echo ""

    # 1. Delete CloudFormation stack (S3 + CloudFront)
    echo -e "${YELLOW}[1/4] Deleting CloudFormation stack: $STACK_NAME ...${NC}"
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
        # Empty the S3 bucket first (CloudFormation can't delete non-empty buckets)
        BUCKET_NAME=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$AWS_REGION" \
            --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
            --output text 2>/dev/null) || true

        if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
            echo "  Emptying S3 bucket: $BUCKET_NAME"
            aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" 2>/dev/null || true
            # Also delete versioned objects
            echo "  Removing versioned objects..."
            aws s3api list-object-versions --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
                --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null | \
                aws s3api delete-objects --bucket "$BUCKET_NAME" --delete file:///dev/stdin \
                --region "$AWS_REGION" 2>/dev/null || true
            aws s3api list-object-versions --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
                --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null | \
                aws s3api delete-objects --bucket "$BUCKET_NAME" --delete file:///dev/stdin \
                --region "$AWS_REGION" 2>/dev/null || true
        fi

        aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
        echo "  Waiting for stack deletion..."
        aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
        echo -e "${GREEN}  ✓ CloudFormation stack deleted${NC}"
    else
        echo -e "${YELLOW}  (Stack not found, skipping)${NC}"
    fi
    echo ""

    # 2. Destroy AgentCore runtime
    echo -e "${YELLOW}[2/4] Destroying AgentCore runtime...${NC}"
    if command -v agentcore &>/dev/null && [ -f ".bedrock_agentcore.yaml" ]; then
        agentcore destroy --yes 2>/dev/null || agentcore destroy 2>/dev/null || echo -e "${YELLOW}  (agentcore destroy failed or already destroyed)${NC}"
        echo -e "${GREEN}  ✓ AgentCore runtime destroyed${NC}"
    else
        echo -e "${YELLOW}  (No agentcore config found, skipping)${NC}"
    fi
    echo ""

    # 3. Clean up Cognito
    echo -e "${YELLOW}[3/4] Cleaning up Cognito...${NC}"
    if command -v agentcore &>/dev/null && [ -f ".agentcore_identity_cognito_user.json" ]; then
        agentcore identity cleanup-cognito --region "$AWS_REGION" 2>/dev/null || \
            echo -e "${YELLOW}  (Cognito cleanup via toolkit failed; you may need to delete User Pools manually)${NC}"
        echo -e "${GREEN}  ✓ Cognito cleaned up${NC}"
    else
        echo -e "${YELLOW}  (No Cognito config found, skipping)${NC}"
    fi
    echo ""

    # 4. Remove local config files
    echo -e "${YELLOW}[4/4] Removing local config files...${NC}"
    rm -f .env client/.env client/.env.production
    rm -f .bedrock_agentcore.yaml .agentcore_identity_cognito_user.json
    rm -rf dist/
    echo -e "${GREEN}  ✓ Config files removed${NC}"
    echo ""

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}All resources destroyed.${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "To redeploy from scratch:  ./deploy.sh"
    exit 0
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AgentCore Runtime Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ──────────────────────────────────────────────
# Prerequisites Check
# ──────────────────────────────────────────────
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not installed${NC}"
    exit 1
fi

if ! command -v npm &> /dev/null; then
    echo -e "${RED}Error: npm not installed${NC}"
    exit 1
fi

# Python 3.10+ is required for the AgentCore Starter Toolkit
PYTHON_CMD=""
for cmd in python3 python; do
    if command -v "$cmd" &> /dev/null; then
        PY_VERSION=$("$cmd" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        PY_MAJOR=$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null)
        PY_MINOR=$("$cmd" -c "import sys; print(sys.version_info.minor)" 2>/dev/null)
        if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ]; then
            PYTHON_CMD="$cmd"
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    echo -e "${RED}Error: Python 3.10+ not found (required for AgentCore Starter Toolkit)${NC}"
    echo "Install Python 3.10+ or activate a virtualenv with Python 3.10+."
    exit 1
fi
echo "  Using Python: $PYTHON_CMD ($PY_VERSION)"

# Derive pip command from the same python
PIP_CMD="$PYTHON_CMD -m pip"

echo -e "${GREEN}✓ Prerequisites check passed${NC}"
echo ""

# ──────────────────────────────────────────────
# AWS Credentials Check
# ──────────────────────────────────────────────
echo -e "${YELLOW}Checking AWS credentials...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || {
    echo -e "${RED}Error: AWS credentials not configured. Run 'aws configure' or set AWS_PROFILE.${NC}"
    exit 1
}
echo -e "${GREEN}✓ AWS credentials valid (Account: $AWS_ACCOUNT_ID)${NC}"
echo ""

# ──────────────────────────────────────────────
# Install npm dependencies
# ──────────────────────────────────────────────
echo -e "${YELLOW}Installing npm dependencies...${NC}"
npm install
echo -e "${GREEN}✓ Dependencies installed${NC}"
echo ""

# ──────────────────────────────────────────────
# Install AgentCore Starter Toolkit (pip)
# ──────────────────────────────────────────────
echo -e "${YELLOW}Installing AgentCore Starter Toolkit...${NC}"
if ! command -v agentcore &> /dev/null; then
    $PIP_CMD install --upgrade bedrock-agentcore-starter-toolkit
fi
echo -e "${GREEN}✓ Toolkit installed $(agentcore --version 2>/dev/null || true)${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 1: Configure AgentCore Runtime
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Configuring AgentCore Runtime...${NC}"
if [ ! -f ".bedrock_agentcore.yaml" ]; then
    agentcore configure \
        --entrypoint server/runtime-server.ts \
        --name "$AGENT_NAME" \
        --region "$AWS_REGION" \
        --language typescript \
        --deployment-type container \
        --protocol HTTP \
        --non-interactive

    # agentcore configure may reset the region; ensure it's correct
    $PYTHON_CMD -c "
import yaml
with open('.bedrock_agentcore.yaml', 'r') as f:
    config = yaml.safe_load(f)
config['agents']['$AGENT_NAME']['aws']['region'] = '$AWS_REGION'
with open('.bedrock_agentcore.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
"
fi
echo -e "${GREEN}✓ AgentCore configured${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 2: Set up Cognito for OAuth authentication
#   Uses the toolkit's managed Cognito setup which creates:
#   - A "Runtime" User Pool (for JWT authorizer on the AgentCore endpoint)
#   - An "Identity" User Pool (for credential vending, optional)
#   - Test users for both pools
#   All details are saved to .agentcore_identity_cognito_user.json
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Setting up Cognito authentication...${NC}"
if [ ! -f ".agentcore_identity_cognito_user.json" ]; then
    agentcore identity setup-cognito --region "$AWS_REGION" --auth-flow user
fi

# Read Cognito Runtime Pool credentials from the toolkit-generated file
RUNTIME_POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['pool_id'])")
RUNTIME_CLIENT_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['client_id'])")
RUNTIME_USERNAME=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['username'])")
RUNTIME_PASSWORD=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['password'])")
DISCOVERY_URL="https://cognito-idp.$AWS_REGION.amazonaws.com/$RUNTIME_POOL_ID/.well-known/openid-configuration"

echo -e "${GREEN}✓ Cognito authentication configured${NC}"
echo "  Runtime Pool ID: $RUNTIME_POOL_ID"
echo "  Client ID:       $RUNTIME_CLIENT_ID"
echo "  Test Username:   $RUNTIME_USERNAME"
echo ""

# ──────────────────────────────────────────────
# Step 3: Configure customJWTAuthorizer on the AgentCore Runtime
#   AgentCore validates JWT tokens at the platform level before
#   forwarding requests to the container. Uses OIDC discovery URL
#   from the Cognito Runtime Pool. The container itself does NOT
#   need to verify tokens (auth is handled externally).
#
#   Key YAML fields:
#   - customJWTAuthorizer.allowedAudience (singular, not plural)
#   - customJWTAuthorizer.discoveryUrl
#   - requestHeaderAllowlist: ["Authorization"]
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Configuring OAuth authorizer...${NC}"

$PYTHON_CMD << PYEOF
import yaml

with open('.bedrock_agentcore.yaml', 'r') as f:
    config = yaml.safe_load(f)

agent = config['agents']['$AGENT_NAME']
agent['authorizer_configuration'] = {
    'customJWTAuthorizer': {
        'allowedAudience': ['$RUNTIME_CLIENT_ID'],
        'discoveryUrl': '$DISCOVERY_URL'
    }
}
agent['request_header_configuration'] = {
    'requestHeaderAllowlist': ['Authorization']
}
# Ensure region is correct (agentcore configure sometimes resets it)
agent['aws']['region'] = '$AWS_REGION'

with open('.bedrock_agentcore.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("Updated .bedrock_agentcore.yaml with OAuth authorizer")
PYEOF

echo -e "${GREEN}✓ OAuth authorizer configured${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 4: Deploy to AgentCore Runtime via CodeBuild
#   - CodeBuild builds an ARM64 container remotely (no local Docker needed)
#   - Base image uses public.ecr.aws to avoid Docker Hub rate limiting
#   - Dockerfile creates a non-root user (Claude Code refuses
#     --dangerously-skip-permissions as root)
#   - Installs git (required by Claude Code) and full npm deps (tsx needed)
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 4: Deploying to AgentCore Runtime (via CodeBuild)...${NC}"
echo "This will build an ARM64 container in the cloud and deploy it."
echo ""

agentcore deploy \
    --auto-update-on-conflict \
    --env "AWS_REGION=$AWS_REGION" \
    --env "PORT=8080" \
    --env "CLAUDE_CODE_USE_BEDROCK=1" \
    --env "ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-20250514-v1:0"

echo ""
echo -e "${GREEN}✓ Deployment complete!${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 5: Generate configuration files
#   - .env (root): AGENT_ARN for the local proxy (ws-proxy.ts)
#   - client/.env: Frontend environment variables
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 5: Generating configuration files...${NC}"

# Extract agent ARN from config
AGENT_ARN=$($PYTHON_CMD -c "import yaml; d=yaml.safe_load(open('.bedrock_agentcore.yaml')); print(d['agents']['$AGENT_NAME']['bedrock_agentcore']['agent_arn'])")

# Root .env for ws-proxy.ts (loaded via dotenv/config)
cat > .env <<EOF
# Local proxy configuration (used by server/ws-proxy.ts)
# The proxy handles both REST and WebSocket forwarding to AgentCore
AGENT_ARN=$AGENT_ARN
AWS_REGION=$AWS_REGION
PROXY_PORT=3001
EOF

# Frontend .env (Vite variables)
# BOTH VITE_API_BASE and VITE_WS_BASE point to the local proxy (port 3001).
# All browser-to-AgentCore traffic goes through the proxy to ensure:
# 1. Authorization header is forwarded (browser WS API can't set headers)
# 2. X-Amzn-Bedrock-AgentCore-Runtime-Session-Id header is forwarded
#    (avoids CORS issues with custom headers on cross-origin REST calls)
cat > client/.env.production <<EOF
VITE_API_BASE=http://localhost:3001
VITE_WS_BASE=ws://localhost:3001
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
EOF

cp client/.env.production client/.env

echo -e "${GREEN}✓ Configuration files saved${NC}"
echo "  .env                    → Local proxy config (AGENT_ARN, region)"
echo "  client/.env             → Frontend config (proxy URL, Cognito)"
echo ""

# ──────────────────────────────────────────────
# Step 6: Deploy frontend to S3 + CloudFront
#   - URL-encode the Agent ARN for CloudFront origin path
#   - Create/update CloudFormation stack (S3 bucket, CloudFront distribution)
#   - Build frontend with same-origin defaults (no API_BASE/WS_BASE needed)
#   - Sync to S3 with appropriate cache headers
#   - Invalidate CloudFront cache
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Deploying frontend to S3 + CloudFront...${NC}"

# URL-encode the Agent ARN (CloudFormation can't do this)
ENCODED_AGENT_ARN=$($PYTHON_CMD -c "import urllib.parse; print(urllib.parse.quote('$AGENT_ARN', safe=''))")
echo "  Encoded ARN: ${ENCODED_AGENT_ARN:0:60}..."

# Create or update CloudFormation stack
echo "  Creating/updating CloudFormation stack: $STACK_NAME"
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
    aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://infra/template.yaml \
        --parameters \
            ParameterKey=EncodedAgentArn,ParameterValue="$ENCODED_AGENT_ARN" \
            ParameterKey=AwsRegion,ParameterValue="$AWS_REGION" \
        --region "$AWS_REGION" 2>/dev/null || echo "  (No stack changes detected)"

    echo "  Waiting for stack update..."
    aws cloudformation wait stack-update-complete \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" 2>/dev/null || true
else
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://infra/template.yaml \
        --parameters \
            ParameterKey=EncodedAgentArn,ParameterValue="$ENCODED_AGENT_ARN" \
            ParameterKey=AwsRegion,ParameterValue="$AWS_REGION" \
        --region "$AWS_REGION"

    echo "  Waiting for stack creation (this may take a few minutes)..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION"
fi

# Read stack outputs
BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
    --output text)
DISTRIBUTION_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" \
    --output text)
CF_DOMAIN=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='DistributionDomain'].OutputValue" \
    --output text)
CF_URL="https://$CF_DOMAIN"

echo "  S3 Bucket:       $BUCKET_NAME"
echo "  Distribution ID: $DISTRIBUTION_ID"
echo "  CloudFront URL:  $CF_URL"

# Write .env.production — explicitly empty API/WS base to override client/.env values
# (Vite merges .env + .env.production; omitting a key falls back to .env)
cat > client/.env.production <<EOF
# Production: same-origin via CloudFront (empty = use window.location)
VITE_API_BASE=
VITE_WS_BASE=
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
EOF

# Build frontend
echo "  Building frontend..."
npm run build

# Sync to S3 with cache headers
echo "  Syncing to S3..."
# index.html: no-cache (always fetch latest)
aws s3 cp dist/index.html "s3://$BUCKET_NAME/index.html" \
    --cache-control "no-cache, no-store, must-revalidate" \
    --content-type "text/html" \
    --region "$AWS_REGION"

# Assets (JS/CSS with hashes): immutable long cache
aws s3 sync dist/ "s3://$BUCKET_NAME/" \
    --exclude "index.html" \
    --cache-control "public, max-age=31536000, immutable" \
    --region "$AWS_REGION"

# Invalidate CloudFront cache
echo "  Invalidating CloudFront cache..."
aws cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" \
    --paths "/*" \
    --region "$AWS_REGION" \
    --output text --query "Invalidation.Id"

echo -e "${GREEN}✓ Frontend deployed to CloudFront${NC}"
echo ""

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Agent ARN:${NC}  $AGENT_ARN"
echo -e "${GREEN}Proxy:${NC}      http://localhost:3001 (REST + WebSocket → AgentCore)"
echo -e "${GREEN}CloudFront:${NC} $CF_URL"
echo ""
echo -e "${YELLOW}Test Credentials:${NC}"
echo "  Username: $RUNTIME_USERNAME"
echo "  Password: $RUNTIME_PASSWORD"
echo ""
echo -e "${BLUE}Production (S3 + CloudFront):${NC}"
echo "  Open: $CF_URL"
echo "  No local proxy needed — CloudFront routes directly to AgentCore"
echo ""
echo -e "${BLUE}Local Dev:${NC}"
echo "  1. Start proxy + frontend:  npm run dev:deployed"
echo "  2. Open:                    http://localhost:5173"
echo "  3. Sign in with the test credentials above"
echo ""
echo -e "${BLUE}Useful Commands:${NC}"
echo "  npm run dev:deployed                 # Start proxy + frontend"
echo "  npm run dev:stop                     # Stop all dev processes"
echo "  agentcore status                     # Check deployment status"
echo "  agentcore destroy                    # Tear down deployment"
echo "  aws cloudformation delete-stack --stack-name $STACK_NAME  # Remove frontend infra"
echo ""
echo -e "${GREEN}Deployment completed successfully!${NC}"
