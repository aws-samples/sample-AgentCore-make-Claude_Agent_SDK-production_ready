#!/bin/bash

# AgentCore Runtime Deployment Script
# Deploys the chat application to AWS Bedrock AgentCore Runtime
# Uses AgentCore Starter Toolkit (CodeBuild, no local Docker required)
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
# Summary
# ──────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Agent ARN:${NC}  $AGENT_ARN"
echo -e "${GREEN}Proxy:${NC}      http://localhost:3001 (REST + WebSocket → AgentCore)"
echo ""
echo -e "${YELLOW}Test Credentials:${NC}"
echo "  Username: $RUNTIME_USERNAME"
echo "  Password: $RUNTIME_PASSWORD"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. Start proxy + frontend:  npm run dev:deployed"
echo "  2. Open:                    http://localhost:5173"
echo "  3. Sign in with the test credentials above"
echo ""
echo -e "${BLUE}Useful Commands:${NC}"
echo "  npm run dev:deployed                 # Start proxy + frontend"
echo "  npm run dev:stop                     # Stop all dev processes"
echo "  agentcore status                     # Check deployment status"
echo "  agentcore destroy                    # Tear down deployment"
echo ""
echo -e "${GREEN}Deployment completed successfully!${NC}"
