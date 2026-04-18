# Template: deploy.sh

Complete one-click deployment script for AgentCore using the `@aws/agentcore`
npm CLI (v0.8+) with CDK-based deployment.

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
#   - Node.js 20+ and npm
#   - @aws/agentcore CLI (installed automatically if missing)

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
LANGUAGE="{{LANGUAGE}}"               # "TypeScript" or "Python"
BUILD_TYPE="{{BUILD_TYPE}}"           # "Container" or "CodeZip"
HAS_FRONTEND={{HAS_FRONTEND}}

# Helper: find python3 for JSON parsing
PYTHON_CMD=""
for cmd in python3 python; do
    if command -v "$cmd" &>/dev/null; then PYTHON_CMD="$cmd"; break; fi
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
    if [ "$HAS_FRONTEND" = true ]; then
        echo "  - CloudFront distribution + S3 bucket"
    fi
    echo "  - AgentCore CDK stack (runtime + memory)"
    echo "  - Cognito User Pool"
    echo "  - Local config files"
    echo ""
    read -p "Are you sure? (y/N) " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo -e "${YELLOW}Aborted.${NC}"; exit 0; }

    # 1. Delete CloudFormation stack (if frontend)
    if [ "$HAS_FRONTEND" = true ]; then
        echo -e "${YELLOW}[1/4] Deleting CloudFormation stack...${NC}"
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

    # 2. Destroy AgentCore CDK stack
    echo -e "${YELLOW}[2/4] Destroying AgentCore CDK stack...${NC}"
    if [ -d "agentcore/cdk" ]; then
        cd agentcore/cdk
        npm install --quiet 2>/dev/null || true
        npx cdk destroy --force 2>/dev/null || true
        cd ../..
        echo -e "${GREEN}  CDK stack destroyed${NC}"
    else
        echo -e "${YELLOW}  (No CDK config found)${NC}"
    fi

    # 3. Clean up Cognito
    echo -e "${YELLOW}[3/4] Cleaning up Cognito...${NC}"
    if [ -f ".agentcore_cognito.json" ] && [ -n "$PYTHON_CMD" ]; then
        POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d.get('pool_id',''))" 2>/dev/null)
        if [ -n "$POOL_ID" ]; then
            DOMAIN=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d.get('domain',''))" 2>/dev/null)
            [ -n "$DOMAIN" ] && aws cognito-idp delete-user-pool-domain --user-pool-id "$POOL_ID" --domain "$DOMAIN" --region "$AWS_REGION" 2>/dev/null || true
            aws cognito-idp delete-user-pool --user-pool-id "$POOL_ID" --region "$AWS_REGION" 2>/dev/null || true
            echo -e "${GREEN}  Cognito cleaned up${NC}"
        fi
    else
        echo -e "${YELLOW}  (No Cognito config found)${NC}"
    fi

    # 4. Remove local files
    echo -e "${YELLOW}[4/4] Removing config files...${NC}"
    rm -f .env .agentcore_cognito.json
    rm -rf agentcore/ dist/
    # ADAPT: remove framework-specific env files
    # rm -f client/.env client/.env.production
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
command -v npm &>/dev/null || { echo -e "${RED}Error: npm not installed${NC}"; exit 1; }
command -v node &>/dev/null || { echo -e "${RED}Error: Node.js not installed${NC}"; exit 1; }
echo -e "${GREEN}Prerequisites OK${NC}\n"

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
# AgentCore CLI
# ──────────────────────────────────────────────
echo -e "${YELLOW}Installing AgentCore CLI...${NC}"
if ! command -v agentcore &>/dev/null; then
    npm install -g @aws/agentcore
fi
echo -e "${GREEN}AgentCore CLI $(agentcore --version)${NC}\n"

# ──────────────────────────────────────────────
# Step 1: Initialize AgentCore project
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Initializing AgentCore project...${NC}"
if [ ! -f "agentcore/agentcore.json" ]; then
    agentcore create \
        --name "$AGENT_NAME" \
        --no-agent \
        --output-dir . \
        --skip-git \
        --skip-install

    agentcore add agent \
        --name "$AGENT_NAME" \
        --type byo \
        --build "$BUILD_TYPE" \
        --language "$LANGUAGE" \
        --entrypoint "$ENTRYPOINT" \
        --code-location . \
        --protocol HTTP \
        --network-mode PUBLIC
fi

# Configure deployment target
if [ -n "$PYTHON_CMD" ]; then
    $PYTHON_CMD << PYEOF
import json
targets_path = "agentcore/aws-targets.json"
try:
    with open(targets_path) as f: targets = json.load(f)
except: targets = []
has_default = any(t.get("name") == "default" for t in targets)
if not has_default:
    targets.append({"name": "default", "account": "$AWS_ACCOUNT_ID", "region": "$AWS_REGION"})
    with open(targets_path, "w") as f: json.dump(targets, f, indent=2)
PYEOF
else
    cat > agentcore/aws-targets.json << EOF
[{"name": "default", "account": "$AWS_ACCOUNT_ID", "region": "$AWS_REGION"}]
EOF
fi
echo -e "${GREEN}AgentCore project initialized${NC}\n"

# ──────────────────────────────────────────────
# Step 2: Cognito setup (via AWS CLI)
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Setting up Cognito...${NC}"
if [ -z "$PYTHON_CMD" ]; then
    echo -e "${RED}Error: Python 3 required for Cognito setup${NC}"; exit 1
fi

if [ ! -f ".agentcore_cognito.json" ]; then
    $PYTHON_CMD << PYEOF
import json, subprocess, secrets, string

region = "$AWS_REGION"
pool_name = "${AGENT_NAME}-runtime"

def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else {}

pool = run(["aws", "cognito-idp", "create-user-pool",
    "--pool-name", pool_name,
    "--auto-verified-attributes", "email",
    "--schema", '[{"Name":"email","Required":true,"Mutable":true}]',
    "--region", region, "--output", "json"])
pool_id = pool["UserPool"]["Id"]

domain = f"{pool_name.replace('_','-').lower()}-{pool_id.split('_')[1][:8].lower()}"
run(["aws", "cognito-idp", "create-user-pool-domain",
    "--user-pool-id", pool_id, "--domain", domain, "--region", region])

client = run(["aws", "cognito-idp", "create-user-pool-client",
    "--user-pool-id", pool_id,
    "--client-name", f"{pool_name}-client",
    "--explicit-auth-flows", "ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH",
    "--region", region, "--output", "json"])
client_id = client["UserPoolClient"]["ClientId"]

username = "testuser@example.com"
password = "Test" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12)) + "!1"
run(["aws", "cognito-idp", "admin-create-user",
    "--user-pool-id", pool_id, "--username", username,
    "--user-attributes", f'Name=email,Value={username}', 'Name=email_verified,Value=true',
    "--message-action", "SUPPRESS", "--region", region])
run(["aws", "cognito-idp", "admin-set-user-password",
    "--user-pool-id", pool_id, "--username", username,
    "--password", password, "--permanent", "--region", region])

discovery_url = f"https://cognito-idp.{region}.amazonaws.com/{pool_id}/.well-known/openid-configuration"
config = {"pool_id": pool_id, "client_id": client_id, "domain": domain,
          "username": username, "password": password, "discovery_url": discovery_url, "region": region}
with open(".agentcore_cognito.json", "w") as f:
    json.dump(config, f, indent=2)
PYEOF
fi

RUNTIME_POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['pool_id'])")
RUNTIME_CLIENT_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['client_id'])")
RUNTIME_USERNAME=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['username'])")
RUNTIME_PASSWORD=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['password'])")
DISCOVERY_URL=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_cognito.json')); print(d['discovery_url'])")
echo -e "${GREEN}Cognito ready (user: $RUNTIME_USERNAME)${NC}\n"

# ──────────────────────────────────────────────
# Step 3: Configure CUSTOM_JWT authorizer + memory
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Configuring authorizer and memory...${NC}"

MEMORY_NAME="${AGENT_NAME}_mem"

$PYTHON_CMD << PYEOF
import json

with open("agentcore/agentcore.json", "r") as f:
    config = json.load(f)

for runtime in config.get("runtimes", []):
    if runtime.get("name") == "$AGENT_NAME":
        runtime["authorizerType"] = "CUSTOM_JWT"
        runtime["customJwtAuthorizer"] = {
            "discoveryUrl": "$DISCOVERY_URL",
            "allowedAudience": ["$RUNTIME_CLIENT_ID"]
        }
        runtime["requestHeaderAllowlist"] = ["Authorization"]
        runtime["memory"] = "$MEMORY_NAME"
        break

has_memory = any(m.get("name") == "$MEMORY_NAME" for m in config.get("memories", []))
if not has_memory:
    config.setdefault("memories", []).append({
        "name": "$MEMORY_NAME",
        "strategies": ["SEMANTIC"],
        "expiryDays": 90
    })

with open("agentcore/agentcore.json", "w") as f:
    json.dump(config, f, indent=2)
PYEOF

echo -e "${GREEN}Authorizer and memory configured${NC}\n"

# ──────────────────────────────────────────────
# Step 4: Deploy via CDK
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 4: Deploying to AgentCore (via CDK)...${NC}"

if [ -d "agentcore/cdk" ]; then
    echo "  Installing CDK dependencies..."
    cd agentcore/cdk && npm install --quiet && cd ../..
fi

echo -e "${YELLOW}  Deploying (this may take 3-5 minutes)...${NC}"
agentcore deploy --yes
echo -e "${GREEN}Deployed!${NC}\n"

# ──────────────────────────────────────────────
# Step 5: Extract deployed info + generate .env files
# ──────────────────────────────────────────────
echo -e "${YELLOW}Step 5: Generating config files...${NC}"

AGENT_ARN=$(agentcore status --json 2>/dev/null | $PYTHON_CMD -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for r in data if isinstance(data, list) else data.get('resources', data.get('runtimes', [])):
        if isinstance(r, dict):
            arn = r.get('arn', r.get('runtimeArn', ''))
            if arn: print(arn); break
except: pass
" 2>/dev/null)

# Fallback: read from deployed-state.json
if [ -z "$AGENT_ARN" ] && [ -f "agentcore/.cli/deployed-state.json" ]; then
    AGENT_ARN=$($PYTHON_CMD -c "
import json
with open('agentcore/.cli/deployed-state.json') as f: state = json.load(f)
for tdata in state.get('targets', {}).values():
    for rdata in tdata.get('resources', {}).get('runtimes', {}).values():
        arn = rdata.get('runtimeArn', rdata.get('arn', ''))
        if arn: print(arn); break
" 2>/dev/null)
fi

AGENTCORE_MEMORY_ID=""
if [ -f "agentcore/.cli/deployed-state.json" ]; then
    AGENTCORE_MEMORY_ID=$($PYTHON_CMD -c "
import json
with open('agentcore/.cli/deployed-state.json') as f: state = json.load(f)
for tdata in state.get('targets', {}).values():
    for mdata in tdata.get('resources', {}).get('memories', {}).values():
        mid = mdata.get('memoryId', mdata.get('arn', ''))
        if mid: print(mid); break
" 2>/dev/null)
fi

cat > .env << EOF
AGENT_ARN=$AGENT_ARN
AWS_REGION=$AWS_REGION
PROXY_PORT=3001
AGENTCORE_MEMORY_ID=$AGENTCORE_MEMORY_ID
EOF

# ADAPT: Generate frontend .env files if HAS_FRONTEND=true
# IMPORTANT: Must be generated BEFORE npm run build (Vite bakes env vars at build time)
if [ "$HAS_FRONTEND" = true ]; then
    cat > client/.env.production << EOF
VITE_API_BASE=
VITE_WS_BASE=
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
VITE_AWS_REGION=$AWS_REGION
EOF

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
# Step 6: Frontend deployment (if applicable)
# ──────────────────────────────────────────────
if [ "$HAS_FRONTEND" = true ]; then
    echo -e "${YELLOW}Step 6: Deploying frontend to S3 + CloudFront...${NC}"

    ENCODED_AGENT_ARN=$($PYTHON_CMD -c "import urllib.parse; print(urllib.parse.quote('$AGENT_ARN', safe=''))")

    # ADAPT: Create/update CloudFormation stack
    # CRITICAL: Do NOT blindly wait after update-stack — it hangs if no update is needed
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
        UPDATE_OUTPUT=$(aws cloudformation update-stack \
            --stack-name "$STACK_NAME" \
            --template-body file://infra/template.yaml \
            --parameters ParameterKey=EncodedAgentArn,ParameterValue="$ENCODED_AGENT_ARN" ParameterKey=AwsRegion,ParameterValue="$AWS_REGION" \
            --region "$AWS_REGION" 2>&1) || true
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
        echo -e "${YELLOW}  Creating CloudFront distribution — this typically takes 5-15 minutes...${NC}"
        aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
    fi

    BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)
    DISTRIBUTION_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" --output text)
    CF_DOMAIN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='DistributionDomain'].OutputValue" --output text)
    CF_URL="https://$CF_DOMAIN"

    # ADAPT: Build frontend
    npm run build

    # ADAPT: Sync to S3 with proper cache headers
    DIST_DIR="dist"
    aws s3 cp "$DIST_DIR/index.html" "s3://$BUCKET_NAME/index.html" \
        --cache-control "no-cache, no-store, must-revalidate" \
        --content-type "text/html" \
        --region "$AWS_REGION"
    aws s3 sync "$DIST_DIR/" "s3://$BUCKET_NAME/" \
        --exclude "index.html" \
        --cache-control "public, max-age=31536000, immutable" \
        --region "$AWS_REGION"

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
echo -e "${GREEN}Region:${NC}     $AWS_REGION"
echo ""
echo -e "${YELLOW}Login Credentials:${NC}"
echo "  Username: $RUNTIME_USERNAME"
echo "  Password: $RUNTIME_PASSWORD"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo "  agentcore status                     # Check deployment status"
echo "  agentcore invoke \"Hello\"              # Chat with deployed agent"
echo "  agentcore logs                       # Stream runtime logs"
echo "  agentcore deploy --diff              # Preview changes"
echo ""
echo -e "${GREEN}Deployment complete!${NC}"
```
