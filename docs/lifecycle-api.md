# Lifecycle API

**Endpoint:** `GET /lifecycle`  
**Purpose:** Surface agent lifecycle data for the daroja-intelligence-console.

Refs: DarojaAI/openclaw-gateway#108

## Response Shape

```json
{
  "sessions": [
    {
      "agent_id": "daroja_coding_agent",
      "session_file": "abc123.trajectory.jsonl",
      "last_event_at": "2026-09-14T15:00:00+00:00",
      "event_count": 42,
      "models_used": ["openrouter/xiaomi/mimo-v2.5"]
    }
  ],
  "crons": [],
  "lessons": [],
  "captured_at": "2026-09-14T16:00:00+00:00"
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `sessions` | array | One entry per trajectory file. Sorted most-recent first. |
| `sessions[].agent_id` | string | Agent that owns the session (directory name under `~/.openclaw/agents/`). |
| `sessions[].session_file` | string | Basename of the `.trajectory.jsonl` file. |
| `sessions[].last_event_at` | string\|null | ISO 8601 timestamp of the most recent event, or null if empty. |
| `sessions[].event_count` | int | Total events in the trajectory file. |
| `sessions[].models_used` | string[] | Deduplicated model IDs seen in the session. |
| `crons` | array | **Stub.** Cron data not yet available from this repo. Returns `[]`. |
| `lessons` | array | **Stub.** Lesson data not yet tracked. Returns `[]`. |
| `captured_at` | string | ISO 8601 timestamp of when this report was generated. |

## Health Check

`GET /healthz` returns `{"status": "ok"}`.

## Running

```bash
# One-shot (print report to stdout)
python3 scripts/lifecycle.py --once

# As a server
python3 scripts/lifecycle.py --port 8099 --host 127.0.0.1
```

No external dependencies — uses Python stdlib only.

## Data Sources

| Field | Source | Status |
|-------|--------|--------|
| `sessions` | `~/.openclaw/agents/*/sessions/*.trajectory.jsonl` | ✅ Implemented |
| `crons` | OpenClaw cron config (gateway runtime) | 🔲 Stub — needs gateway runtime access |
| `lessons` | Not yet tracked | 🔲 Stub — no data source identified |

## Integration with Console

The daroja-intelligence-console proxies `/api/lifecycle` to `LIFECYCLE_URL`.
Set `LIFECYCLE_URL=http://127.0.0.1:8099` (or wherever this server runs)
to connect the console's Lifecycle view to this endpoint.
