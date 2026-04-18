# Deploy Script Reference

Patterns for generating a complete one-click deployment script using the
`@aws/agentcore` npm CLI (v0.8+) with CDK-based deployment.

## Script Structure

The deploy script is a single `deploy.sh` (bash) that handles the full lifecycle:

```
deploy.sh
  ├── --destroy flag        (teardown mode)
  ├── Prerequisites check   (aws, node, npm)
  ├── AWS credentials check
  ├── Install dependencies
  ├── Install agentcore CLI (npm install -g @aws/agentcore)
  ├── agentcore create + agentcore add agent --type byo
  ├── Configure aws-targets.json (account + region)
  ├── Cognito setup (via AWS CLI)
  ├── Configure CUSTOM_JWT authorizer in agentcore.json
  ├── agentcore add memory
  ├── agentcore deploy --yes (CDK)
  ├── agentcore status --json (extract ARN)
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
STACK_NAME="{{STACK_NAME}}"           # CloudFormation stack name (frontend)
LANGUAGE="{{LANGUAGE}}"               # "TypeScript" or "Python"
ENTRYPOINT="{{ENTRYPOINT}}"           # e.g., "server/runtime-server.ts"
HAS_FRONTEND={{HAS_FRONTEND}}         # true or false
```

## Prerequisites Check

The new CLI is a Node.js tool — no Python venv needed for the CLI itself.
Python is still useful for JSON parsing in bash scripts.

```bash
echo -e "${YELLOW}Checking prerequisites...${NC}"

command -v aws &>/dev/null || { echo -e "${RED}Error: AWS CLI not installed${NC}"; exit 1; }
command -v npm &>/dev/null || { echo -e "${RED}Error: npm not installed${NC}"; exit 1; }
command -v node &>/dev/null || { echo -e "${RED}Error: Node.js not installed${NC}"; exit 1; }

# Optional: find python3 for JSON parsing convenience
PYTHON_CMD=""
for cmd in python3 python; do
    if command -v "$cmd" &>/dev/null; then PYTHON_CMD="$cmd"; break; fi
done
```

## AgentCore CLI Installation

```bash
if ! command -v agentcore &>/dev/null; then
    npm install -g @aws/agentcore
fi
echo "AgentCore CLI $(agentcore --version)"
```

## Project Initialization

The new CLI uses `agentcore/` directory with:
- `agentcore.json` — project spec (runtimes, memories, credentials, evaluators)
- `aws-targets.json` — deployment targets (account + region)
- `cdk/` — CDK app for infrastructure deployment

```bash
if [ ! -f "agentcore/agentcore.json" ]; then
    # Create project skeleton (--no-agent to skip template agent)
    agentcore create \
        --name "$AGENT_NAME" \
        --no-agent \
        --output-dir . \
        --skip-git \
        --skip-install

    # Add BYO (bring-your-own) agent pointing to existing code
    agentcore add agent \
        --name "$AGENT_NAME" \
        --type byo \
        --build Container \
        --language "$LANGUAGE" \
        --entrypoint "$ENTRYPOINT" \
        --code-location . \
        --protocol HTTP \
        --network-mode PUBLIC
fi
```

## Deployment Target Configuration

```bash
# Write aws-targets.json with account + region
# (agentcore create generates an empty array)
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
```

## Cognito Setup

The new CLI does not have `identity setup-cognito`. Create Cognito resources
directly via AWS CLI:

```bash
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
```

## JWT Authorizer Configuration

Configure the CUSTOM_JWT authorizer directly in `agentcore.json`:

```bash
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
        break

with open("agentcore/agentcore.json", "w") as f:
    json.dump(config, f, indent=2)
PYEOF
```

## Memory Resource

Add memory to `agentcore.json` — CDK deploy creates the actual resource:

```bash
$PYTHON_CMD << PYEOF
import json

with open("agentcore/agentcore.json", "r") as f:
    config = json.load(f)

MEMORY_NAME = "${AGENT_NAME}_mem"
has_memory = any(m.get("name") == MEMORY_NAME for m in config.get("memories", []))
if not has_memory:
    config.setdefault("memories", []).append({
        "name": MEMORY_NAME,
        "strategies": ["SEMANTIC"],
        "expiryDays": 90
    })
    for runtime in config.get("runtimes", []):
        if runtime.get("name") == "$AGENT_NAME":
            runtime["memory"] = MEMORY_NAME
            break
    with open("agentcore/agentcore.json", "w") as f:
        json.dump(config, f, indent=2)
PYEOF
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
case "$AWS_REGION" in
    us-*)  MODEL_PREFIX="us" ;;
    ap-*)  MODEL_PREFIX="apac" ;;
    eu-*)  MODEL_PREFIX="eu" ;;
    *)     MODEL_PREFIX="us" ;;
esac
BEDROCK_MODEL_ID="${MODEL_PREFIX}.anthropic.claude-sonnet-4-20250514-v1:0"
```

## Deploy via CDK

```bash
# Install CDK dependencies
if [ -d "agentcore/cdk" ]; then
    cd agentcore/cdk && npm install --quiet && cd ../..
fi

agentcore deploy --yes
```

## Extract Deployed Resource Info

```bash
# Get agent ARN from status
AGENT_ARN=$(agentcore status --json 2>/dev/null | $PYTHON_CMD -c "
import json, sys
data = json.load(sys.stdin)
for r in data if isinstance(data, list) else data.get('resources', data.get('runtimes', [])):
    if isinstance(r, dict):
        arn = r.get('arn', r.get('runtimeArn', ''))
        if arn: print(arn); break
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
```

## Generate .env Files

**IMPORTANT:** Frontend env files MUST be generated BEFORE `npm run build`,
since Vite bakes env vars into the JS bundle at build time.

```bash
cat > .env << EOF
AGENT_ARN=$AGENT_ARN
AWS_REGION=$AWS_REGION
PROXY_PORT=3001
AGENTCORE_MEMORY_ID=$AGENTCORE_MEMORY_ID
EOF

if [ "$HAS_FRONTEND" = true ]; then
  cat > client/.env.production << EOF
VITE_API_BASE=
VITE_WS_BASE=
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
EOF

  cat > client/.env << EOF
VITE_API_BASE=http://localhost:3001
VITE_WS_BASE=ws://localhost:3001
VITE_COGNITO_POOL_ID=$RUNTIME_POOL_ID
VITE_COGNITO_CLIENT_ID=$RUNTIME_CLIENT_ID
EOF
fi
```

## Teardown (--destroy flag)

```bash
if [ "$1" = "--destroy" ]; then
    # 1. Delete CloudFormation stack (empty S3 first)
    # 2. Destroy AgentCore CDK stack (cdk destroy)
    # 3. Clean up Cognito (delete user pool via AWS CLI)
    # 4. Remove local files (agentcore/, .agentcore_cognito.json, .env, etc.)
    exit 0
fi
```

Order matters: CloudFormation first (S3 bucket must be emptied),
then AgentCore CDK stack, then Cognito, then local files.

## Language-Specific Adaptations

### TypeScript
- `npm install` for dependencies
- `npm run build` for frontend
- Entrypoint: `server/runtime-server.ts`
- `tsx` for TypeScript execution
- Build type: `Container` (CodeZip only supports Python)

### Python
- `pip install -r requirements.txt` for dependencies
- Entrypoint: `server/runtime_server.py` or `app/main.py`
- Build type: `CodeZip` (recommended) or `Container`

## Summary Output

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
echo -e "${YELLOW}Login Credentials:${NC}"
echo "  Username: $RUNTIME_USERNAME"
echo "  Password: $RUNTIME_PASSWORD"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo "  agentcore status                     # Check deployment status"
echo "  agentcore invoke \"Hello\"              # Chat with deployed agent"
echo "  agentcore logs                       # Stream runtime logs"
echo "  agentcore deploy --diff              # Preview changes"
```
