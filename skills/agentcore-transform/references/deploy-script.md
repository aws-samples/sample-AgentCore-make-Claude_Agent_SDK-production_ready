# Deploy Script Reference

Patterns for generating a complete one-click deployment script.

## Script Structure

The deploy script is a single `deploy.sh` (bash) that handles the full lifecycle:

```
deploy.sh
  ├── --destroy flag        (teardown mode)
  ├── Prerequisites check   (aws, python, npm/pip, etc.)
  ├── AWS credentials check
  ├── Install dependencies
  ├── Install agentcore CLI
  ├── agentcore configure
  ├── Cognito setup
  ├── JWT authorizer config
  ├── Memory resource create
  ├── agentcore deploy
  ├── Generate .env files
  ├── Frontend deploy (if applicable)
  └── Summary output
```

## Configuration Variables

At the top of the script, define project-specific configuration:

```bash
#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration — adapt these to the project
AWS_REGION="us-east-1"
AGENT_NAME="{{AGENT_NAME}}"           # from package.json name or directory
STACK_NAME="{{STACK_NAME}}"           # CloudFormation stack name
LANGUAGE="{{LANGUAGE}}"               # "typescript" or "python"
ENTRYPOINT="{{ENTRYPOINT}}"           # e.g., "server/runtime-server.ts"
HAS_FRONTEND={{HAS_FRONTEND}}         # true or false
```

## Prerequisites Check

**IMPORTANT:** Always prefer a Python virtual environment (`.venv/`, `venv/`, or
user-specified path) for Python and agentcore CLI. System Python often lacks required
packages (boto3, pyyaml). During analysis, detect existing venvs and ask the user to
confirm the path.

All `agentcore` CLI calls must use `$AGENTCORE_CMD` (not bare `agentcore`).

```bash
echo -e "${YELLOW}Checking prerequisites...${NC}"

# AWS CLI
command -v aws &>/dev/null || { echo -e "${RED}Error: AWS CLI not installed${NC}"; exit 1; }

# Language-specific
if [ "$LANGUAGE" = "typescript" ]; then
  command -v npm &>/dev/null || { echo -e "${RED}Error: npm not installed${NC}"; exit 1; }
elif [ "$LANGUAGE" = "python" ]; then
  command -v pip &>/dev/null || command -v pip3 &>/dev/null || { echo -e "${RED}Error: pip not installed${NC}"; exit 1; }
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Prefer .venv Python (has boto3, pyyaml, and agentcore toolkit)
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
[ -z "$PYTHON_CMD" ] && { echo -e "${RED}Error: Python 3.10+ required for AgentCore Toolkit${NC}"; exit 1; }

# Prefer .venv agentcore CLI
if [ -x "$SCRIPT_DIR/.venv/bin/agentcore" ]; then
    AGENTCORE_CMD="$SCRIPT_DIR/.venv/bin/agentcore"
elif command -v agentcore &>/dev/null; then
    AGENTCORE_CMD="agentcore"
else
    AGENTCORE_CMD=""
fi
```

## AgentCore Toolkit Installation

```bash
if [ -z "$AGENTCORE_CMD" ]; then
    # Create venv if needed and install toolkit
    if [ ! -d "$SCRIPT_DIR/.venv" ]; then
        $PYTHON_CMD -m venv "$SCRIPT_DIR/.venv"
        PYTHON_CMD="$SCRIPT_DIR/.venv/bin/python3"
    fi
    $PYTHON_CMD -m pip install --upgrade bedrock-agentcore-starter-toolkit boto3 pyyaml
    AGENTCORE_CMD="$SCRIPT_DIR/.venv/bin/agentcore"
fi
```

## AgentCore Configure

```bash
if [ ! -f ".bedrock_agentcore.yaml" ]; then
  $AGENTCORE_CMD configure \
    --entrypoint "$ENTRYPOINT" \
    --name "$AGENT_NAME" \
    --region "$AWS_REGION" \
    --language "$LANGUAGE" \
    --deployment-type container \
    --protocol HTTP \
    --non-interactive

  # Ensure region is correct
  $PYTHON_CMD -c "
import yaml
with open('.bedrock_agentcore.yaml', 'r') as f:
    config = yaml.safe_load(f)
config['agents']['$AGENT_NAME']['aws']['region'] = '$AWS_REGION'
with open('.bedrock_agentcore.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
"
fi
```

## Cognito Setup

```bash
if [ ! -f ".agentcore_identity_cognito_user.json" ]; then
  $AGENTCORE_CMD identity setup-cognito --region "$AWS_REGION" --auth-flow user
fi

RUNTIME_POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['pool_id'])")
RUNTIME_CLIENT_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['client_id'])")
RUNTIME_USERNAME=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['username'])")
RUNTIME_PASSWORD=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['password'])")
DISCOVERY_URL="https://cognito-idp.$AWS_REGION.amazonaws.com/$RUNTIME_POOL_ID/.well-known/openid-configuration"
```

## JWT Authorizer Configuration

```bash
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
```

## Memory Resource Creation

```bash
MEMORY_NAME="${AGENT_NAME}_mem"

# Check if already exists in config
EXISTING_MEMORY_ID=$($PYTHON_CMD -c "
import yaml
try:
    with open('.bedrock_agentcore.yaml', 'r') as f:
        config = yaml.safe_load(f)
    mid = config['agents']['$AGENT_NAME'].get('memory', {}).get('memory_id', '')
    print(mid if mid else '')
except:
    print('')
" 2>/dev/null)

if [ -n "$EXISTING_MEMORY_ID" ]; then
    if $AGENTCORE_CMD memory get "$EXISTING_MEMORY_ID" --region "$AWS_REGION" 2>&1 | grep -q "ACTIVE"; then
        AGENTCORE_MEMORY_ID="$EXISTING_MEMORY_ID"
    else
        EXISTING_MEMORY_ID=""
    fi
fi

if [ -z "$EXISTING_MEMORY_ID" ]; then
    CREATE_OUTPUT=$($AGENTCORE_CMD memory create "$MEMORY_NAME" \
        --region "$AWS_REGION" \
        --event-expiry-days 90 \
        --strategies '[{"semanticMemoryStrategy": {"name": "semantic", "description": "Extract key facts and information from conversations"}}]' \
        --wait 2>&1) || {
        echo -e "${YELLOW}Warning: Could not create memory resource.${NC}"
        AGENTCORE_MEMORY_ID=""
    }

    if [ -z "$AGENTCORE_MEMORY_ID" ]; then
        # NOTE: grep -P is not available on macOS. Use sed instead.
        AGENTCORE_MEMORY_ID=$(echo "$CREATE_OUTPUT" | sed -n 's/.*Memory ID: \([^ ]*\).*/\1/p' || true)
    fi
    if [ -z "$AGENTCORE_MEMORY_ID" ]; then
        AGENTCORE_MEMORY_ID=$($PYTHON_CMD -c "
import yaml
try:
    with open('.bedrock_agentcore.yaml', 'r') as f:
        config = yaml.safe_load(f)
    mid = config['agents']['$AGENT_NAME'].get('memory', {}).get('memory_id', '')
    print(mid if mid else '')
except:
    print('')
" 2>/dev/null)
    fi
fi
```

## Resolve Bedrock Model ID

**CRITICAL:** Direct Bedrock model IDs (e.g., `anthropic.claude-sonnet-4-20250514-v1:0`)
do NOT work for on-demand invocation. You MUST use an inference profile ID. The prefix
depends on the AWS region:

| Region prefix | Inference profile prefix |
|---|---|
| `us-east-1`, `us-west-2` | `us.anthropic.claude-*` |
| `ap-northeast-1`, `ap-southeast-*` | `apac.anthropic.claude-*` |
| `eu-west-1`, `eu-central-1` | `eu.anthropic.claude-*` |
| Any region (cross-region routing) | `global.anthropic.claude-*` |

```bash
# Resolve the correct inference profile prefix for the target region
# Use wildcard matching for future-proof region support
case "$AWS_REGION" in
    us-*)  MODEL_PREFIX="us" ;;
    ap-*)  MODEL_PREFIX="apac" ;;
    eu-*)  MODEL_PREFIX="eu" ;;
    *)     MODEL_PREFIX="us" ;;
esac

# ADAPT: Use the model the user's app needs. Default to sonnet.
BEDROCK_MODEL_ID="${MODEL_PREFIX}.anthropic.claude-sonnet-4-20250514-v1:0"
```

## Deploy to AgentCore Runtime

**CRITICAL:** Container env vars are passed via `--env` flags, NOT hardcoded in Dockerfile.
The Dockerfile should only contain build-time constants (AWS_REGION, DOCKER_CONTAINER).

```bash
DEPLOY_ENV_FLAGS=(
    --env "AWS_REGION=$AWS_REGION"
    --env "PORT=8080"
    --env "CLAUDE_CODE_USE_BEDROCK=1"
    --env "ANTHROPIC_MODEL=$BEDROCK_MODEL_ID"
)
if [ -n "$AGENTCORE_MEMORY_ID" ]; then
    DEPLOY_ENV_FLAGS+=(--env "AGENTCORE_MEMORY_ID=$AGENTCORE_MEMORY_ID")
fi

echo -e "${YELLOW}  Building and deploying container (this may take 3-5 minutes)...${NC}"
$AGENTCORE_CMD deploy --auto-update-on-conflict "${DEPLOY_ENV_FLAGS[@]}"
```

## Generate .env Files

**IMPORTANT:** Frontend env files MUST be generated BEFORE `npm run build`,
since Vite bakes env vars into the JS bundle at build time.

```bash
AGENT_ARN=$($PYTHON_CMD -c "
import yaml
d = yaml.safe_load(open('.bedrock_agentcore.yaml'))
print(d['agents']['$AGENT_NAME']['bedrock_agentcore']['agent_arn'])
")

# Root .env (for proxy / local dev)
cat > .env << EOF
AGENT_ARN=$AGENT_ARN
AWS_REGION=$AWS_REGION
PROXY_PORT=3001
AGENTCORE_MEMORY_ID=$AGENTCORE_MEMORY_ID
EOF

# Frontend .env (if applicable)
if [ "$HAS_FRONTEND" = true ]; then
  # .env.production for same-origin via CloudFront
  # HAS_COGNITO triggers /invocations mode + login form automatically
  cat > client/.env.production << EOF
VITE_API_BASE=
VITE_WS_BASE=
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
VITE_AWS_REGION=$AWS_REGION
EOF

  # .env for local dev via proxy
  cat > client/.env << EOF
VITE_API_BASE=http://localhost:3001
VITE_WS_BASE=ws://localhost:3001
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
VITE_AWS_REGION=$AWS_REGION
EOF
fi
```

## Teardown (--destroy flag)

The script must support `--destroy` to remove all resources:

```bash
if [ "$1" = "--destroy" ]; then
    # 1. Delete CloudFormation stack (empty S3 first)
    # 2. Delete AgentCore Memory resource
    # 3. agentcore destroy
    # 4. agentcore identity cleanup-cognito
    # 5. Remove local config files (.env, .bedrock_agentcore.yaml, etc.)
    exit 0
fi
```

Order matters: CloudFormation first (S3 bucket must be emptied), then Memory,
then Runtime, then Cognito, then local files.

## Language-Specific Adaptations

### TypeScript
- `npm install` for dependencies
- `npm run build` for frontend
- Entrypoint: `server/runtime-server.ts`
- `tsx` for TypeScript execution

### Python
- `pip install -r requirements.txt` for dependencies
- Frontend may be separate or none
- Entrypoint: `server/runtime_server.py` or `app/main.py`
- Direct python execution or uvicorn for ASGI

## Summary Output

End the script with a clear summary:

```bash
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Agent ARN:${NC}   $AGENT_ARN"
[ -n "$AGENTCORE_MEMORY_ID" ] && echo -e "${GREEN}Memory ID:${NC}   $AGENTCORE_MEMORY_ID"
if [ "$HAS_FRONTEND" = true ]; then
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
if [ "$HAS_FRONTEND" = true ]; then
    echo "  1. Visit $CF_URL and sign in with the credentials above"
fi
echo "  2. Run ./tests/agentcore-test.sh to verify the deployment"
echo "  3. For local dev: npm run dev:proxy (requires .env with AGENT_ARN)"
```
