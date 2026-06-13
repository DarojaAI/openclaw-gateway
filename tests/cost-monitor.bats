#!/usr/bin/env bats
#
# BATS tests for scripts/cost-monitor.py
#
# What we're guarding
# -------------------
# The cost monitor is the user-facing surface for per-agent OpenRouter
# spend attribution. It is exposed as the ``cost-report`` and
# ``context-health`` Discord slash commands (see
# config/skills/cost-report/SKILL.md and
# config/skills/context-health/SKILL.md). If it silently returns
# "no data" when there is data, attribution goes dark without any
# deploy failure. If it sums the wrong fields, the report is
# silently wrong.
#
# The test surface is the public functions: aggregate_by_agent_and_model,
# aggregate_compaction_events, _load_cost_table, resolve_cost_block,
# handle_cost_report_command, handle_context_health_command, and the
# CLI subcommands. We drive them with synthetic trajectory files under
# a temporary agents root.
#
# The trajectory format follows the openclaw-trajectory schema with
# schemaVersion 1, events of type model.completed and context.compiled.
# See issue #830 for the design rationale (the rewrite from the SQLite
# data source to the trajectory file data source).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/cost-monitor.py"
    # BATS_TEST_TMPDIR is provided by bats 1.5+; fall back to mktemp on
    # older versions (this repo's CI runner uses bats 1.2).
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BATS_TEST_TMPDIR
    WORK="$BATS_TEST_TMPDIR/openclaw"
    mkdir -p "$WORK/agents"
    export OPENCLAW_AGENTS_ROOT="$WORK/agents"
    # Synthetic gateway config with non-zero pricing so we can assert
    # that cost is computed from the formula fallback (when the
    # trajectory doesn't pre-record usage.cost.total).
    WORK_CONFIG="$BATS_TEST_TMPDIR/openclaw.json"
    cat > "$WORK_CONFIG" <<'JSON'
{
  "models": {
    "providers": {
      "openrouter": {
        "models": [
          {
            "id": "anthropic/claude-sonnet-4.5",
            "cost": {"input": 0.003, "output": 0.015, "cacheRead": 0.0, "cacheWrite": 0.0}
          },
          {
            "id": "minimax/minimax-m2.7",
            "cost": {"input": 0.00025, "output": 0.001, "cacheRead": 0.0, "cacheWrite": 0.0}
          }
        ]
      }
    }
  }
}
JSON
    export OPENCLAW_GATEWAY_CONFIG="$WORK_CONFIG"
}

teardown() {
    if [ -n "$BATS_TEST_TMPDIR" ] && [ -d "$BATS_TEST_TMPDIR/openclaw" ]; then
        rm -rf "$BATS_TEST_TMPDIR/openclaw" "$BATS_TEST_TMPDIR/openclaw.json"
    fi
}

# Helper: write a trajectory file under agents/<id>/sessions/<uuid>.trajectory.jsonl
_seed_trajectory() {
    local agent_id="$1"
    local session_id="$2"
    local body="$3"
    mkdir -p "$OPENCLAW_AGENTS_ROOT/$agent_id/sessions"
    printf '%s\n' "$body" > "$OPENCLAW_AGENTS_ROOT/$agent_id/sessions/${session_id}.trajectory.jsonl"
}

# ─── _load_cost_table ─────────────────────────────────────────────────

@test "load_cost_table: returns empty dict when config is missing" {
    OPENCLAW_GATEWAY_CONFIG="$BATS_TEST_TMPDIR/does-not-exist.json" run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
print(cost_monitor._load_cost_table(Path('$BATS_TEST_TMPDIR/does-not-exist.json')))
"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

@test "load_cost_table: parses models with cost blocks" {
    run python3 -c "
import sys, json
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
table = cost_monitor._load_cost_table(Path('$WORK_CONFIG'))
print(json.dumps(table, sort_keys=True))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"anthropic/claude-sonnet-4.5"'* ]]
    [[ "$output" == *'"input": 0.003'* ]]
    [[ "$output" == *'"minimax/minimax-m2.7"'* ]]
}

@test "load_cost_table: also indexes bare model name and lowercased variants" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
table = cost_monitor._load_cost_table(Path('$WORK_CONFIG'))
# bare names
assert 'claude-sonnet-4.5' in table, 'bare name not indexed'
assert 'minimax-m2.7' in table, 'bare name not indexed'
# lowercase
assert 'anthropic/claude-sonnet-4.5'.lower() in table, 'lowercased not indexed'
print('ok')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

# ─── resolve_cost_block ───────────────────────────────────────────────

@test "resolve_cost_block: exact match wins" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
table = cost_monitor._load_cost_table(Path('$WORK_CONFIG'))
block = cost_monitor.resolve_cost_block('anthropic/claude-sonnet-4.5', table)
print(block['input'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "0.003" ]
}

@test "resolve_cost_block: bare model name is a fallback" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
table = cost_monitor._load_cost_table(Path('$WORK_CONFIG'))
block = cost_monitor.resolve_cost_block('claude-sonnet-4.5', table)
print(block['output'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "0.015" ]
}

@test "resolve_cost_block: returns None for unknown model" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
table = cost_monitor._load_cost_table(Path('$WORK_CONFIG'))
block = cost_monitor.resolve_cost_block('unknown/model', table)
print(repr(block))
"
    [ "$status" -eq 0 ]
    [ "$output" = "None" ]
}

# ─── iter_model_completed ─────────────────────────────────────────────

@test "iter_model_completed: yields nothing for empty agents root" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
events = list(cost_monitor.iter_model_completed(Path('$OPENCLAW_AGENTS_ROOT'), days=None))
print(len(events))
"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "iter_model_completed: parses a single model.completed event" {
    _seed_trajectory "alpha" "11111111-1111-1111-1111-111111111111" \
'{"type":"model.completed","data":{"agentId":"alpha","usage":{"input":100,"output":50,"cacheRead":10,"cacheWrite":5,"cost":{"total":0.0001}}},"modelId":"anthropic/claude-sonnet-4.5","ts":"2026-06-13T10:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
events = list(cost_monitor.iter_model_completed(Path('$OPENCLAW_AGENTS_ROOT')))
assert len(events) == 1, len(events)
agent, model, usage, ts = events[0]
print(agent, model, usage['input'], usage['output'], usage['cost']['total'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "alpha anthropic/claude-sonnet-4.5 100 50 0.0001" ]
}

@test "iter_model_completed: tolerates truncated tail lines" {
    _seed_trajectory "beta" "22222222-2222-2222-2222-222222222222" \
'{"type":"model.completed","data":{"agentId":"beta","usage":{"input":1,"output":1}},"modelId":"minimax/minimax-m2.7","ts":"2026-06-13T10:00:00Z"}
{"type":"model.completed","data":{"agentId":"beta","usage":{"input":'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
events = list(cost_monitor.iter_model_completed(Path('$OPENCLAW_AGENTS_ROOT')))
print(len(events))
"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "iter_model_completed: agent_id extracted from sessionKey prefix" {
    _seed_trajectory "gamma" "33333333-3333-3333-3333-333333333333" \
'{"type":"model.completed","sessionKey":"agent:gamma:discord:c1","data":{"usage":{"input":5,"output":1}},"modelId":"minimax/minimax-m2.7","ts":"2026-06-13T10:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
events = list(cost_monitor.iter_model_completed(Path('$OPENCLAW_AGENTS_ROOT')))
print(events[0][0])
"
    [ "$status" -eq 0 ]
    [ "$output" = "gamma" ]
}

# ─── aggregate_by_agent_and_model ─────────────────────────────────────

@test "aggregate_by_agent_and_model: empty input returns empty dict" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
print(cost_monitor.aggregate_by_agent_and_model(Path('$OPENCLAW_AGENTS_ROOT')))
"
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

@test "aggregate_by_agent_and_model: pre-computed usage.cost.total takes precedence" {
    _seed_trajectory "alpha" "11111111-1111-1111-1111-111111111111" \
'{"type":"model.completed","data":{"agentId":"alpha","usage":{"input":1000,"output":500,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.12345}}},"modelId":"anthropic/claude-sonnet-4.5","ts":"2026-06-13T10:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
agg = cost_monitor.aggregate_by_agent_and_model(Path('$OPENCLAW_AGENTS_ROOT'), days=None, config_path=Path('$WORK_CONFIG'))
print(agg['alpha']['total']['cost_usd'])
"
    [ "$status" -eq 0 ]
    # Should be 0.12345 (the precomputed total), not the formula's
    # ~0.0105 (= 1000*0.003/1M + 500*0.015/1M).
    [ "$output" = "0.12345" ]
}

@test "aggregate_by_agent_and_model: formula fallback when no pre-computed cost" {
    _seed_trajectory "beta" "22222222-2222-2222-2222-222222222222" \
'{"type":"model.completed","data":{"agentId":"beta","usage":{"input":1000000,"output":100000}},"modelId":"minimax/minimax-m2.7","ts":"2026-06-13T10:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
agg = cost_monitor.aggregate_by_agent_and_model(Path('$OPENCLAW_AGENTS_ROOT'), days=None, config_path=Path('$WORK_CONFIG'))
# 1M * 0.00025 / 1M + 0.1M * 0.001 / 1M = 0.00025 + 0.0001 = 0.00035
print(agg['beta']['total']['cost_usd'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "0.00035" ]
}

@test "aggregate_by_agent_and_model: zero cost when model not in cost table" {
    _seed_trajectory "gamma" "33333333-3333-3333-3333-333333333333" \
'{"type":"model.completed","data":{"agentId":"gamma","usage":{"input":1000,"output":500}},"modelId":"unknown/provider-model","ts":"2026-06-13T10:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
agg = cost_monitor.aggregate_by_agent_and_model(Path('$OPENCLAW_AGENTS_ROOT'), days=None, config_path=Path('$WORK_CONFIG'))
print(agg['gamma']['total']['cost_usd'], agg['gamma']['total']['call_count'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "0.0 1" ]
}

@test "aggregate_by_agent_and_model: multiple sessions for the same agent sum" {
    _seed_trajectory "delta" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
'{"type":"model.completed","data":{"agentId":"delta","usage":{"input":100,"output":10}},"modelId":"minimax/minimax-m2.7","ts":"2026-06-13T10:00:00Z"}'
    _seed_trajectory "delta" "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" \
'{"type":"model.completed","data":{"agentId":"delta","usage":{"input":200,"output":20}},"modelId":"minimax/minimax-m2.7","ts":"2026-06-13T11:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
agg = cost_monitor.aggregate_by_agent_and_model(Path('$OPENCLAW_AGENTS_ROOT'), days=None, config_path=Path('$WORK_CONFIG'))
print(agg['delta']['total']['prompt_tokens'], agg['delta']['total']['call_count'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "300 2" ]
}

# ─── handle_cost_report_command ───────────────────────────────────────

@test "handle_cost_report_command: empty data returns informative message" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
print(cost_monitor.handle_cost_report_command(days=7, agents_root=Path('$OPENCLAW_AGENTS_ROOT'), config_path=Path('$WORK_CONFIG')))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cost Report"* ]]
    [[ "$output" == *"No model.completed events"* ]]
}

@test "handle_cost_report_command: surfaces active agents and per-model breakdown" {
    _seed_trajectory "alpha" "11111111-1111-1111-1111-111111111111" \
'{"type":"model.completed","data":{"agentId":"alpha","usage":{"input":1000,"output":100,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.001}}},"modelId":"anthropic/claude-sonnet-4.5","ts":"2026-06-13T10:00:00Z"}'
    _seed_trajectory "beta" "22222222-2222-2222-2222-222222222222" \
'{"type":"model.completed","data":{"agentId":"beta","usage":{"input":2000,"output":200,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.002}}},"modelId":"minimax/minimax-m2.7","ts":"2026-06-13T10:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
print(cost_monitor.handle_cost_report_command(days=7, agents_root=Path('$OPENCLAW_AGENTS_ROOT'), config_path=Path('$WORK_CONFIG')))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Active Agents"* ]]
    [[ "$output" == *": 2"* ]]
    [[ "$output" == *"Top Agents"* ]]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"By Model"* ]]
    [[ "$output" == *"claude-sonnet-4.5"* ]]
    [[ "$output" == *"minimax-m2.7"* ]]
}

# ─── aggregate_compaction_events ──────────────────────────────────────

@test "aggregate_compaction_events: empty data returns empty list" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
print(cost_monitor.aggregate_compaction_events(Path('$OPENCLAW_AGENTS_ROOT')))
"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "aggregate_compaction_events: extracts promptCache.lastCallUsage tokens" {
    _seed_trajectory "alpha" "11111111-1111-1111-1111-111111111111" \
'{"type":"context.compiled","data":{"agentId":"alpha","promptCache":{"lastCallUsage":{"input":8000,"output":1000,"cacheRead":500,"cacheWrite":0,"total":9500}}},"ts":"2026-06-13T10:00:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
events = cost_monitor.aggregate_compaction_events(Path('$OPENCLAW_AGENTS_ROOT'))
print(len(events), events[0]['agent_id'], events[0]['reserved_tokens'], events[0]['used_tokens'])
"
    [ "$status" -eq 0 ]
    [ "$output" = "1 alpha 9500 8000" ]
}

# ─── handle_context_health_command ─────────────────────────────────────

@test "handle_context_health_command: empty data returns informative message" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
print(cost_monitor.handle_context_health_command(agents_root=Path('$OPENCLAW_AGENTS_ROOT')))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Context Health"* ]]
    [[ "$output" == *"No context.compiled events"* ]]
}

@test "handle_context_health_command: high-ratio events surface a warning" {
    # Three compilations with > 80% reserved usage should trigger the
    # warning. The trigger threshold is > 3 events (so 4+ here).
    _seed_trajectory "alpha" "11111111-1111-1111-1111-111111111111" \
'{"type":"context.compiled","data":{"agentId":"alpha","promptCache":{"lastCallUsage":{"input":900,"output":0,"cacheRead":0,"cacheWrite":0,"total":1000}}},"ts":"2026-06-13T10:00:00Z"}
{"type":"context.compiled","data":{"agentId":"alpha","promptCache":{"lastCallUsage":{"input":950,"output":0,"cacheRead":0,"cacheWrite":0,"total":1000}}},"ts":"2026-06-13T10:01:00Z"}
{"type":"context.compiled","data":{"agentId":"alpha","promptCache":{"lastCallUsage":{"input":850,"output":0,"cacheRead":0,"cacheWrite":0,"total":1000}}},"ts":"2026-06-13T10:02:00Z"}
{"type":"context.compiled","data":{"agentId":"alpha","promptCache":{"lastCallUsage":{"input":900,"output":0,"cacheRead":0,"cacheWrite":0,"total":1000}}},"ts":"2026-06-13T10:03:00Z"}'
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
from pathlib import Path
print(cost_monitor.handle_context_health_command(agents_root=Path('$OPENCLAW_AGENTS_ROOT')))
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
    [[ "$output" == *"reserveTokens"* ]]
    [[ "$output" == *"alpha"* ]]
}

# ─── deprecation: keep init_db / log_api_call / log_compaction_event working ─

@test "init_db: deprecated no-op prints a deprecation warning" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
cost_monitor._DEPRECATION_WARNED = False
cost_monitor.init_db()
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEPRECATION"* ]]
    [[ "$output" == *"init_db"* ]]
}

@test "log_api_call: deprecated no-op prints a deprecation warning" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
cost_monitor._DEPRECATION_WARNED = False
cost_monitor.log_api_call('test', 1, 1, 0.001, 'run-1')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEPRECATION"* ]]
    [[ "$output" == *"log_api_call"* ]]
}

@test "log_compaction_event: deprecated no-op prints a deprecation warning" {
    run python3 -c "
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('cm', '$REPO_ROOT/scripts/cost-monitor.py')
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm); cost_monitor = cm
cost_monitor._DEPRECATION_WARNED = False
cost_monitor.log_compaction_event(1000, 500, 'run-1')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEPRECATION"* ]]
    [[ "$output" == *"log_compaction_event"* ]]
}

# ─── CLI ──────────────────────────────────────────────────────────────

@test "CLI: cost-report exits 0 with output" {
    _seed_trajectory "alpha" "11111111-1111-1111-1111-111111111111" \
'{"type":"model.completed","data":{"agentId":"alpha","usage":{"input":100,"output":10,"cost":{"total":0.001}}},"modelId":"minimax/minimax-m2.7","ts":"2026-06-13T10:00:00Z"}'
    run python3 "$SCRIPT" cost-report 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cost Report"* ]]
    [[ "$output" == *"alpha"* ]]
}

@test "CLI: log-call prints a deprecation message and exits 0" {
    run python3 "$SCRIPT" log-call model 1 1 0.001 run-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEPRECATION"* ]]
    [[ "$output" == *"log-call"* ]]
}

@test "CLI: log-compaction prints a deprecation message and exits 0" {
    run python3 "$SCRIPT" log-compaction 1000 500 run-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEPRECATION"* ]]
    [[ "$output" == *"log-compaction"* ]]
}

@test "CLI: no command prints usage and exits 1" {
    run python3 "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "CLI: unknown command prints error and exits 1" {
    run python3 "$SCRIPT" unknown-cmd
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]
}
