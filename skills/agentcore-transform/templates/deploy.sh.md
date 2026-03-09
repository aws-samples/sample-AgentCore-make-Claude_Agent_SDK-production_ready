# Template: deploy.sh

Complete one-click deployment script for AgentCore.

This template should be filled in based on the analysis phase results.
Replace all `{{PLACEHOLDER}}` values with project-specific values.

See `references/deploy-script.md` for detailed documentation of each section.

```bash
#!/bin/bash

# AgentCore Runtime Deployment Script
# Deploys {{AGENT_NAME}} to AWS Bedrock AgentCore Runtime
#
# Usage:
#   ./deploy.sh             # Deploy everything
#   ./deploy.sh --destroy   # Tear down ALL resources
#
# Prerequisites:
#   - AWS CLI configured with credentials
#   - Python 3.10+ (for AgentCore Starter Toolkit)
#   - {{LANG_PREREQS}}

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
AWS_REGION="us-east-1"
AGENT_NAME="{{AGENT_NAME}}"
STACK_NAME="{{STACK_NAME}}-frontend"
ENTRYPOINT="{{ENTRYPOINT}}"
LANGUAGE="{{LANGUAGE}}"
HAS_FRONTEND={{HAS_FRONTEND}}

# ──────────────────────────────────────────────
# --destroy: Tear down all resources
# ──────────────────────────────────────────────
if [ "$1" = "--destroy" ]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}Destroying ALL Resources${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    echo "This will remove:"
    if [ "$HAS_FRONTEND" = true ]; then
        echo "  - CloudFront distribution + S3 bucket"
    fi
    echo "  - AgentCore runtime (agent: $AGENT_NAME)"
    echo "  - AgentCore Memory resource"
    echo "  - Cognito User Pools"
    echo "  - Local config files"
    echo ""
    read -p "Are you sure? (y/N) " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo -e "${YELLOW}Aborted.${NC}"; exit 0; }

    # 1. Delete CloudFormation stack (if frontend)
    if [ "$HAS_FRONTEND" = true ]; then
        echo -e "${YELLOW}[1/5] Deleting CloudFormation stack...${NC}"
        if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
            BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
                --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text 2>/dev/null) || true
            if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
                aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" 2>/dev/null || true
            fi
            aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
            aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
            echo -e "${GREEN}  Stack deleted${NC}"
        else
            echo -e "${YELLOW}  (Stack not found)${NC}"
        fi
    fi

    # 2. Delete Memory resource
    echo -e "${YELLOW}[2/5] Deleting AgentCore Memory...${NC}"
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
        PYTHON_CMD="$SCRIPT_DIR/.venv/bin/python3"
    else
        PYTHON_CMD=$(command -v python3 || command -v python)
    fi
    if [ -x "$SCRIPT_DIR/.venv/bin/agentcore" ]; then
        AGENTCORE_CMD="$SCRIPT_DIR/.venv/bin/agentcore"
    else
        AGENTCORE_CMD="agentcore"
    fi
    MEMORY_ID=$($PYTHON_CMD -c "
import yaml
try:
    with open('.bedrock_agentcore.yaml', 'r') as f:
        config = yaml.safe_load(f)
    mid = config['agents']['$AGENT_NAME'].get('memory', {}).get('memory_id', '')
    print(mid if mid else '')
except: print('')
" 2>/dev/null)
    if [ -n "$MEMORY_ID" ]; then
        # Check if memory still exists before attempting delete
        # CRITICAL: Do NOT use --wait (hangs indefinitely if resource is already deleting or gone)
        if $AGENTCORE_CMD memory get "$MEMORY_ID" --region "$AWS_REGION" 2>&1 | grep -q "ACTIVE\|CREATING\|DELETING"; then
            $AGENTCORE_CMD memory delete "$MEMORY_ID" --region "$AWS_REGION" 2>/dev/null || true
            echo -e "${GREEN}  Memory delete initiated (async)${NC}"
        else
            echo -e "${YELLOW}  (Memory already deleted or not found)${NC}"
        fi
    else
        echo -e "${YELLOW}  (Not found)${NC}"
    fi

    # 3. Destroy AgentCore runtime
    echo -e "${YELLOW}[3/5] Destroying AgentCore runtime...${NC}"
    if [ -f ".bedrock_agentcore.yaml" ]; then
        $AGENTCORE_CMD destroy --yes 2>/dev/null || $AGENTCORE_CMD destroy 2>/dev/null || true
        echo -e "${GREEN}  Runtime destroyed${NC}"
    fi

    # 4. Cleanup Cognito
    echo -e "${YELLOW}[4/5] Cleaning up Cognito...${NC}"
    if [ -f ".agentcore_identity_cognito_user.json" ]; then
        $AGENTCORE_CMD identity cleanup-cognito --region "$AWS_REGION" 2>/dev/null || true
        echo -e "${GREEN}  Cognito cleaned up${NC}"
    fi

    # 5. Remove local files
    echo -e "${YELLOW}[5/5] Removing config files...${NC}"
    rm -f .env .bedrock_agentcore.yaml .agentcore_identity_cognito_user.json
    # ADAPT: remove framework-specific env files
    # rm -f client/.env client/.env.production
    # rm -rf dist/
    echo -e "${GREEN}  Done${NC}"

    echo -e "\n${GREEN}All resources destroyed.${NC}"
    exit 0
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AgentCore Runtime Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ──────────────────────────────────────────────
# Prerequisites
# ──────────────────────────────────────────────
echo -e "${YELLOW}Checking prerequisites...${NC}"
command -v aws &>/dev/null || { echo -e "${RED}Error: AWS CLI not installed${NC}"; exit 1; }

# ADAPT: language-specific checks
# TypeScript:
# command -v npm &>/dev/null || { echo -e "${RED}Error: npm not installed${NC}"; exit 1; }
# Python:
# command -v pip3 &>/dev/null || { echo -e "${RED}Error: pip not installed${NC}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prefer .venv Python (has boto3, pyyaml, and agentcore toolkit)
# ADAPT: Change .venv path if the user's project uses a different venv location
PYTHON_CMD=""
if [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
    PYTHON_CMD="$SCRIPT_DIR/.venv/bin/python3"
else
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            PY_MAJOR=$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null)
            PY_MINOR=$("$cmd" -c "import sys; print(sys.version_info.minor)" 2>/dev/null)
            if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ]; then
                PYTHON_CMD="$cmd"; break
            fi
        fi
    done
fi
[ -z "$PYTHON_CMD" ] && { echo -e "${RED}Error: Python 3.10+ required${NC}"; exit 1; }

# Prefer .venv agentcore CLI
if [ -x "$SCRIPT_DIR/.venv/bin/agentcore" ]; then
    AGENTCORE_CMD="$SCRIPT_DIR/.venv/bin/agentcore"
elif command -v agentcore &>/dev/null; then
    AGENTCORE_CMD="agentcore"
else
    AGENTCORE_CMD=""
fi

echo -e "${GREEN}Prerequisites OK (python: $PYTHON_CMD)${NC}\n"

# ──────────────────────────────────────────────
# AWS Credentials
# ──────────────────────────────────────────────
echo -e "${YELLOW}Checking AWS credentials...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || {
    echo -e "${RED}Error: AWS credentials not configured${NC}"; exit 1; }
echo -e "${GREEN}AWS Account: $AWS_ACCOUNT_ID${NC}\n"

# ──────────────────────────────────────────────
# Install dependencies
# ──────────────────────────────────────────────
echo -e "${YELLOW}Installing dependencies...${NC}"
# ADAPT: npm install (TS) or pip install -r requirements.txt (Python)
echo -e "${GREEN}Dependencies installed${NC}\n"

# ──────────────────────────────────────────────
# AgentCore Toolkit
# ──────────────────────────────────────────────
echo -e "${YELLOW}Installing AgentCore Toolkit...${NC}"
if [ -z "$AGENTCORE_CMD" ]; then
    # Create venv if needed and install toolkit
    if [ ! -d "$SCRIPT_DIR/.venv" ]; then
        $PYTHON_CMD -m venv "$SCRIPT_DIR/.venv"
        PYTHON_CMD="$SCRIPT_DIR/.venv/bin/python3"
    fi
    $PYTHON_CMD -m pip install --upgrade bedrock-agentcore-starter-toolkit boto3 pyyaml
    AGENTCORE_CMD="$SCRIPT_DIR/.venv/bin/agentcore"
fi
echo -e "${GREEN}Toolkit ready ($AGENTCORE_CMD)${NC}\n"

# ──────────────────────────────────────────────
# Step 1: Configure AgentCore
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Configuring AgentCore Runtime...${NC}"
if [ ! -f ".bedrock_agentcore.yaml" ]; then
    $AGENTCORE_CMD configure \
        --entrypoint "$ENTRYPOINT" \
        --name "$AGENT_NAME" \
        --region "$AWS_REGION" \
        --language "$LANGUAGE" \
        --deployment-type container \
        --protocol HTTP \
        --non-interactive

    $PYTHON_CMD -c "
import yaml
with open('.bedrock_agentcore.yaml', 'r') as f:
    config = yaml.safe_load(f)
config['agents']['$AGENT_NAME']['aws']['region'] = '$AWS_REGION'
with open('.bedrock_agentcore.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
"
fi
echo -e "${GREEN}AgentCore configured${NC}"

# CRITICAL: Patch the auto-generated Dockerfile for tsx projects
# The default Dockerfile has: npm run build -> npm prune --production -> node dist/...
# This fails because: (1) vite build only builds frontend, not server TS
# (2) prune removes tsx which is needed at runtime
# (3) OTel --require is injected but package may not survive prune
DOCKERFILE_PATH=".bedrock_agentcore/${AGENT_NAME}/Dockerfile"
if [ -f "$DOCKERFILE_PATH" ]; then
    echo -e "${YELLOW}  Patching Dockerfile for tsx runtime...${NC}"
    $PYTHON_CMD << DFPATCH
import re
with open("$DOCKERFILE_PATH", "r") as f:
    content = f.read()
# Remove npm run build (vite build is frontend-only)
content = re.sub(r'\n# Build TypeScript\nRUN npm run build\n', '\n', content)
# Remove npm prune --production (tsx is a devDependency we need at runtime)
content = re.sub(r'\n# Prune dev dependencies and set production mode\nRUN npm prune --production\nENV NODE_ENV=production\n', '\n', content)
# Replace CMD to use tsx directly
content = re.sub(r'CMD \[.*\]', 'CMD ["npx", "tsx", "server/runtime-server.ts"]', content)
with open("$DOCKERFILE_PATH", "w") as f:
    f.write(content)
print("  Dockerfile patched: uses npx tsx, no build/prune steps")
DFPATCH
fi
echo ""

# ──────────────────────────────────────────────
# Step 2: Cognito setup
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Setting up Cognito...${NC}"
if [ ! -f ".agentcore_identity_cognito_user.json" ]; then
    $AGENTCORE_CMD identity setup-cognito --region "$AWS_REGION" --auth-flow user
fi

RUNTIME_POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['pool_id'])")
RUNTIME_CLIENT_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['client_id'])")
RUNTIME_USERNAME=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['username'])")
RUNTIME_PASSWORD=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['password'])")
DISCOVERY_URL="https://cognito-idp.$AWS_REGION.amazonaws.com/$RUNTIME_POOL_ID/.well-known/openid-configuration"
echo -e "${GREEN}Cognito ready (user: $RUNTIME_USERNAME)${NC}\n"

# ──────────────────────────────────────────────
# Step 3: JWT Authorizer
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Configuring JWT authorizer...${NC}"
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
agent['aws']['region'] = '$AWS_REGION'
with open('.bedrock_agentcore.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
PYEOF
echo -e "${GREEN}JWT authorizer configured${NC}\n"

# ──────────────────────────────────────────────
# Step 4: Memory resource
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 4: Creating AgentCore Memory...${NC}"
MEMORY_NAME="${AGENT_NAME}_mem"
AGENTCORE_MEMORY_ID=""

EXISTING_MEMORY_ID=$($PYTHON_CMD -c "
import yaml
try:
    with open('.bedrock_agentcore.yaml', 'r') as f:
        config = yaml.safe_load(f)
    mid = config['agents']['$AGENT_NAME'].get('memory', {}).get('memory_id', '')
    print(mid if mid else '')
except: print('')
" 2>/dev/null)

if [ -n "$EXISTING_MEMORY_ID" ] && $AGENTCORE_CMD memory get "$EXISTING_MEMORY_ID" --region "$AWS_REGION" 2>&1 | grep -q "ACTIVE"; then
    AGENTCORE_MEMORY_ID="$EXISTING_MEMORY_ID"
    echo "  Memory already exists: $AGENTCORE_MEMORY_ID"
else
    echo -e "${YELLOW}  Creating memory resource (this may take 1-2 minutes)...${NC}"
    CREATE_OUTPUT=$($AGENTCORE_CMD memory create "$MEMORY_NAME" \
        --region "$AWS_REGION" \
        --event-expiry-days 90 \
        --strategies '[{"semanticMemoryStrategy": {"name": "semantic", "description": "Extract key facts and information from conversations"}}]' \
        --wait 2>&1) || echo -e "${YELLOW}  Warning: Memory creation failed${NC}"

    # NOTE: grep -P is not available on macOS. Use sed instead.
    AGENTCORE_MEMORY_ID=$(echo "$CREATE_OUTPUT" | sed -n 's/.*Memory ID: \([^ ]*\).*/\1/p' || true)
    if [ -z "$AGENTCORE_MEMORY_ID" ]; then
        AGENTCORE_MEMORY_ID=$($PYTHON_CMD -c "
import yaml
try:
    with open('.bedrock_agentcore.yaml', 'r') as f:
        config = yaml.safe_load(f)
    mid = config['agents']['$AGENT_NAME'].get('memory', {}).get('memory_id', '')
    print(mid if mid else '')
except: print('')
" 2>/dev/null)
    fi
fi

[ -n "$AGENTCORE_MEMORY_ID" ] && echo -e "${GREEN}Memory ready: $AGENTCORE_MEMORY_ID${NC}" || echo -e "${YELLOW}Memory unavailable (in-memory fallback)${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 5: Deploy container
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 5: Deploying to AgentCore Runtime...${NC}"

# Resolve Bedrock inference profile for the target region
# CRITICAL: Direct model IDs do NOT work; must use inference profiles
case "$AWS_REGION" in
    us-*)  MODEL_PREFIX="us" ;;
    ap-*)  MODEL_PREFIX="apac" ;;
    eu-*)  MODEL_PREFIX="eu" ;;
    *)     MODEL_PREFIX="us" ;;
esac
# ADAPT: Change the model to match the user's needs (sonnet, haiku, opus, etc.)
BEDROCK_MODEL_ID="${MODEL_PREFIX}.anthropic.claude-sonnet-4-20250514-v1:0"

DEPLOY_ENV_FLAGS=(
    --env "AWS_REGION=$AWS_REGION"
    --env "PORT=8080"
    --env "CLAUDE_CODE_USE_BEDROCK=1"
    --env "ANTHROPIC_MODEL=$BEDROCK_MODEL_ID"
)
[ -n "$AGENTCORE_MEMORY_ID" ] && DEPLOY_ENV_FLAGS+=(--env "AGENTCORE_MEMORY_ID=$AGENTCORE_MEMORY_ID")

echo -e "${YELLOW}  Building and deploying container (this may take 3-5 minutes)...${NC}"
$AGENTCORE_CMD deploy --auto-update-on-conflict "${DEPLOY_ENV_FLAGS[@]}"
echo -e "${GREEN}Deployed!${NC}\n"

# ──────────────────────────────────────────────
# Step 6: Generate .env files
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Generating config files...${NC}"
AGENT_ARN=$($PYTHON_CMD -c "import yaml; d=yaml.safe_load(open('.bedrock_agentcore.yaml')); print(d['agents']['$AGENT_NAME']['bedrock_agentcore']['agent_arn'])")

cat > .env << EOF
AGENT_ARN=$AGENT_ARN
AWS_REGION=$AWS_REGION
PROXY_PORT=3001
AGENTCORE_MEMORY_ID=$AGENTCORE_MEMORY_ID
EOF

# ADAPT: Generate frontend .env files if HAS_FRONTEND=true
# IMPORTANT: Must be generated BEFORE npm run build (Vite bakes env vars at build time)
if [ "$HAS_FRONTEND" = true ]; then
    # Production: empty API/WS base = use same-origin CloudFront routing
    # HAS_COGNITO triggers /invocations mode + login form automatically
    cat > client/.env.production << EOF
VITE_API_BASE=
VITE_WS_BASE=
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
VITE_AWS_REGION=$AWS_REGION
EOF

    # Local dev: proxy mode
    cat > client/.env << EOF
VITE_API_BASE=http://localhost:3001
VITE_WS_BASE=ws://localhost:3001
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
VITE_AWS_REGION=$AWS_REGION
EOF
fi

echo -e "${GREEN}Config files saved${NC}\n"

# ──────────────────────────────────────────────
# Step 7: Frontend deployment (if applicable)
# ──────────────────────────────────────────────
if [ "$HAS_FRONTEND" = true ]; then
    echo -e "${YELLOW}Step 7: Deploying frontend to S3 + CloudFront...${NC}"

    ENCODED_AGENT_ARN=$($PYTHON_CMD -c "import urllib.parse; print(urllib.parse.quote('$AGENT_ARN', safe=''))")

    # ADAPT: Create/update CloudFormation stack
    # See references/frontend-deployment.md for full template
    # CRITICAL: Do NOT blindly wait after update-stack — it hangs if no update is needed
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
        UPDATE_OUTPUT=$(aws cloudformation update-stack \
            --stack-name "$STACK_NAME" \
            --template-body file://infra/template.yaml \
            --parameters ParameterKey=EncodedAgentArn,ParameterValue="$ENCODED_AGENT_ARN" ParameterKey=AwsRegion,ParameterValue="$AWS_REGION" \
            --region "$AWS_REGION" 2>&1) || true
        # Only wait if an update was actually started (not "No updates are to be performed")
        if echo "$UPDATE_OUTPUT" | grep -q "StackId"; then
            echo -e "${YELLOW}  Waiting for stack update (CloudFront updates can take 5-15 minutes)...${NC}"
            aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
        else
            echo "  (Stack already up to date)"
        fi
    else
        aws cloudformation create-stack \
            --stack-name "$STACK_NAME" \
            --template-body file://infra/template.yaml \
            --parameters ParameterKey=EncodedAgentArn,ParameterValue="$ENCODED_AGENT_ARN" ParameterKey=AwsRegion,ParameterValue="$AWS_REGION" \
            --region "$AWS_REGION"
        echo -e "${YELLOW}  Creating CloudFront distribution — this typically takes 5-15 minutes. Please be patient...${NC}"
        aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
    fi

    BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)
    DISTRIBUTION_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" --output text)
    CF_DOMAIN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='DistributionDomain'].OutputValue" --output text)
    CF_URL="https://$CF_DOMAIN"

    # ADAPT: Build frontend (env files must already exist from Step 6)
    # IMPORTANT: .env.production must be generated BEFORE build — Vite bakes env vars at build time
    # TypeScript (Vite):
    npm run build
    # Python (if applicable):
    # python build_frontend.py

    # ADAPT: Sync to S3 with proper cache headers
    # - index.html: no-cache (always fetch fresh after invalidation)
    # - Hashed assets (JS/CSS/images): cache forever (immutable, content-addressed)
    # ADAPT: Change "dist/" to match your build output directory (e.g., "dist/", "build/", "client/dist/")
    DIST_DIR="dist"
    aws s3 cp "$DIST_DIR/index.html" "s3://$BUCKET_NAME/index.html" \
        --cache-control "no-cache, no-store, must-revalidate" \
        --content-type "text/html" \
        --region "$AWS_REGION"
    aws s3 sync "$DIST_DIR/" "s3://$BUCKET_NAME/" \
        --exclude "index.html" \
        --cache-control "public, max-age=31536000, immutable" \
        --region "$AWS_REGION"

    # Invalidate
    aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*" --region "$AWS_REGION" --output text --query "Invalidation.Id"

    echo -e "${GREEN}Frontend deployed: $CF_URL${NC}\n"
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Agent ARN:${NC}   $AGENT_ARN"
[ -n "$AGENTCORE_MEMORY_ID" ] && echo -e "${GREEN}Memory ID:${NC}   $AGENTCORE_MEMORY_ID"
if [ "$HAS_FRONTEND" = true ] && [ -n "$CF_URL" ]; then
    echo -e "${GREEN}CloudFront:${NC} $CF_URL"
fi
echo -e "${GREEN}Model:${NC}      $BEDROCK_MODEL_ID"
echo -e "${GREEN}Region:${NC}     $AWS_REGION"
echo ""
echo -e "${YELLOW}Features:${NC}"
echo "  - STM: Conversation events stored in AgentCore Memory"
echo "  - LTM: Semantic search retrieves context from past conversations"
echo "  - Auth: Cognito login form built into frontend"
echo ""
echo -e "${YELLOW}Login Credentials:${NC}"
echo "  Username: $RUNTIME_USERNAME"
echo "  Password: $RUNTIME_PASSWORD"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
if [ "$HAS_FRONTEND" = true ] && [ -n "$CF_URL" ]; then
    echo "  1. Visit $CF_URL and sign in with the credentials above"
fi
echo "  2. Run ./tests/agentcore-test.sh to verify the deployment"
echo "  3. For local dev: npm run dev:proxy (requires .env with AGENT_ARN)"
echo ""
echo -e "${GREEN}Deployment complete!${NC}"
```
