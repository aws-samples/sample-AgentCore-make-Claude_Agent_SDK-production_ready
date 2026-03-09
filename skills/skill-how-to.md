# Claude Code Skills

This directory contains custom [Claude Code skills](https://docs.anthropic.com/en/docs/claude-code/skills) that extend Claude Code with reusable, project-specific capabilities.

## Available Skills

### `agentcore-transform`

Transforms and deploys Claude Agent SDK applications (TypeScript or Python) to AWS Bedrock AgentCore. It integrates AgentCore Memory (STM + LTM), Runtime, Identity (Cognito), and full AWS infrastructure (S3, CloudFront, CloudFormation).

**Trigger phrases:** "deploy to AgentCore", "migrate to AgentCore", "add AgentCore Memory", "deploy my agent to AWS", etc.

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
