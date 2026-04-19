# Claude Code Skills

This directory contains custom [Claude Code skills](https://docs.anthropic.com/en/docs/claude-code/skills) that extend Claude Code with reusable, project-specific capabilities.

## Available Skills

### `agentcore-transform`

Transforms and deploys Claude Agent SDK applications (TypeScript or Python) to AWS Bedrock AgentCore. It integrates AgentCore Memory (STM + LTM), Runtime, Identity (Cognito), and full AWS infrastructure (S3, CloudFront, CloudFormation).

**Trigger phrases:** "deploy to AgentCore", "migrate to AgentCore", "add AgentCore Memory", "deploy my agent to AWS", etc.

### `ac-evaluation-transform`

Adds OpenTelemetry instrumentation (traces + structured logs + CloudWatch EMF metrics) to a Claude Agent SDK agent so that all 9 Amazon Bedrock AgentCore built-in evaluators pass with zero errors. The skill modifies **only** the instrumentation layer — tools, prompts, and application logic are preserved byte-for-byte.

**Trigger phrases:**

- "add OTEL to my Claude agent so it works with AgentCore evaluations"
- "my `agentcore run eval` keeps reporting `LogEventMissingException` / `AgentSpanMappingException` / `span data is incomplete`"
- "spans are in `aws/spans` but eval says the log event is missing"
- "make my Claude Agent SDK app compatible with Bedrock evaluations"
- "instrument a Claude agent running outside AgentCore Runtime for observability"

**What it produces.** A Claude Agent SDK agent file (or a shared `_instrumentation.py` module + thin agent file) containing:

| Component | Where in the skill |
|---|---|
| OTEL Resource with `aws.service.type`, `aws.log.group.names` (suffixed `-{ENDPOINT}`), `cloud.resource_id` | Step 2 |
| TracerProvider with `OTLPAwsSpanExporter` + `BaggageSpanProcessor`, scope `strands.telemetry.tracer` | Step 3 |
| LoggerProvider with two loggers under `strands.telemetry.tracer` and `opentelemetry.instrumentation.botocore.bedrock-runtime` | Step 4 |
| MeterProvider with `AwsCloudWatchEmfExporter` and Strands-parity metric instruments | Step 5 |
| `pre_tool_use_hook` / `post_tool_use_hook` with parented tool spans and per-tool I/O summary logs | Step 7 |
| `invoke_agent` → `execute_event_loop_cycle` → `chat` → `chat <model>` span hierarchy | Step 8 |
| `invoke_agent`-level I/O summary with user-only input and `tool.result`-enriched output | Step 9 |
| `session.id` propagation via OTEL baggage | Step 10 |
| Clean shutdown: traces → logs → metrics | Step 11 |

**Usage:**

```
In the project containing your Claude Agent SDK agent, ask:
  "Apply the ac-evaluation-transform skill to <path/to/agent.py> — the target AgentCore runtime id is <AGENT_ID> and endpoint is DEFAULT."
```

The skill will work through Steps 1–11 inline, reading `references/*.md` as needed. It does not prompt for phased approval — it produces the instrumented file in one pass.

**Post-transform verification.**

Because telemetry bugs produce 400 errors that `BatchSpanProcessor`/`BatchLogRecordProcessor` silently swallow, always sanity-check in CloudWatch before running evaluation:

```bash
# 1. Run the agent once with a recorded session id
python your_agent.py --session-id "verify-$(date +%s)" --query "hello"

# 2. Wait ~4 minutes for CloudWatch ingestion
sleep 240

# 3. Confirm the runtime-logs stream exists in the -{ENDPOINT}-suffixed group
aws logs describe-log-streams \
  --log-group-name "/aws/bedrock-agentcore/runtimes/<AGENT_ID>-DEFAULT" \
  --log-stream-name-prefix runtime-logs

# 4. Logs Insights: check both struct logs AND invoke_agent span exist, then
#    match their spanIds
#    In log group /aws/bedrock-agentcore/runtimes/<AGENT_ID>-DEFAULT:
#      fields @timestamp, scope.name, attributes.session.id, spanId
#      | filter attributes.session.id = "<sid>"
#    In log group aws/spans:
#      fields @timestamp, name, spanId
#      | filter attributes.session.id = "<sid>" and name like /invoke_agent/

# 5. Only after step 4 confirms a spanId match, run the evaluator:
agentcore run eval \
  --runtime-arn arn:aws:bedrock-agentcore:<region>:<acct>:runtime/<AGENT_ID> \
  --region <region> \
  --session-id "<sid>" \
  --evaluator-arn arn:aws:bedrock-agentcore:::evaluator/Builtin.Helpfulness
```

A successful result looks like `aggregateScore > 0` with every `sessionScores[].errorMessage` empty. If you get `LogEventMissingException` despite the I/O summary log being present, 99% of the time it's the log-group-suffix mismatch covered in Step 2 — re-read that step.

**Prerequisites** (easy to miss):
- **CloudWatch Transaction Search enabled** in the target region. Check with `aws xray get-trace-segment-destination --region <region>`; `Status` must be `ACTIVE`.
- IAM permissions for the running identity to write CloudWatch Logs + X-Ray traces; eval CLI needs `logs:StartQuery`, `logs:GetQueryResults`, and `bedrock-agentcore:Evaluate`.

**Iterating on the skill itself.**

- `evals/evals.json` — five eval prompts covering triggering, the log-group-suffix regression, missing per-tool I/O log, add-from-vanilla, from-scratch, and post-transform verification. Each entry carries an `expectations[]` array suitable for automated grading.
- `evals/fixtures/vanilla_math_agent.py` — zero-OTEL input for the add-from-vanilla case.
- `evals/fixtures/tool_hook_missing_io_log.py` — partial-instrumentation input for the missing-per-tool-log case.

Run evals with the skill-creator workflow (spawn with-skill + baseline subagents, then aggregate). When opentelemetry-sdk, aws-opentelemetry-distro, or the AgentCore Evaluation API itself ships a breaking change, re-run the evals to confirm the skill still produces byte-compatible output.

## Installation

Skills can be installed at two levels:

```bash
# Global install (available in all projects)
mkdir -p ~/.claude/skills
cp -r skills/agentcore-transform ~/.claude/skills/

# Project-level install (this project only)
mkdir -p .claude/skills
cp -r skills/agentcore-transform .claude/skills/
```

## Dependencies

```bash
# create Python virtual environment at your project root directory
cd path/to/your/project
python3 -m venv .venv

# clone Anthropics chatapp sample or use your own application
git clone https://github.com/anthropics/claude-agent-sdk-demos.git
cd claude-agent-sdk-demos/simple-chatapp
rm package-lock.json
npm install
```

## Usage

### 1. Verify the skill is loaded

Open Claude Code and ask:

```
What skills do you have available?
```

Or type `/skills` in Claude window.

The skill should appear as `agentcore-transform`.

### 2. Trigger the skill

Navigate to a Claude Agent SDK project and use one of the trigger phrases:

```
Deploy claude-agent-sdk-demos/simple-chatapp to AgentCore
```

or

```
Migrate claude-agent-sdk-demos/simple-chatapp to AgentCore
```

### 3. Follow the interactive phases

The skill runs in 5 phases, pausing for your approval after Phase 1 and Phase 2:

| Phase | Description | User Action |
|-------|-------------|-------------|
| **Phase 1: Analyze** | Scans the project, detects language/framework/storage/auth/frontend | Review the analysis report and confirm |
| **Phase 2: Plan** | Lists files to create and modify | Review the plan and confirm (or skip features) |
| **Phase 3: Transform** | Generates and modifies all code files | Automatic |
| **Phase 4: Deploy** | Generates `deploy.sh` and CloudFormation infrastructure | Run `./deploy.sh` to deploy |
| **Phase 5: Test** | Generates `tests/agentcore-test.sh` for post-deployment verification | Run the test script |

## Skill Structure

Each skill is a directory containing:

```
agentcore-transform/
  SKILL.md              # Skill definition (name, description, instructions)
  references/           # Detailed integration guides read during execution
  templates/            # Code templates adapted to the user's project
  evals/                # Evaluation tests for measuring skill quality
```

- **`SKILL.md`** -- The main skill file. Contains the name, trigger description, required tools, and the full multi-phase workflow instructions.
- **`references/`** -- Deep-dive docs on each integration area (memory, runtime, identity, frontend, deploy script, test generation, lessons learned).
- **`templates/`** -- Code templates for generated files (`.ts` and `.py` variants). These are adapted to the user's actual code during transformation, never copied verbatim.
- **`evals/`** -- JSON eval definitions for testing the skill with `claude skill eval`.
