#!/bin/bash

# AgentCore Runtime Deployment Script
# Deploys the chat application to AWS Bedrock AgentCore Runtime
# Uses @aws/agentcore CLI (npm) with CDK-based deployment
#
# Usage:
#   ./deploy.sh             # Deploy everything (AgentCore + S3/CloudFront frontend)
#   ./deploy.sh --destroy   # Tear down ALL resources and clean up config files
#
# Prerequisites:
#   - AWS CLI configured with credentials
#   - Node.js 20+ and npm
#   - @aws/agentcore CLI (installed automatically if missing)
#   - No local Docker required (CodeBuild handles builds remotely)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="us-east-1"
PROJECT_NAME="claudesimplechatapp"  # alphanumeric only (agentcore create constraint)
AGENT_NAME="claude_simple_chatapp"  # alphanumeric + underscores (agent name)
STACK_NAME="chatapp-frontend"

# Helper: find a working python3 for JSON/YAML parsing
PYTHON_CMD=""
for cmd in python3 python; do
    if command -v "$cmd" &> /dev/null; then
        PYTHON_CMD="$cmd"
        break
    fi
done

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
    echo "  - AgentCore runtime + memory (CDK stack)"
    echo "  - Cognito User Pools"
    echo "  - Local config files (.env, client/.env, agentcore/, etc.)"
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

    # 2. Destroy AgentCore CDK stack (runtime + memory)
    echo -e "${YELLOW}[2/4] Destroying AgentCore CDK stack...${NC}"
    if command -v agentcore &>/dev/null && [ -d "agentcore" ]; then
        # CDK destroy via the CLI
        agentcore deploy --yes --diff 2>/dev/null || true
        # Direct CDK destroy
        if [ -d "agentcore/cdk" ]; then
            cd agentcore/cdk
            npm install --quiet 2>/dev/null || true
            npx cdk destroy --force 2>/dev/null || true
            cd ../..
        fi
        echo -e "${GREEN}  ✓ AgentCore CDK stack destroyed${NC}"
    else
        echo -e "${YELLOW}  (No agentcore config found, skipping)${NC}"
    fi
    echo ""

    # 3. Clean up Cognito
    echo -e "${YELLOW}[3/4] Cleaning up Cognito...${NC}"
    if [ -f ".agentcore_cognito.json" ] && [ -n "$PYTHON_CMD" ]; then
        POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d.get('pool_id',''))" 2>/dev/null)
        if [ -n "$POOL_ID" ]; then
            echo "  Deleting Cognito User Pool: $POOL_ID"
            # Must delete domain first, then pool
            DOMAIN=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d.get('domain',''))" 2>/dev/null)
            if [ -n "$DOMAIN" ]; then
                aws cognito-idp delete-user-pool-domain \
                    --user-pool-id "$POOL_ID" \
                    --domain "$DOMAIN" \
                    --region "$AWS_REGION" 2>/dev/null || true
            fi
            aws cognito-idp delete-user-pool \
                --user-pool-id "$POOL_ID" \
                --region "$AWS_REGION" 2>/dev/null || true
            echo -e "${GREEN}  ✓ Cognito cleaned up${NC}"
        else
            echo -e "${YELLOW}  (No pool ID found in config, skipping)${NC}"
        fi
    else
        echo -e "${YELLOW}  (No Cognito config found, skipping)${NC}"
    fi
    echo ""

    # 4. Remove local config files
    echo -e "${YELLOW}[4/4] Removing local config files...${NC}"
    rm -f .env client/.env client/.env.production
    rm -f .agentcore_cognito.json
    rm -rf agentcore/ dist/
    # Legacy cleanup
    rm -f .bedrock_agentcore.yaml .agentcore_identity_cognito_user.json
    rm -rf .bedrock_agentcore/
    rm -f Dockerfile .dockerignore
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

if ! command -v node &> /dev/null; then
    echo -e "${RED}Error: Node.js not installed${NC}"
    exit 1
fi

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
# Install AgentCore CLI (@aws/agentcore)
# ──────────────────────────────────────────────
echo -e "${YELLOW}Installing AgentCore CLI...${NC}"
if ! command -v agentcore &> /dev/null; then
    npm install -g @aws/agentcore
fi
echo -e "${GREEN}✓ AgentCore CLI installed $(agentcore --version 2>/dev/null || true)${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 0: Migrate from old Python toolkit config (if present)
#   Convert .agentcore_identity_cognito_user.json → .agentcore_cognito.json
# ──────────────────────────────────────────────
if [ -f ".agentcore_identity_cognito_user.json" ] && [ ! -f ".agentcore_cognito.json" ] && [ -n "$PYTHON_CMD" ]; then
    echo -e "${YELLOW}Migrating Cognito config from old toolkit format...${NC}"
    $PYTHON_CMD << PYEOF
import json
with open(".agentcore_identity_cognito_user.json") as f:
    old = json.load(f)
rt = old.get("runtime", old)
# Extract domain prefix from discovery URL or use a default
pool_id = rt["pool_id"]
domain = rt.get("domain_prefix", f"agentcore-runtime-{pool_id.split('_')[1][:8].lower()}")
new_config = {
    "pool_id": pool_id,
    "client_id": rt["client_id"],
    "domain": domain,
    "username": rt["username"],
    "password": rt["password"],
    "discovery_url": rt["discovery_url"],
    "region": "$AWS_REGION"
}
with open(".agentcore_cognito.json", "w") as f:
    json.dump(new_config, f, indent=2)
print(f"  Migrated Cognito config (pool: {pool_id})")
PYEOF
    echo -e "${GREEN}✓ Cognito config migrated${NC}"
    echo ""
fi

# ──────────────────────────────────────────────
# Step 1: Initialize AgentCore project config
#   New CLI uses agentcore/ directory with:
#   - agentcore.json  (project spec: runtimes, memories, credentials)
#   - aws-targets.json (deployment targets with account/region)
#   - cdk/            (CDK app for deployment)
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Configuring AgentCore project...${NC}"
if [ ! -f "agentcore/agentcore.json" ]; then
    # Create project skeleton in a temp subdirectory, then move agentcore/ up
    agentcore create \
        --name "$PROJECT_NAME" \
        --no-agent \
        --skip-git \
        --skip-install

    # Move agentcore/ directory to project root
    if [ -d "$PROJECT_NAME/agentcore" ]; then
        mv "$PROJECT_NAME/agentcore" ./agentcore
        rm -rf "$PROJECT_NAME"
    fi

    # Add BYO agent pointing to our existing TypeScript code
    agentcore add agent \
        --name "$AGENT_NAME" \
        --type byo \
        --build Container \
        --language TypeScript \
        --framework Strands \
        --model-provider Bedrock \
        --entrypoint server/runtime-server.ts \
        --code-location . \
        --protocol HTTP \
        --network-mode PUBLIC

    echo -e "${GREEN}✓ AgentCore project initialized${NC}"
else
    echo "  agentcore/agentcore.json already exists, skipping init"
    echo -e "${GREEN}✓ AgentCore config present${NC}"
fi
echo ""

# ──────────────────────────────────────────────
# Step 1b: Configure deployment target
#   Ensure aws-targets.json has our region/account
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 1b: Configuring deployment target...${NC}"
if [ -n "$PYTHON_CMD" ]; then
    $PYTHON_CMD << PYEOF
import json, os

targets_path = "agentcore/aws-targets.json"
try:
    with open(targets_path, "r") as f:
        targets = json.load(f)
except:
    targets = []

if not isinstance(targets, list):
    targets = []

# Ensure default target exists with correct region/account
has_default = any(t.get("name") == "default" for t in targets)
if not has_default:
    targets.append({
        "name": "default",
        "account": "$AWS_ACCOUNT_ID",
        "region": "$AWS_REGION"
    })
    with open(targets_path, "w") as f:
        json.dump(targets, f, indent=2)
    print("  Added default deployment target")
else:
    # Update region/account on existing default target
    for t in targets:
        if t.get("name") == "default":
            t["account"] = "$AWS_ACCOUNT_ID"
            t["region"] = "$AWS_REGION"
    with open(targets_path, "w") as f:
        json.dump(targets, f, indent=2)
    print("  Updated default deployment target")
PYEOF
else
    # Fallback: write targets directly
    cat > agentcore/aws-targets.json << EOF
[{"name": "default", "account": "$AWS_ACCOUNT_ID", "region": "$AWS_REGION"}]
EOF
fi
echo -e "${GREEN}✓ Deployment target configured${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 2: Set up Cognito for OAuth authentication
#   Creates a Cognito User Pool with a test user for
#   CUSTOM_JWT authorizer on the AgentCore endpoint.
#   Saves credentials to .agentcore_cognito.json
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Setting up Cognito authentication...${NC}"
if [ -z "$PYTHON_CMD" ]; then
    echo -e "${RED}Error: Python 3 required for Cognito setup (JSON parsing)${NC}"
    exit 1
fi

if [ ! -f ".agentcore_cognito.json" ]; then
    $PYTHON_CMD << PYEOF
import json, subprocess, secrets, string

region = "$AWS_REGION"
pool_name = "${AGENT_NAME}-runtime"

def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else {}

# Create User Pool
pool = run(["aws", "cognito-idp", "create-user-pool",
    "--pool-name", pool_name,
    "--auto-verified-attributes", "email",
    "--schema", '[{"Name":"email","Required":true,"Mutable":true}]',
    "--region", region, "--output", "json"])
pool_id = pool["UserPool"]["Id"]

# Add domain for OIDC discovery
domain = f"{pool_name.replace('_','-').lower()}-{pool_id.split('_')[1][:8].lower()}"
run(["aws", "cognito-idp", "create-user-pool-domain",
    "--user-pool-id", pool_id, "--domain", domain, "--region", region])

# Create app client
client = run(["aws", "cognito-idp", "create-user-pool-client",
    "--user-pool-id", pool_id,
    "--client-name", f"{pool_name}-client",
    "--explicit-auth-flows", "ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH",
    "--region", region, "--output", "json"])
client_id = client["UserPoolClient"]["ClientId"]

# Create test user
username = "testuser@example.com"
password = "Test" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12)) + "!1"
run(["aws", "cognito-idp", "admin-create-user",
    "--user-pool-id", pool_id,
    "--username", username,
    "--user-attributes", f'Name=email,Value={username}', 'Name=email_verified,Value=true',
    "--message-action", "SUPPRESS",
    "--region", region])
run(["aws", "cognito-idp", "admin-set-user-password",
    "--user-pool-id", pool_id,
    "--username", username,
    "--password", password,
    "--permanent",
    "--region", region])

discovery_url = f"https://cognito-idp.{region}.amazonaws.com/{pool_id}/.well-known/openid-configuration"

config = {
    "pool_id": pool_id,
    "client_id": client_id,
    "domain": domain,
    "username": username,
    "password": password,
    "discovery_url": discovery_url,
    "region": region
}
with open(".agentcore_cognito.json", "w") as f:
    json.dump(config, f, indent=2)

print(f"  Created User Pool: {pool_id}")
print(f"  Client ID: {client_id}")
print(f"  Test user: {username}")
PYEOF
fi

# Read Cognito credentials
RUNTIME_POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['pool_id'])")
RUNTIME_CLIENT_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['client_id'])")
RUNTIME_USERNAME=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['username'])")
RUNTIME_PASSWORD=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['password'])")
DISCOVERY_URL=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['discovery_url'])")

echo -e "${GREEN}✓ Cognito authentication configured${NC}"
echo "  Runtime Pool ID: $RUNTIME_POOL_ID"
echo "  Client ID:       $RUNTIME_CLIENT_ID"
echo "  Test Username:   $RUNTIME_USERNAME"
echo ""

# ──────────────────────────────────────────────
# Step 3: Configure CUSTOM_JWT authorizer on the agent
#   Update agentcore.json with JWT authorizer config
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Configuring OAuth authorizer...${NC}"

$PYTHON_CMD << PYEOF
import json

with open("agentcore/agentcore.json", "r") as f:
    config = json.load(f)

for runtime in config.get("runtimes", []):
    if runtime.get("name") == "$AGENT_NAME":
        runtime["authorizerType"] = "CUSTOM_JWT"
        runtime["authorizerConfiguration"] = {
            "customJwtAuthorizer": {
                "discoveryUrl": "$DISCOVERY_URL",
                "allowedAudience": ["$RUNTIME_CLIENT_ID"]
            }
        }
        runtime.pop("customJwtAuthorizer", None)
        runtime["requestHeaderAllowlist"] = ["Authorization"]
        break

with open("agentcore/agentcore.json", "w") as f:
    json.dump(config, f, indent=2)

print("  Updated agentcore.json with CUSTOM_JWT authorizer")
PYEOF

echo -e "${GREEN}✓ OAuth authorizer configured${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 3b: Add AgentCore Memory resource
#   Adds memory config to agentcore.json.
#   CDK deploy will create the actual memory resource.
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 3b: Adding AgentCore Memory resource...${NC}"

MEMORY_NAME="${AGENT_NAME}_mem"

$PYTHON_CMD << PYEOF
import json

with open("agentcore/agentcore.json", "r") as f:
    config = json.load(f)

# Check if memory already configured
has_memory = any(m.get("name") == "$MEMORY_NAME" for m in config.get("memories", []))
if not has_memory:
    config.setdefault("memories", []).append({
        "name": "$MEMORY_NAME",
        "eventExpiryDuration": 90,
        "strategies": [
            {"type": "SEMANTIC", "namespaces": ["/users/{actorId}/facts"]},
            {"type": "USER_PREFERENCE", "namespaces": ["/users/{actorId}/preferences"]},
            {"type": "SUMMARIZATION", "namespaces": ["/summaries/{actorId}/{sessionId}"]},
            {"type": "EPISODIC", "namespaces": ["/episodes/{actorId}/{sessionId}"], "reflectionNamespaces": ["/episodes/{actorId}"]}
        ]
    })
    # Link memory to the runtime
    for runtime in config.get("runtimes", []):
        if runtime.get("name") == "$AGENT_NAME":
            runtime["memory"] = "$MEMORY_NAME"
            break
    with open("agentcore/agentcore.json", "w") as f:
        json.dump(config, f, indent=2)
    print("  Added memory resource: $MEMORY_NAME")
else:
    print("  Memory already configured: $MEMORY_NAME")
PYEOF

echo -e "${GREEN}✓ Memory resource configured${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 4: Deploy to AgentCore via CDK
#   - Installs CDK deps, synthesizes, and deploys
#   - Builds container remotely (no local Docker needed)
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 4: Deploying to AgentCore (via CDK)...${NC}"
echo "This will build and deploy the agent container to AgentCore."
echo ""

# Install CDK dependencies, patch asset bundling, and clean stale output
if [ -d "agentcore/cdk" ]; then
    echo "  Installing CDK dependencies..."
    cd agentcore/cdk && npm install --quiet && cd ../..
    rm -rf agentcore/cdk/cdk.out 2>/dev/null

    # Patch ContainerSourceAsset to exclude agentcore/cdk/cdk.out from asset staging.
    # Without this, codeLocation="./" causes CDK to recursively copy cdk.out into the asset.
    ASSET_JS="agentcore/cdk/node_modules/@aws/agentcore-cdk/dist/cdk/constructs/bundling/container/ContainerSourceAsset.js"
    if [ -f "$ASSET_JS" ] && ! grep -q "exclude:" "$ASSET_JS"; then
        echo "  Patching ContainerSourceAsset (exclude cdk.out from asset staging)..."
        $PYTHON_CMD -c "
import re
with open('$ASSET_JS') as f:
    code = f.read()
old = \"path: resolvedCodeLocation,\\n        });\"
new = \"\"\"path: resolvedCodeLocation,
            exclude: ['agentcore/cdk/cdk.out', 'agentcore/cdk/node_modules', 'agentcore/.cli', 'agentcore/.cache', 'node_modules', '.git', 'dist', 'evals', 'skills'],
        });\"\"\"
code = code.replace(old, new)
with open('$ASSET_JS', 'w') as f:
    f.write(code)
"
    fi
fi

# Set environment variables for the runtime
export AGENTCORE_ENV_AWS_REGION="$AWS_REGION"
export AGENTCORE_ENV_PORT="8080"
export AGENTCORE_ENV_CLAUDE_CODE_USE_BEDROCK="1"
export AGENTCORE_ENV_ANTHROPIC_MODEL="us.anthropic.claude-sonnet-4-20250514-v1:0"

agentcore deploy --yes

echo ""
echo -e "${GREEN}✓ Deployment complete!${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 5: Fetch deployed resource info and generate config files
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 5: Generating configuration files...${NC}"

# Extract agent ARN from deployed status
AGENT_ARN=$(agentcore status --json 2>/dev/null | $PYTHON_CMD -c "
import json, sys
try:
    data = json.load(sys.stdin)
    # Navigate the status JSON to find the runtime ARN
    for r in data if isinstance(data, list) else data.get('resources', data.get('runtimes', [])):
        if isinstance(r, dict):
            arn = r.get('arn', r.get('runtimeArn', r.get('agentArn', '')))
            if arn: print(arn); break
except: pass
" 2>/dev/null)

# Fallback: try reading from deployed-state.json
if [ -z "$AGENT_ARN" ] && [ -f "agentcore/.cli/deployed-state.json" ]; then
    AGENT_ARN=$($PYTHON_CMD -c "
import json
try:
    with open('agentcore/.cli/deployed-state.json') as f:
        state = json.load(f)
    # Walk the state to find runtime ARN
    for tname, tdata in state.get('targets', {}).items():
        for rname, rdata in tdata.get('resources', {}).get('runtimes', {}).items():
            arn = rdata.get('runtimeArn', rdata.get('arn', ''))
            if arn: print(arn); break
except: pass
" 2>/dev/null)
fi

if [ -z "$AGENT_ARN" ]; then
    echo -e "${YELLOW}  Warning: Could not auto-detect Agent ARN. Check 'agentcore status' and set AGENT_ARN in .env manually.${NC}"
fi

# Read memory ID from deployed state
AGENTCORE_MEMORY_ID=""
if [ -f "agentcore/.cli/deployed-state.json" ]; then
    AGENTCORE_MEMORY_ID=$($PYTHON_CMD -c "
import json
try:
    with open('agentcore/.cli/deployed-state.json') as f:
        state = json.load(f)
    for tname, tdata in state.get('targets', {}).items():
        for mname, mdata in tdata.get('resources', {}).get('memories', {}).items():
            mid = mdata.get('memoryId', mdata.get('arn', ''))
            if mid: print(mid); break
except: pass
" 2>/dev/null)
fi

# Root .env for ws-proxy.ts (loaded via dotenv/config)
cat > .env <<EOF
# Local proxy configuration (used by server/ws-proxy.ts)
# The proxy handles both REST and WebSocket forwarding to AgentCore
AGENT_ARN=$AGENT_ARN
AWS_REGION=$AWS_REGION
PROXY_PORT=3001
AGENTCORE_MEMORY_ID=$AGENTCORE_MEMORY_ID
EOF

# Frontend .env (Vite variables)
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
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Deploying frontend to S3 + CloudFront...${NC}"

if [ -z "$PYTHON_CMD" ]; then
    echo -e "${RED}Error: Python 3 required for URL encoding${NC}"
    exit 1
fi

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
echo -e "${GREEN}Agent ARN:${NC}   $AGENT_ARN"
if [ -n "$AGENTCORE_MEMORY_ID" ]; then
    echo -e "${GREEN}Memory ID:${NC}   $AGENTCORE_MEMORY_ID"
fi
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
echo "  agentcore deploy --diff              # Preview changes"
echo "  aws cloudformation delete-stack --stack-name $STACK_NAME  # Remove frontend infra"
echo ""
echo -e "${GREEN}Deployment completed successfully!${NC}"
