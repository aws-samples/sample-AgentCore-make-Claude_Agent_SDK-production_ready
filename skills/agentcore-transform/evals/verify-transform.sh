#!/usr/bin/env bash
# verify-transform.sh — Automated verification of agentcore-transform skill output
#
# Usage:
#   ./verify-transform.sh <project-dir> [--lang ts|py] [--verbose]
#
# Verifies that generated code from the agentcore-transform skill meets all
# quality criteria across Categories 4-6 (Transform, Deploy, Test).

set -uo pipefail

PROJECT_DIR="${1:-.}"
LANG="ts"
VERBOSE=false

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang) LANG="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { ((PASS++)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}FAIL${NC} $1"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}WARN${NC} $1"; }

check_file_exists() {
  if [[ -f "$PROJECT_DIR/$1" ]]; then
    pass "File exists: $1"
    return 0
  else
    fail "File missing: $1"
    return 1
  fi
}

check_file_contains() {
  local file="$1" pattern="$2" desc="$3"
  if [[ -f "$PROJECT_DIR/$file" ]] && grep -q "$pattern" "$PROJECT_DIR/$file" 2>/dev/null; then
    pass "$desc"
    return 0
  else
    fail "$desc"
    return 1
  fi
}

check_file_not_contains() {
  local file="$1" pattern="$2" desc="$3"
  if [[ -f "$PROJECT_DIR/$file" ]] && grep -q "$pattern" "$PROJECT_DIR/$file" 2>/dev/null; then
    fail "$desc"
    return 1
  else
    pass "$desc"
    return 0
  fi
}

# ============================================================
# Auto-detect source directory (server/ for TS, app/ or server/ for Python)
if [[ "$LANG" == "ts" ]]; then
  SRC_DIR="server"
else
  if [[ -d "$PROJECT_DIR/app" ]] && [[ ! -d "$PROJECT_DIR/server" ]]; then
    SRC_DIR="app"
  elif [[ -d "$PROJECT_DIR/server" ]]; then
    SRC_DIR="server"
  else
    SRC_DIR="app"
  fi
fi

echo "============================================"
echo "AgentCore Transform Verification"
echo "Project: $PROJECT_DIR"
echo "Language: $LANG"
echo "Source dir: $SRC_DIR"
echo "============================================"
echo ""

# ----------------------------------------------------------
# Category 4: Transform Quality — Memory
# ----------------------------------------------------------
echo "--- Category 4.1: Memory Integration ---"

if [[ "$LANG" == "ts" ]]; then
  MC="$SRC_DIR/memory-client.ts"
  MS="$SRC_DIR/memory-store.ts"
  SR="$SRC_DIR/store.ts"
else
  MC="$SRC_DIR/memory_client.py"
  MS="$SRC_DIR/memory_store.py"
  SR="$SRC_DIR/store.py"
fi

check_file_exists "$MC"
check_file_exists "$MS"
check_file_exists "$SR"

# M1: Blob serialization — must use JSON.stringify (TS) or json.dumps (Python)
if [[ "$LANG" == "ts" ]]; then
  check_file_contains "$MC" "JSON.stringify" "M1: Blob payloads use JSON.stringify()"
else
  check_file_contains "$MC" "json.dumps" "M1: Blob payloads use json.dumps()"
fi

# M2: Java Map parser fallback or multiple JSON.parse fallback paths
if [[ "$LANG" == "ts" ]]; then
  # Accept either a named parseJavaMap function or multiple JSON.parse fallback paths
  PARSE_COUNT=$(grep -c "JSON.parse\|parseJavaMap\|TextDecoder\|DocumentType" "$PROJECT_DIR/$MC" 2>/dev/null || echo "0")
  if [[ "$PARSE_COUNT" -ge 2 ]]; then
    pass "M2: Blob read fallback logic present ($PARSE_COUNT parse paths)"
  else
    fail "M2: Missing blob read fallback (Java Map parser or multi-path JSON.parse)"
  fi
else
  PARSE_COUNT=$(grep -c "json.loads\|parse_java_map\|fallback\|except" "$PROJECT_DIR/$MC" 2>/dev/null || echo "0")
  if [[ "$PARSE_COUNT" -ge 2 ]]; then
    pass "M2: Blob read fallback logic present ($PARSE_COUNT parse paths)"
  else
    fail "M2: Missing blob read fallback (Java Map parser or multi-path json.loads)"
  fi
fi

# M3: actorId parameter in store methods
if [[ "$LANG" == "ts" ]]; then
  check_file_contains "$MS" "actorId" "M3: Memory store methods accept actorId"
else
  check_file_contains "$MS" "actor_id" "M3: Memory store methods accept actor_id"
fi

# M4: Feature flag in store router
if [[ "$LANG" == "ts" ]]; then
  check_file_contains "$SR" "AGENTCORE_MEMORY_ID" "M4: Store router checks AGENTCORE_MEMORY_ID"
else
  check_file_contains "$SR" "AGENTCORE_MEMORY_ID" "M4: Store router checks AGENTCORE_MEMORY_ID"
fi

echo ""
echo "--- Category 4.2: LTM Active Injection ---"

# M5: searchLTM actively called (not just defined)
if [[ "$LANG" == "ts" ]]; then
  # Check session.ts or similar for searchLTM call
  CALL_FILE=$(grep -rl "searchLTM\|search_ltm" "$PROJECT_DIR/$SRC_DIR/" --include="*.ts" 2>/dev/null | grep -v "memory-client" | head -1 || true)
  if [[ -n "$CALL_FILE" ]]; then
    pass "M5: searchLTM() called outside memory-client (in $(basename "$CALL_FILE"))"
  else
    fail "M5: searchLTM() not called outside memory-client — LTM is dead code"
  fi
else
  CALL_FILE=$(grep -rl "search_ltm" "$PROJECT_DIR/$SRC_DIR/" --include="*.py" 2>/dev/null | grep -v "memory_client" | head -1 || true)
  if [[ -n "$CALL_FILE" ]]; then
    pass "M5: search_ltm() called outside memory_client (in $(basename "$CALL_FILE"))"
  else
    fail "M5: search_ltm() not called outside memory_client — LTM is dead code"
  fi
fi

# M6: System prompt mentions LTM context
if [[ "$LANG" == "ts" ]]; then
  AI_CLIENT=$(find "$PROJECT_DIR/$SRC_DIR" -name "ai-client.ts" -o -name "ai_client.ts" 2>/dev/null | head -1 || true)
  if [[ -n "$AI_CLIENT" ]] && grep -q "previous conversations\|LTM\|long.term\|Relevant context" "$AI_CLIENT" 2>/dev/null; then
    pass "M6: System prompt updated with LTM context instructions"
  else
    fail "M6: System prompt missing LTM context instructions"
  fi
else
  AI_CLIENT=$(find "$PROJECT_DIR/$SRC_DIR" -name "ai_client.py" -o -name "ai-client.py" 2>/dev/null | head -1 || true)
  if [[ -n "$AI_CLIENT" ]] && grep -q "previous conversations\|LTM\|long.term\|Relevant context" "$AI_CLIENT" 2>/dev/null; then
    pass "M6: System prompt updated with LTM context instructions"
  else
    fail "M6: System prompt missing LTM context instructions"
  fi
fi

echo ""
echo "--- Category 4.3: Model Configuration ---"

# M7: Model reads from env var
if [[ "$LANG" == "ts" ]]; then
  if grep -rq "process.env.ANTHROPIC_MODEL\|process\.env\[.ANTHROPIC_MODEL.\]" "$PROJECT_DIR/$SRC_DIR/" --include="*.ts" 2>/dev/null; then
    pass "M7: Model reads from ANTHROPIC_MODEL env var"
  else
    fail "M7: Model not configurable via ANTHROPIC_MODEL env var"
  fi
else
  if grep -rq "os.environ.*ANTHROPIC_MODEL\|os\.getenv.*ANTHROPIC_MODEL" "$PROJECT_DIR/$SRC_DIR/" --include="*.py" 2>/dev/null; then
    pass "M7: Model reads from ANTHROPIC_MODEL env var"
  else
    fail "M7: Model not configurable via ANTHROPIC_MODEL env var"
  fi
fi

echo ""
echo "--- Category 4.4: Runtime Server ---"

if [[ "$LANG" == "ts" ]]; then
  RS="$SRC_DIR/runtime-server.ts"
else
  RS="$SRC_DIR/runtime_server.py"
fi

check_file_exists "$RS"

# M8: Port 8080
check_file_contains "$RS" "8080" "M8: Runtime server listens on port 8080"

# M9: /invocations endpoint
check_file_contains "$RS" "invocations" "M9: /invocations endpoint present"

# M10: /health endpoint
check_file_contains "$RS" "health" "M10: /health endpoint present"

echo ""
echo "--- Category 4.5: Authentication ---"

if [[ "$LANG" == "ts" ]]; then
  AUTH="$SRC_DIR/auth.ts"
else
  AUTH="$SRC_DIR/auth.py"
fi

check_file_exists "$AUTH"

# M11: actorId extraction
if [[ "$LANG" == "ts" ]]; then
  check_file_contains "$AUTH" "sub\|cognito:username" "M11: Auth extracts sub/cognito:username for actorId"
else
  check_file_contains "$AUTH" "sub\|cognito:username" "M11: Auth extracts sub/cognito:username for actorId"
fi

# M12: Dev mode fallback
if [[ "$LANG" == "ts" ]]; then
  check_file_contains "$AUTH" "anonymous\|skip\|dev" "M12: Dev mode auth fallback present"
else
  check_file_contains "$AUTH" "anonymous\|skip\|dev" "M12: Dev mode auth fallback present"
fi

echo ""
echo "--- Category 4.6: Frontend Adaptation ---"

if [[ -d "$PROJECT_DIR/client" ]]; then
  # M14: Production mode detection
  if grep -rq "VITE_COGNITO\|HAS_COGNITO\|isProduction\|IS_PRODUCTION" "$PROJECT_DIR/client/" --include="*.ts" --include="*.tsx" 2>/dev/null; then
    pass "M14: Frontend production mode detection present"
  else
    fail "M14: Frontend missing production mode detection"
  fi

  # M15: /invocations path with /api prefix
  if grep -rq "/api/chats\|/api/" "$PROJECT_DIR/client/" --include="*.ts" --include="*.tsx" 2>/dev/null; then
    pass "M15: Frontend API paths include /api prefix"
  else
    fail "M15: Frontend API paths missing /api prefix in /invocations body"
  fi

  # M16: Login form
  if grep -rq "login\|Login\|signIn\|SignIn\|authenticate" "$PROJECT_DIR/client/" --include="*.ts" --include="*.tsx" 2>/dev/null; then
    pass "M16: Cognito login form present"
  else
    fail "M16: Cognito login form missing"
  fi

  # M17: vite-env.d.ts or vite/client in tsconfig types
  if [[ -f "$PROJECT_DIR/client/vite-env.d.ts" ]]; then
    pass "M17: client/vite-env.d.ts exists"
  elif grep -rq "vite/client" "$PROJECT_DIR/tsconfig.json" 2>/dev/null; then
    pass "M17: vite/client referenced in tsconfig.json (alternative to vite-env.d.ts)"
  else
    fail "M17: Missing client/vite-env.d.ts (import.meta.env will cause TS errors)"
  fi

  # VITE_AWS_REGION
  if [[ -f "$PROJECT_DIR/.env.production" ]] || [[ -f "$PROJECT_DIR/.env" ]]; then
    if grep -rq "VITE_AWS_REGION" "$PROJECT_DIR/.env"* 2>/dev/null; then
      pass "M18-env: VITE_AWS_REGION in env files"
    else
      warn "M18-env: VITE_AWS_REGION not found in env files (may be generated by deploy.sh)"
    fi
  else
    warn "M18-env: No .env files found (expected to be generated by deploy.sh)"
  fi
else
  warn "No client/ directory found — skipping frontend checks"
fi

echo ""
echo "--- Category 4.7: Package Dependencies ---"

if [[ "$LANG" == "ts" ]]; then
  PKG="package.json"
  check_file_contains "$PKG" "@aws-sdk/client-bedrock-agentcore" "M18: @aws-sdk/client-bedrock-agentcore in deps"
  check_file_contains "$PKG" "@opentelemetry/auto-instrumentations-node" "M18: @opentelemetry/auto-instrumentations-node in deps"
  check_file_contains "$PKG" "aws-jwt-verify" "M18: aws-jwt-verify in deps"
  check_file_contains "$PKG" "dotenv" "M18: dotenv in deps"
  check_file_contains "$PKG" "uuid" "M18: uuid in deps"

  # npm scripts
  check_file_contains "$PKG" "start:runtime" "M18: start:runtime npm script"
else
  REQ=$(find "$PROJECT_DIR" -maxdepth 1 -name "requirements*.txt" | head -1 || true)
  if [[ -n "$REQ" ]]; then
    check_file_contains "$(basename "$REQ")" "boto3" "M19: boto3 in requirements"
    check_file_contains "$(basename "$REQ")" "pyjwt" "M19: pyjwt in requirements"
    check_file_contains "$(basename "$REQ")" "python-dotenv" "M19: python-dotenv in requirements"
  else
    fail "M19: No requirements.txt found"
  fi
fi

# ----------------------------------------------------------
# Category 5: Deploy Script
# ----------------------------------------------------------
echo ""
echo "--- Category 5: Deploy Script ---"

check_file_exists "deploy.sh"

if [[ -f "$PROJECT_DIR/deploy.sh" ]]; then
  # D1: Dockerfile patch for tsx
  if [[ "$LANG" == "ts" ]]; then
    check_file_contains "deploy.sh" "npm run build\|npm prune\|npx tsx" "D1: Dockerfile patch logic present"
  fi

  # D2: Container env vars
  check_file_contains "deploy.sh" "CLAUDE_CODE_USE_BEDROCK" "D2: CLAUDE_CODE_USE_BEDROCK env var"
  check_file_contains "deploy.sh" "ANTHROPIC_MODEL" "D2: ANTHROPIC_MODEL env var"
  check_file_contains "deploy.sh" "AGENTCORE_MEMORY_ID" "D2: AGENTCORE_MEMORY_ID env var"

  # D3: Inference profile resolution (check for region-based prefix logic or literal profile IDs)
  if grep -q 'us\.\|eu\.\|apac\.\|global\.\|MODEL_PREFIX\|inference.profile\|INFERENCE_PROFILE' "$PROJECT_DIR/deploy.sh" 2>/dev/null; then
    pass "D3: Regional inference profile resolution logic present"
  else
    fail "D3: Missing regional inference profile resolution"
  fi

  # D4: Agent name sanitization
  if grep -q "sed.*-.*_\|tr.*-.*_\|replace.*-.*_\|gsub\|hyphen\|underscore" "$PROJECT_DIR/deploy.sh" 2>/dev/null; then
    pass "D4: Agent name hyphen-to-underscore sanitization"
  else
    warn "D4: No explicit agent name sanitization found (may use safe name)"
  fi

  # D5: Timing hints — check for wait messages or duration estimates
  TIMING_COUNT=$(grep -c "minute\|This may take\|Estimated\|may take\|waiting\|Waiting\|~[0-9]\|be patient" "$PROJECT_DIR/deploy.sh" 2>/dev/null || echo "0")
  if [[ "$TIMING_COUNT" -ge 3 ]]; then
    pass "D5: Timing hints present ($TIMING_COUNT found)"
  elif [[ "$TIMING_COUNT" -ge 1 ]]; then
    warn "D5: Some timing hints present ($TIMING_COUNT) but could be more explicit"
  else
    fail "D5: Missing timing hints for long-running operations"
  fi

  # D6: CloudFormation update guard
  if grep -q "no.updates\|No updates\|update.*complete\|UPDATE_COMPLETE\|ValidationError" "$PROJECT_DIR/deploy.sh" 2>/dev/null; then
    pass "D6: CloudFormation update guard present"
  else
    warn "D6: CloudFormation update guard not detected (may not have frontend)"
  fi

  # D7: --destroy flag
  check_file_contains "deploy.sh" "\-\-destroy" "D7: --destroy flag supported"

  # D8: .env generation
  check_file_contains "deploy.sh" "\.env" "D8: .env file generation"

  # D9: .gitignore update (in deploy.sh or done directly to .gitignore)
  if grep -q "gitignore" "$PROJECT_DIR/deploy.sh" 2>/dev/null; then
    pass "D9: .gitignore update logic in deploy.sh"
  elif [[ -f "$PROJECT_DIR/.gitignore" ]] && grep -q "agentcore" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
    pass "D9: .gitignore already contains AgentCore entries (updated directly)"
  else
    fail "D9: .gitignore not updated with AgentCore entries"
  fi

  # D10: Python venv handling
  if [[ "$LANG" == "py" ]]; then
    check_file_contains "deploy.sh" "venv\|AGENTCORE_CMD" "D10: Python venv handling"
  fi

  # D11: macOS compatibility — check for actual grep -P usage (not in comments)
  if grep -v "^[[:space:]]*#" "$PROJECT_DIR/deploy.sh" 2>/dev/null | grep -q "grep -P"; then
    fail "D11: Uses grep -P in code (macOS incompatible)"
  else
    pass "D11: No grep -P in executable code (macOS compatible)"
  fi
fi

# ----------------------------------------------------------
# Category 5.1: Infrastructure
# ----------------------------------------------------------
echo ""
echo "--- Category 5.1: Infrastructure ---"

if [[ -d "$PROJECT_DIR/client" ]]; then
  check_file_exists "infra/template.yaml"
  check_file_exists "infra/cloudfront-function.js"

  if [[ -f "$PROJECT_DIR/infra/cloudfront-function.js" ]]; then
    check_file_contains "infra/cloudfront-function.js" "token" "CloudFront Function handles token"
    check_file_contains "infra/cloudfront-function.js" "authorization\|Authorization" "CloudFront Function injects Authorization header"
  fi

  if [[ -f "$PROJECT_DIR/infra/template.yaml" ]]; then
    check_file_contains "infra/template.yaml" "S3\|s3" "CloudFormation includes S3"
    check_file_contains "infra/template.yaml" "CloudFront\|cloudfront" "CloudFormation includes CloudFront"
    check_file_contains "infra/template.yaml" "invocations" "CloudFormation routes /invocations"
  fi
else
  warn "No client/ directory — skipping infrastructure checks"
fi

# ----------------------------------------------------------
# Category 6: Test Script
# ----------------------------------------------------------
echo ""
echo "--- Category 6: Test Script ---"

# Search in multiple common locations for test scripts
TEST_SCRIPT=$(find "$PROJECT_DIR" \( -path "*/tests/agentcore-test*" -o -path "*/tests/test*agentcore*" -o -path "*agentcore-test*" -o -path "*/test-suite*" \) ! -path "*/node_modules/*" ! -path "*/skills/*" ! -path "*/.git/*" 2>/dev/null | head -1 || true)

if [[ -n "$TEST_SCRIPT" ]]; then
  pass "Test script exists: $TEST_SCRIPT"
  # Use the absolute path for all checks
  TSP_ABS="$TEST_SCRIPT"

  check_file_contains_abs() {
    local file="$1" pattern="$2" desc="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
      pass "$desc"
    else
      fail "$desc"
    fi
  }

  # TS1: Python-based API calls
  check_file_contains_abs "$TSP_ABS" "urllib\|requests\|python\|Python" "TS1: Uses Python for API calls (not curl)"

  # TS2: Bearer-only auth
  check_file_contains_abs "$TSP_ABS" "Bearer" "TS2: Uses Bearer token auth"

  # TS3: qualifier=DEFAULT
  check_file_contains_abs "$TSP_ABS" "qualifier=DEFAULT\|qualifier" "TS3: /invocations calls include qualifier"

  # TS4: Session header
  check_file_contains_abs "$TSP_ABS" "Session-Id\|session.id\|SESSION_ID" "TS4: Runtime session ID header"

  # TS5: Auth failure test
  check_file_contains_abs "$TSP_ABS" "401\|403\|unauth\|Unauth\|no.token\|without.*token" "TS5: Auth failure test"

  # TS6: Memory verification
  check_file_contains_abs "$TSP_ABS" "memory\|Memory\|ACTIVE" "TS6: Memory resource verification"

  # TS7: Cleanup
  check_file_contains_abs "$TSP_ABS" "DELETE\|delete\|cleanup\|clean" "TS7: Test cleanup"

  # TS8: --endpoint flag
  check_file_contains_abs "$TSP_ABS" "\-\-endpoint" "TS8: --endpoint flag supported"
else
  fail "No test script found in tests/ directory"
fi

# ----------------------------------------------------------
# Security Checks
# ----------------------------------------------------------
echo ""
echo "--- Security ---"

# S1: No full token logging
if grep -rn "console.log.*token\|print.*token\|logger.*token" "$PROJECT_DIR/$SRC_DIR/" --include="*.ts" --include="*.py" 2>/dev/null | grep -v "first\|last\|substr\|slice\|\[:.\]\|truncat" | grep -v "\.env\|config\|#\|//.*token" | head -3 | grep -q .; then
  warn "S1: Possible full token logging detected — review manually"
else
  pass "S1: No obvious full token logging"
fi

# S2: Sensitive files in .gitignore
if [[ -f "$PROJECT_DIR/.gitignore" ]]; then
  check_file_contains ".gitignore" "\.env" "S3: .env in .gitignore"
  check_file_contains ".gitignore" "agentcore.*cli\|agentcore.*cdk\|bedrock_agentcore" "S3: AgentCore config in .gitignore"
  check_file_contains ".gitignore" "cognito\|identity" "S3: Cognito credentials file in .gitignore"
else
  fail "S3: No .gitignore file found"
fi

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
echo ""
echo "============================================"
echo "RESULTS"
echo "============================================"
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
echo -e "  ${YELLOW}WARN: $WARN${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All checks passed!${NC}"
  exit 0
else
  echo -e "${RED}$FAIL check(s) failed. Review output above.${NC}"
  exit 1
fi
