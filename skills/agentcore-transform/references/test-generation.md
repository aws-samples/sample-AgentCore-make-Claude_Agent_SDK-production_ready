# Test Generation Reference

Patterns for generating post-deployment verification tests.

## Test Script Structure

Generate `tests/agentcore-test.sh` — a self-contained shell script that verifies
the AgentCore deployment is working correctly.

```bash
#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} $1: $2"; SKIP=$((SKIP + 1)); }
```

## Test Prerequisites

```bash
# Load configuration
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
fi

if [ ! -f ".agentcore_identity_cognito_user.json" ]; then
  echo -e "${RED}Error: .agentcore_identity_cognito_user.json not found${NC}"
  echo "Run deploy.sh first."
  exit 1
fi

# Parse Cognito credentials
PYTHON_CMD=$(command -v python3 || command -v python)
POOL_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['pool_id'])")
CLIENT_ID=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['client_id'])")
USERNAME=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['username'])")
PASSWORD=$($PYTHON_CMD -c "import json; d=json.load(open('.agentcore_identity_cognito_user.json')); print(d['runtime']['password'])")
REGION=${AWS_REGION:-us-east-1}

# Support --endpoint flag (default: use AGENT_ARN to construct URL)
ENDPOINT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$ENDPOINT" ] && [ -n "$AGENT_ARN" ]; then
  ENCODED_ARN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$AGENT_ARN', safe=''))")
  ENDPOINT="https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$ENCODED_ARN"
fi
```

## Test 1: Authentication

```bash
echo ""
echo "Test 1: Authentication"
echo "======================"

# Get JWT token from Cognito
# IMPORTANT: Double-quote the entire --auth-parameters value.
# Cognito passwords often contain special chars (%, *, =, !) that break
# if only the individual values are quoted.
TOKEN=$(aws cognito-idp initiate-auth \
  --client-id "$CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USERNAME,PASSWORD=$PASSWORD" \
  --region "$REGION" \
  --query 'AuthenticationResult.IdToken' \
  --output text 2>&1) || true

if [ -n "$TOKEN" ] && [ "$TOKEN" != "None" ]; then
  pass "Cognito authentication"
else
  fail "Cognito authentication" "Could not get JWT token"
  echo -e "${RED}Cannot continue without authentication.${NC}"
  exit 1
fi
```

## Test 2: Health Check

```bash
echo ""
echo "Test 2: Health Check"
echo "===================="

# Health check via /invocations
HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "$ENDPOINT/invocations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":{"method":"GET","path":"/health"}}' 2>/dev/null) || true

HTTP_CODE=$(echo "$HEALTH_RESPONSE" | tail -1)
BODY=$(echo "$HEALTH_RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
  pass "Health check endpoint"
else
  fail "Health check" "HTTP $HTTP_CODE"
fi
```

## Test 3: Create Chat

```bash
echo ""
echo "Test 3: Chat CRUD"
echo "=================="

# Create a chat
CREATE_RESPONSE=$(curl -s \
  -X POST "$ENDPOINT/invocations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":{"method":"POST","path":"/api/chats","body":{"title":"Test Chat"}}}')

CHAT_ID=$(echo "$CREATE_RESPONSE" | $PYTHON_CMD -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('output', {}).get('body', {}).get('id', ''))
except: print('')
" 2>/dev/null)

if [ -n "$CHAT_ID" ]; then
  pass "Create chat (id: ${CHAT_ID:0:8}...)"
else
  fail "Create chat" "No chat ID returned"
fi

# List chats
LIST_RESPONSE=$(curl -s \
  -X POST "$ENDPOINT/invocations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":{"method":"GET","path":"/api/chats"}}')

CHAT_COUNT=$(echo "$LIST_RESPONSE" | $PYTHON_CMD -c "
import sys, json
try:
    d = json.load(sys.stdin)
    body = d.get('output', {}).get('body', [])
    print(len(body) if isinstance(body, list) else 0)
except: print(0)
" 2>/dev/null)

if [ "$CHAT_COUNT" -gt 0 ] 2>/dev/null; then
  pass "List chats (count: $CHAT_COUNT)"
else
  fail "List chats" "Expected at least 1 chat"
fi
```

## Test 4: Auth Failure

```bash
echo ""
echo "Test 4: Auth Failure"
echo "===================="

# Request without token should fail
NOAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$ENDPOINT/invocations" \
  -H "Content-Type: application/json" \
  -d '{"input":{"method":"GET","path":"/api/chats"}}' 2>/dev/null) || true

if [ "$NOAUTH_CODE" = "401" ] || [ "$NOAUTH_CODE" = "403" ]; then
  pass "Unauthenticated request rejected (HTTP $NOAUTH_CODE)"
else
  fail "Unauthenticated request" "Expected 401/403, got HTTP $NOAUTH_CODE"
fi
```

## Test 5: WebSocket Connectivity

```bash
echo ""
echo "Test 5: WebSocket"
echo "=================="

# Check if websocat is available
if command -v websocat &>/dev/null; then
  ENCODED_ARN_WS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$AGENT_ARN', safe=''))")
  WS_URL="wss://bedrock-agentcore.$REGION.amazonaws.com/runtimes/$ENCODED_ARN_WS/ws?qualifier=DEFAULT&token=$TOKEN"

  WS_RESPONSE=$(echo '{"type":"subscribe","chatId":"test-ws-'$RANDOM'"}' | \
    timeout 10 websocat -1 "$WS_URL" 2>/dev/null) || true

  if echo "$WS_RESPONSE" | grep -q "connected\|history"; then
    pass "WebSocket connection"
  else
    fail "WebSocket connection" "No valid response"
  fi
else
  skip "WebSocket" "websocat not installed (brew install websocat)"
fi
```

## Test 6: Memory Integration

```bash
echo ""
echo "Test 6: Memory (STM/LTM)"
echo "========================="

if [ -n "$AGENTCORE_MEMORY_ID" ]; then
  # Verify memory resource is active
  MEM_STATUS=$(agentcore memory get "$AGENTCORE_MEMORY_ID" --region "$REGION" 2>&1) || true

  if echo "$MEM_STATUS" | grep -q "ACTIVE"; then
    pass "Memory resource active"
  else
    fail "Memory resource" "Not in ACTIVE state"
  fi

  # Send a message and check it appears in history
  if [ -n "$CHAT_ID" ]; then
    # Get messages for the chat we created
    MSG_RESPONSE=$(curl -s \
      -X POST "$ENDPOINT/invocations" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"input\":{\"method\":\"GET\",\"path\":\"/api/chats/$CHAT_ID/messages\"}}")

    MSG_STATUS=$(echo "$MSG_RESPONSE" | $PYTHON_CMD -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('output', {}).get('statusCode', 0))
except: print(0)
" 2>/dev/null)

    if [ "$MSG_STATUS" = "200" ]; then
      pass "Message retrieval via STM"
    else
      fail "Message retrieval" "Status $MSG_STATUS"
    fi
  fi
else
  skip "Memory tests" "AGENTCORE_MEMORY_ID not set"
fi
```

## Test 7: Cleanup

```bash
echo ""
echo "Test 7: Cleanup"
echo "================"

if [ -n "$CHAT_ID" ]; then
  DEL_RESPONSE=$(curl -s \
    -X POST "$ENDPOINT/invocations" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"input\":{\"method\":\"DELETE\",\"path\":\"/api/chats/$CHAT_ID\"}}")

  DEL_SUCCESS=$(echo "$DEL_RESPONSE" | $PYTHON_CMD -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('output', {}).get('body', {}).get('success', False))
except: print(False)
" 2>/dev/null)

  if [ "$DEL_SUCCESS" = "True" ]; then
    pass "Delete test chat"
  else
    fail "Delete test chat" "Deletion failed"
  fi
fi
```

## Test Summary

```bash
echo ""
echo "==============================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
```

## Adapting Tests for the Project

When generating the test script, adapt based on analysis:

- **No frontend:** Skip CloudFront-specific tests.
- **No WebSocket:** Skip WS connectivity test.
- **No Memory:** Skip STM/LTM tests but keep chat CRUD tests.
- **Custom endpoints:** Adapt route paths from the analysis.
- **Python backend:** Same curl tests (framework-agnostic).
