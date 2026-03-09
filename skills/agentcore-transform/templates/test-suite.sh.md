# Template: tests/agentcore-test.sh

Post-deployment verification test script.

**CRITICAL:** Uses Python for ALL API calls to avoid:
1. Shell quoting issues with Cognito passwords (special chars like `=`, `@`, `)`)
2. SigV4 vs Bearer auth confusion (JWT authorizer = Bearer only, NO SigV4)
3. Fragile JSON parsing via shell heredocs

The test authenticates via OAuth (Cognito JWT) and calls the AgentCore API
with Bearer token + `?qualifier=DEFAULT` query param.

Adapt based on the application's actual endpoints and features.
See `references/test-generation.md` for full documentation.

```bash
#!/bin/bash

# AgentCore Deployment Tests
# Uses Python for all API calls (avoids shell quoting issues with passwords).
# Authentication: OAuth (Cognito JWT) only — no AWS IAM/SigV4 needed.
#
# Usage:
#   ./tests/agentcore-test.sh                                          # Test via AgentCore endpoint
#   ./tests/agentcore-test.sh --endpoint http://localhost:3001         # Test via local proxy
#   ./tests/agentcore-test.sh --endpoint https://d123.cloudfront.net   # Test via CloudFront

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# Prefer .venv Python
if [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
    PYTHON_CMD="$SCRIPT_DIR/.venv/bin/python3"
else
    PYTHON_CMD=$(command -v python3 || command -v python)
fi

# Pass endpoint flag through
ENDPOINT_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --endpoint) ENDPOINT_ARG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

exec $PYTHON_CMD - "$ENDPOINT_ARG" << 'PYTEST'
import json, sys, os, subprocess, urllib.parse, time

# ── Colors ──
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
NC = "\033[0m"

PASS = FAIL = SKIP = 0

def ppass(msg):
    global PASS; PASS += 1; print(f"  {GREEN}PASS{NC} {msg}")
def pfail(msg, detail=""):
    global FAIL; FAIL += 1; print(f"  {RED}FAIL{NC} {msg}: {detail}")
def pskip(msg, detail=""):
    global SKIP; SKIP += 1; print(f"  {YELLOW}SKIP{NC} {msg}: {detail}")

# ── Configuration ──
env_file = os.path.join(os.getcwd(), ".env")
if os.path.exists(env_file):
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k, v)

cognito_file = ".agentcore_identity_cognito_user.json"
if not os.path.exists(cognito_file):
    print(f"{RED}Error: {cognito_file} not found. Run deploy.sh first.{NC}")
    sys.exit(1)

with open(cognito_file) as f:
    cognito = json.load(f)

rt = cognito["runtime"]
CLIENT_ID = rt["client_id"]
USERNAME = rt["username"]
PASSWORD = rt["password"]
# ADAPT: Change default region to match deployment
REGION = os.environ.get("AWS_REGION", "us-east-1")
AGENT_ARN = os.environ.get("AGENT_ARN", "")
MEMORY_ID = os.environ.get("AGENTCORE_MEMORY_ID", "")

# Endpoint
endpoint_arg = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else ""
if endpoint_arg:
    ENDPOINT = endpoint_arg
elif AGENT_ARN:
    encoded = urllib.parse.quote(AGENT_ARN, safe="")
    ENDPOINT = f"https://bedrock-agentcore.{REGION}.amazonaws.com/runtimes/{encoded}"
else:
    print(f"{RED}Error: No endpoint. Set AGENT_ARN in .env or use --endpoint.{NC}")
    sys.exit(1)

print("===============================")
print("AgentCore Deployment Tests")
print("===============================")
print(f"Endpoint: {ENDPOINT}")
print()

# ── Helper: invoke AgentCore via OAuth (Bearer token only, NO SigV4) ──
# CRITICAL: When JWT authorizer is configured, the AgentCore API accepts
# Bearer token directly WITHOUT SigV4 signing. Combining SigV4 + Bearer
# causes "Authorization method mismatch" (403).
SESSION_ID = str(__import__('uuid').uuid4())

def invoke_agentcore(method, path, body=None, token=None):
    """Invoke AgentCore /invocations with Bearer JWT (OAuth mode)."""
    import urllib.request

    url = f"{ENDPOINT}/invocations?qualifier=DEFAULT"
    # ADAPT: Change the path format to match your app's routes
    payload = json.dumps({"input": {"method": method, "path": path, **({"body": body} if body else {})}})

    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream, application/json",
        "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": SESSION_ID,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, data=payload.encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            body_text = e.read().decode()
            return e.code, json.loads(body_text) if body_text else {}
        except:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}

def invoke_agentcore_noauth(method, path, body=None):
    """Invoke without Bearer token to test auth rejection."""
    import urllib.request

    url = f"{ENDPOINT}/invocations?qualifier=DEFAULT"
    payload = json.dumps({"input": {"method": method, "path": path, **({"body": body} if body else {})}})
    headers = {
        "Content-Type": "application/json",
        "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": SESSION_ID,
    }

    req = urllib.request.Request(url, data=payload.encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, {}
    except:
        return 0, {}

# ──────────────────────────────────────────────
# Test 1: OAuth Authentication (Cognito)
# ──────────────────────────────────────────────
print("Test 1: OAuth Authentication (Cognito)")

# CRITICAL: Use subprocess to avoid shell quoting issues with password special chars
try:
    result = subprocess.run(
        ["aws", "cognito-idp", "initiate-auth",
         "--client-id", CLIENT_ID,
         "--auth-flow", "USER_PASSWORD_AUTH",
         "--auth-parameters", f"USERNAME={USERNAME},PASSWORD={PASSWORD}",
         "--region", REGION,
         "--query", "AuthenticationResult.IdToken",
         "--output", "text"],
        capture_output=True, text=True, timeout=15
    )
    TOKEN = result.stdout.strip()
    if TOKEN and TOKEN != "None" and not TOKEN.startswith("An error"):
        ppass(f"Cognito OAuth token obtained ({len(TOKEN)} chars)")
    else:
        pfail("Cognito authentication", result.stderr.strip() or "No token")
        print(f"{RED}Cannot continue without auth.{NC}")
        sys.exit(1)
except Exception as e:
    pfail("Cognito authentication", str(e))
    sys.exit(1)

# ──────────────────────────────────────────────
# Test 2: Create Chat
# ADAPT: Change paths to match your app's API routes
# ──────────────────────────────────────────────
print("\nTest 2: Chat CRUD")

status, resp = invoke_agentcore("POST", "/api/chats", {"title": "Test Chat"}, TOKEN)
output = resp.get("output", {})
chat_body = output.get("body", {})
CHAT_ID = chat_body.get("id", "") if isinstance(chat_body, dict) else ""

if CHAT_ID:
    ppass(f"Create chat (id: {CHAT_ID[:8]}...)")
else:
    pfail("Create chat", f"status={status}, response={json.dumps(resp)[:200]}")

# List chats
status, resp = invoke_agentcore("GET", "/api/chats", token=TOKEN)
output = resp.get("output", {})
chat_list = output.get("body", [])
count = len(chat_list) if isinstance(chat_list, list) else 0

if count > 0:
    ppass(f"List chats (count: {count})")
else:
    pfail("List chats", f"Expected >= 1 chat, got status={status}")

# ──────────────────────────────────────────────
# Test 3: Get Messages
# ──────────────────────────────────────────────
print("\nTest 3: Messages")

if CHAT_ID:
    status, resp = invoke_agentcore("GET", f"/api/chats/{CHAT_ID}/messages", token=TOKEN)
    out_status = resp.get("output", {}).get("statusCode", 0)
    if out_status == 200:
        ppass("Get messages")
    else:
        pfail("Get messages", f"statusCode={out_status}")
else:
    pskip("Get messages", "No chat ID")

# ──────────────────────────────────────────────
# Test 4: Auth Failure (no Bearer token)
# ──────────────────────────────────────────────
print("\nTest 4: Auth Failure (missing Bearer token)")

status, resp = invoke_agentcore_noauth("GET", "/api/chats")
if status in (401, 403):
    ppass(f"Unauthenticated request rejected (HTTP {status})")
else:
    pfail("Unauthenticated request", f"Expected 401/403, got {status}")

# ──────────────────────────────────────────────
# Test 5: WebSocket
# ──────────────────────────────────────────────
print("\nTest 5: WebSocket")
pskip("WebSocket", "Requires interactive client (use browser or websocat)")

# ──────────────────────────────────────────────
# Test 6: Memory
# ──────────────────────────────────────────────
print("\nTest 6: Memory (STM/LTM)")

if MEMORY_ID:
    venv_ac = os.path.join(os.getcwd(), ".venv", "bin", "agentcore")
    ac_cmd = venv_ac if os.path.isfile(venv_ac) else "agentcore"
    try:
        result = subprocess.run(
            [ac_cmd, "memory", "get", MEMORY_ID, "--region", REGION],
            capture_output=True, text=True, timeout=15
        )
        if "ACTIVE" in result.stdout or "ACTIVE" in result.stderr:
            ppass("Memory resource active")
        else:
            pfail("Memory resource", "Not ACTIVE")
    except Exception as e:
        pfail("Memory resource", str(e))
else:
    pskip("Memory", "AGENTCORE_MEMORY_ID not set")

# ──────────────────────────────────────────────
# Test 7: Cleanup
# ──────────────────────────────────────────────
print("\nTest 7: Cleanup")

if CHAT_ID:
    status, resp = invoke_agentcore("DELETE", f"/api/chats/{CHAT_ID}", token=TOKEN)
    success = resp.get("output", {}).get("body", {}).get("success", False)
    if success:
        ppass("Delete test chat")
    else:
        pfail("Delete test chat", f"status={status}")

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
print()
print("===============================")
print(f"Results: {GREEN}{PASS} passed{NC}, {RED}{FAIL} failed{NC}, {YELLOW}{SKIP} skipped{NC}")
print("===============================")

sys.exit(1 if FAIL > 0 else 0)
PYTEST
```
