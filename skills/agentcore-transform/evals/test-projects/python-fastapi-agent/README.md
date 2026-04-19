# Python FastAPI Chat Agent

Minimal Python chat agent using Claude Agent SDK and FastAPI.
Test project for the `agentcore-transform` skill.

## Structure

```
python-fastapi-agent/
├── app/
│   ├── __init__.py
│   ├── main.py          # FastAPI server (REST + WebSocket)
│   ├── ai_client.py     # Claude Agent SDK wrapper
│   └── chat_store.py    # In-memory chat storage
├── requirements.txt
└── README.md
```

## Running

```bash
pip install -r requirements.txt
uvicorn app.main:app --port 3001 --reload
```

## Testing the skill

Run the agentcore-transform skill against this project:
```
cd python-fastapi-agent
# Then ask Claude: "Deploy my Python agent to AgentCore"
```

After transformation, verify with:
```bash
../verify-transform.sh . --lang py
```
