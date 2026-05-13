#!/usr/bin/env python3
"""
openclaw-model-manager.py
Unified CLI for OpenClaw model discovery, switching, and cost tracking.

Usage:
    openclaw-model-manager list [--provider <p>] [--free-only] [--sort <name|cost|context>]
    openclaw-model-manager switch <model_id_or_alias> [--agent <agent_id>]
    openclaw-model-manager info <model_id>
    openclaw-model-manager search <query>
    openclaw-model-manager current [--agent <agent_id>]
    openclaw-model-manager cost [--days <N>] [--model <model_id>]
    openclaw-model-manager context [--days <N>]

Installs to /usr/local/bin/openclaw-model-manager during deploy.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Colors
RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
NC = "\033[0m"

OPENROUTER_MODELS_API = "https://openrouter.ai/api/v1/models"
CACHE_PATH = Path.home() / ".cache" / "openrouter-models.json"
CACHE_TTL_SECONDS = 3600  # 1 hour
CONFIG_PATH = Path.home() / ".openclaw" / "openclaw.json"
COST_DB_PATH = Path.home() / ".openclaw" / "cost-log.db"


def log_info(msg: str):
    print(f"{BLUE}[INFO]{NC} {msg}")


def log_success(msg: str):
    print(f"{GREEN}[OK]{NC} {msg}")


def log_warn(msg: str):
    print(f"{YELLOW}[WARN]{NC} {msg}")


def log_error(msg: str):
    print(f"{RED}[ERROR]{NC} {msg}", file=sys.stderr)


def get_api_key() -> str:
    key = os.environ.get("OPENROUTER_API_KEY", "")
    if not key:
        log_error("OPENROUTER_API_KEY environment variable is not set")
        sys.exit(1)
    return key


def fetch_openrouter_models(force_refresh: bool = False) -> list:
    """Fetch full model catalog from OpenRouter, with local cache."""
    if not force_refresh and CACHE_PATH.exists():
        mtime = CACHE_PATH.stat().st_mtime
        if (time.time() - mtime) < CACHE_TTL_SECONDS:
            try:
                with open(CACHE_PATH, "r") as f:
                    return json.load(f)
            except (json.JSONDecodeError, OSError):
                pass  # Fall through to fetch

    api_key = get_api_key()
    log_info("Fetching model catalog from OpenRouter...")

    try:
        result = subprocess.run(
            [
                "curl",
                "-s",
                OPENROUTER_MODELS_API,
                "-H",
                f"Authorization: Bearer {api_key}",
                "--max-time",
                "30",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        log_error(f"Failed to fetch models from OpenRouter: {e}")
        sys.exit(1)
    except FileNotFoundError:
        log_error("curl not found - please install curl")
        sys.exit(1)

    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        log_error(f"Failed to parse OpenRouter response: {e}")
        sys.exit(1)

    if "error" in response:
        msg = response["error"].get("message", "Unknown error")
        log_error(f"OpenRouter API error: {msg}")
        sys.exit(1)

    models = response.get("data", [])
    if not models:
        log_error("OpenRouter returned empty model list")
        sys.exit(1)

    # Save cache
    try:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(CACHE_PATH, "w") as f:
            json.dump(models, f)
    except OSError as e:
        log_warn(f"Could not cache model list: {e}")

    log_success(f"Fetched {len(models)} models")
    return models


def load_config(config_path: Path = CONFIG_PATH) -> dict:
    """Load OpenClaw config, stripping comments for JSON5 compat."""
    content = config_path.read_text()

    try:
        return json.loads(content)
    except json.JSONDecodeError:
        pass

    # Strip single-line comments
    content_no_comments = re.sub(r"//.*?$", "", content, flags=re.MULTILINE)
    # Strip multi-line comments
    content_no_comments = re.sub(r"/\*.*?\*/", "", content_no_comments, flags=re.DOTALL)

    try:
        return json.loads(content_no_comments)
    except json.JSONDecodeError as e:
        log_error(f"Failed to parse config: {e}")
        sys.exit(1)


def save_config(config: dict, config_path: Path = CONFIG_PATH):
    """Save OpenClaw config with timestamped backup."""
    if config_path.exists():
        backup = config_path.parent / f"openclaw.json.backup-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(config_path, backup)

    output = json.dumps(config, indent=2)
    config_path.write_text(output + "\n")


def get_configured_aliases(config: dict) -> dict:
    """Return mapping of alias -> full model key from config."""
    aliases = {}
    agent_defaults = config.get("agents", {}).get("defaults", {})
    models_map = agent_defaults.get("models", {})
    for model_key, entry in models_map.items():
        alias = entry.get("alias", "")
        if alias:
            aliases[alias] = model_key
    return aliases


def get_configured_models(config: dict) -> list:
    """Return list of model IDs currently in config."""
    providers = config.get("models", {}).get("providers", {})
    openrouter = providers.get("openrouter", {})
    return [m.get("id", "") for m in openrouter.get("models", [])]


def resolve_model_id(target: str, config: dict) -> str:
    """Resolve an alias or partial ID to a full model ID."""
    aliases = get_configured_aliases(config)

    # Exact alias match
    if target in aliases:
        full_key = aliases[target]
        # full_key is like "openrouter/anthropic/claude-sonnet-4-5"
        # Return just the model part after openrouter/
        if full_key.startswith("openrouter/"):
            return full_key[11:]
        return full_key

    # Check if target is already a full model ID in config
    configured = get_configured_models(config)
    if target in configured:
        return target

    # Partial match against configured models
    matches = [m for m in configured if target.lower() in m.lower()]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        log_error(f"Ambiguous model '{target}'. Matches: {', '.join(matches)}")
        sys.exit(1)

    # Search OpenRouter catalog for partial match
    try:
        models = fetch_openrouter_models()
        catalog_matches = [m["id"] for m in models if target.lower() in m["id"].lower()]
        if len(catalog_matches) == 1:
            return catalog_matches[0]
        if len(catalog_matches) > 1:
            log_error(f"Ambiguous model '{target}' in catalog. Matches: {', '.join(catalog_matches)}")
            sys.exit(1)
    except SystemExit:
        pass  # fetch failed, continue to error

    log_error(f"Model '{target}' not found in config or OpenRouter catalog")
    sys.exit(1)


def parse_price(value) -> float:
    """Parse a pricing value from OpenRouter API."""
    if value is None:
        return 0.0
    try:
        return float(value)
    except (ValueError, TypeError):
        return 0.0


def is_free_model(model: dict) -> bool:
    """Check if a model is free (zero pricing)."""
    pricing = model.get("pricing", {})
    prompt = parse_price(pricing.get("prompt"))
    completion = parse_price(pricing.get("completion"))
    return prompt == 0.0 and completion == 0.0


def supports_reasoning(model: dict) -> bool:
    """Check if model supports reasoning tokens."""
    params = model.get("supported_parameters", [])
    if "reasoning" in params or "include_reasoning" in params:
        return True
    name = model.get("name", "").lower()
    keywords = ["reasoning", "r1", "o1", "o3", "deepseek-r"]
    return any(k in name for k in keywords)


def get_input_modalities(model: dict) -> list:
    """Return list of input modalities for a model."""
    modalities = model.get("architecture", {}).get("input_modalities", [])
    result = ["text"]
    if "image" in modalities:
        result.append("image")
    if "file" in modalities:
        result.append("file")
    return result


def format_model_line(model: dict, aliases: dict, max_id_width: int) -> str:
    """Format a single model for list output."""
    model_id = model.get("id", "")
    name = model.get("name", model_id)
    context = model.get("context_length", 0)

    pricing = model.get("pricing", {})
    input_cost = parse_price(pricing.get("prompt", 0)) * 1_000_000
    output_cost = parse_price(pricing.get("completion", 0)) * 1_000_000

    free = is_free_model(model)
    reasoning = supports_reasoning(model)

    # Build cost string
    if free:
        cost_str = f"{GREEN}free{NC}"
    else:
        cost_str = f"${input_cost:.3f}/${output_cost:.3f} per 1M"

    # Build badges
    badges = []
    if reasoning:
        badges.append("🧠")
    modalities = get_input_modalities(model)
    if "image" in modalities:
        badges.append("🖼️")
    if "file" in modalities:
        badges.append("📄")

    badge_str = " ".join(badges) if badges else ""

    # Find alias
    alias_str = ""
    for alias, full_key in aliases.items():
        if full_key == f"openrouter/{model_id}" or full_key == model_id:
            alias_str = f" {CYAN}[{alias}]{NC}"
            break

    # Format context in K
    context_str = f"{context // 1000}K" if context >= 1000 else str(context)

    return (
        f"  {CYAN}{model_id:<{max_id_width}}{NC}{alias_str}\n"
        f"     {name[:40]:<40} | Context: {context_str:>4} | {cost_str} {badge_str}"
    )


def cmd_list(args):
    """List available OpenRouter models."""
    models = fetch_openrouter_models(force_refresh=args.refresh)
    config = load_config()
    aliases = get_configured_aliases(config)

    # Filter
    if args.provider:
        models = [m for m in models if m.get("id", "").startswith(args.provider + "/")]
    if args.free_only:
        models = [m for m in models if is_free_model(m)]

    if not models:
        print("No models match your filters.")
        return

    # Sort
    sort_key = args.sort or "name"
    if sort_key == "cost":
        def cost_score(m):
            pricing = m.get("pricing", {})
            return parse_price(pricing.get("prompt", 0)) + parse_price(pricing.get("completion", 0))
        models.sort(key=cost_score)
    elif sort_key == "context":
        models.sort(key=lambda m: m.get("context_length", 0), reverse=True)
    else:
        models.sort(key=lambda m: m.get("name", m.get("id", "")).lower())

    # Calculate width for alignment
    max_id_len = max(len(m.get("id", "")) for m in models) if models else 0
    max_id_len = min(max_id_len, 40)

    # Header
    print(f"\n{GREEN}Available OpenRouter Models ({len(models)} total){NC}")
    if args.provider:
        print(f"  Filtered by provider: {args.provider}")
    if args.free_only:
        print(f"  {GREEN}Showing free models only{NC}")
    print(f"\n  {YELLOW}Configured aliases shown in [brackets]{NC}")
    print(f"  {YELLOW}🧠 = reasoning | 🖼️ = vision | 📄 = file upload{NC}\n")

    # Print models
    for model in models:
        print(format_model_line(model, aliases, max_id_len))

    print(f"\n{BLUE}Tip:{NC} Use 'openclaw-model-manager switch <alias_or_id>' to change models")


def cmd_switch(args):
    """Switch the default (or specified) agent's model."""
    target = args.model
    config = load_config()

    # Resolve to model ID
    model_id = resolve_model_id(target, config)
    full_model_key = f"openrouter/{model_id}"

    log_info(f"Resolved target to model: {CYAN}{model_id}{NC}")

    # Check if model is already in config
    providers = config.setdefault("models", {}).setdefault("providers", {})
    openrouter = providers.setdefault("openrouter", {"models": []})
    models_list = openrouter.setdefault("models", [])

    existing = None
    for m in models_list:
        if m.get("id") == model_id:
            existing = m
            break

    if not existing:
        log_info(f"Model {model_id} not in local config. Importing from OpenRouter...")
        # Fetch full model data and generate config
        models = fetch_openrouter_models()
        model_data = None
        for m in models:
            if m.get("id") == model_id:
                model_data = m
                break

        if not model_data:
            log_error(f"Could not find {model_id} in OpenRouter catalog")
            sys.exit(1)

        # Generate config entry (reusing logic from import-openrouter-model.py)
        context_length = model_data.get("context_length", 128000)
        max_tokens = min(context_length // 2, 32768)

        input_types = ["text"]
        modalities = model_data.get("architecture", {}).get("input_modalities", [])
        if "image" in modalities or "file" in modalities:
            input_types.append("image")
        if "file" in modalities:
            input_types.append("file")

        pricing = model_data.get("pricing", {})
        new_model_config = {
            "id": model_id,
            "name": model_data.get("name", model_id),
            "api": "openai-completions",
            "reasoning": supports_reasoning(model_data),
            "input": input_types,
            "cost": {
                "input": parse_price(pricing.get("prompt")),
                "output": parse_price(pricing.get("completion")),
                "cacheRead": parse_price(pricing.get("input_cache_read")),
                "cacheWrite": parse_price(pricing.get("input_cache_write")),
            },
            "contextWindow": context_length,
            "maxTokens": max_tokens,
        }

        models_list.append(new_model_config)
        models_list.sort(key=lambda x: x.get("id", ""))
        log_success(f"Added {model_id} to config")

    # Update default model
    agent_path = ["agents", "defaults"]
    if args.agent:
        # Per-agent override if the agent exists in config
        agent_list = config.get("agents", {}).get("list", [])
        if any(a.get("id") == args.agent for a in agent_list):
            agent_path = ["agents", "list"]
            # Find the specific agent entry -- this is more complex with OpenClaw's list format
            # For now, we only support default agent switching
            log_warn(f"Per-agent switching not yet fully supported; updating defaults")
        else:
            log_warn(f"Agent '{args.agent}' not found in config; updating defaults")

    defaults = config.setdefault("agents", {}).setdefault("defaults", {})
    old_model = defaults.get("model", "")
    defaults["model"] = full_model_key

    # Update metadata
    meta = config.setdefault("meta", {})
    meta["lastTouchedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    save_config(config)

    print()
    log_success(f"Switched default model: {old_model} → {CYAN}{full_model_key}{NC}")
    print()
    print(f"{YELLOW}Restart required to apply:{NC}")
    print(f"  systemctl --user restart openclaw-gateway.service")
    print()
    print(f"Or run: {CYAN}openclaw gateway restart{NC}")


def cmd_info(args):
    """Show detailed info about a specific model."""
    model_id = args.model
    config = load_config()

    # Try to resolve if it's an alias
    try:
        resolved = resolve_model_id(model_id, config)
        if resolved != model_id:
            model_id = resolved
    except SystemExit:
        pass  # Not in config, search catalog anyway

    models = fetch_openrouter_models()
    model_data = None
    for m in models:
        if m.get("id") == model_id:
            model_data = m
            break

    if not model_data:
        log_error(f"Model '{model_id}' not found in OpenRouter catalog")
        sys.exit(1)

    # Check if in local config
    configured_models = get_configured_models(config)
    in_config = model_id in configured_models

    aliases = get_configured_aliases(config)
    alias_names = [a for a, mk in aliases.items() if mk == f"openrouter/{model_id}" or mk == model_id]

    print(f"\n{GREEN}Model Info: {model_id}{NC}\n")

    print(f"  Name:        {model_data.get('name', 'N/A')}")
    print(f"  ID:          {model_id}")
    print(f"  In Config:   {'✅ Yes' if in_config else '❌ No'}")
    if alias_names:
        print(f"  Aliases:     {', '.join(alias_names)}")
    print(f"  Description: {model_data.get('description', 'N/A')[:100]}")

    context = model_data.get("context_length", 0)
    print(f"  Context:     {context:,} tokens ({context // 1000}K)")

    pricing = model_data.get("pricing", {})
    input_cost = parse_price(pricing.get("prompt", 0)) * 1_000_000
    output_cost = parse_price(pricing.get("completion", 0)) * 1_000_000
    print(f"  Pricing:     ${input_cost:.4f} / 1M input | ${output_cost:.4f} / 1M output")
    if is_free_model(model_data):
        print(f"  {GREEN}  FREE MODEL{NC}")

    print(f"  Reasoning:   {'✅ Yes' if supports_reasoning(model_data) else '❌ No'}")
    print(f"  Modalities:  {', '.join(get_input_modalities(model_data))}")

    # Show cost data if available
    if COST_DB_PATH.exists():
        import sqlite3
        conn = sqlite3.connect(COST_DB_PATH)
        cursor = conn.cursor()
        cutoff = (datetime.now() - timedelta(days=7)).isoformat()
        cursor.execute(
            """SELECT SUM(cost_usd), COUNT(*), SUM(prompt_tokens), SUM(completion_tokens)
               FROM api_calls WHERE model = ? AND timestamp >= ?""",
            (model_id, cutoff),
        )
        row = cursor.fetchone()
        conn.close()
        if row and row[0]:
            cost, calls, prompt, completion = row
            print(f"\n  {BLUE}Usage (last 7 days):{NC}")
            print(f"    Cost:   ${cost:.4f}")
            print(f"    Calls:  {calls}")
            print(f"    Tokens: {prompt:,} prompt / {completion:,} completion")

    print()
    if not in_config:
        print(f"{BLUE}To add this model:{NC}")
        print(f"  openclaw-model-manager switch {model_id}")


def cmd_search(args):
    """Search models by name or ID."""
    query = args.query.lower()
    models = fetch_openrouter_models()
    config = load_config()
    aliases = get_configured_aliases(config)

    matches = []
    for m in models:
        model_id = m.get("id", "").lower()
        name = m.get("name", "").lower()
        desc = m.get("description", "").lower()
        if query in model_id or query in name or query in desc:
            matches.append(m)

    if not matches:
        print(f"No models found matching '{args.query}'")
        return

    max_id_len = max(len(m.get("id", "")) for m in matches) if matches else 0
    max_id_len = min(max_id_len, 40)

    print(f"\n{GREEN}Search Results ({len(matches)} matches for '{args.query}'){NC}\n")
    for model in matches:
        print(format_model_line(model, aliases, max_id_len))
    print()


def cmd_current(args):
    """Show the currently configured default model."""
    config = load_config()
    defaults = config.get("agents", {}).get("defaults", {})
    current_model = defaults.get("model", "Not set")

    aliases = get_configured_aliases(config)
    reverse_aliases = {v: k for k, v in aliases.items()}
    alias = reverse_aliases.get(current_model, "")

    print(f"\n{GREEN}Current Default Model{NC}\n")
    print(f"  Model: {CYAN}{current_model}{NC}")
    if alias:
        print(f"  Alias: {CYAN}{alias}{NC}")

    # Show current model details from config
    model_id = current_model.replace("openrouter/", "")
    providers = config.get("models", {}).get("providers", {})
    openrouter = providers.get("openrouter", {})
    models_list = openrouter.get("models", [])
    for m in models_list:
        if m.get("id") == model_id:
            print(f"  Name:  {m.get('name', 'N/A')}")
            print(f"  Context: {m.get('contextWindow', 'N/A'):,}")
            print(f"  Reasoning: {'Yes' if m.get('reasoning') else 'No'}")
            break

    print()


def cmd_cost(args):
    """Show cost breakdown by model."""
    if not COST_DB_PATH.exists():
        print("No cost data available yet. Run some agent tasks first!")
        return

    import sqlite3
    from datetime import timedelta

    days = args.days or 7
    conn = sqlite3.connect(COST_DB_PATH)
    cursor = conn.cursor()

    cutoff = (datetime.now() - timedelta(days=days)).isoformat()

    if args.model:
        # Specific model cost
        cursor.execute(
            """SELECT SUM(cost_usd), COUNT(*), SUM(prompt_tokens), SUM(completion_tokens)
               FROM api_calls WHERE model = ? AND timestamp >= ?""",
            (args.model, cutoff),
        )
        row = cursor.fetchone()
        conn.close()
        if row and row[0]:
            cost, calls, prompt, completion = row
            print(f"\n{GREEN}Cost for {args.model} (last {days} days){NC}\n")
            print(f"  Total Cost:   ${cost:.4f}")
            print(f"  Calls:        {calls}")
            print(f"  Prompt Tokens: {prompt:,}")
            print(f"  Completion Tokens: {completion:,}")
            if calls > 0:
                avg = cost / calls
                print(f"  Avg per Call: ${avg:.4f}")
        else:
            print(f"No cost data for {args.model} in the last {days} days.")
        return

    # All models breakdown
    cursor.execute(
        """SELECT model, SUM(cost_usd), COUNT(*), SUM(prompt_tokens), SUM(completion_tokens)
           FROM api_calls WHERE timestamp >= ?
           GROUP BY model
           ORDER BY SUM(cost_usd) DESC""",
        (cutoff,),
    )
    rows = cursor.fetchall()
    conn.close()

    if not rows:
        print(f"No cost data in the last {days} days.")
        return

    print(f"\n{GREEN}Cost Breakdown by Model (last {days} days){NC}\n")

    max_cost = max(row[1] for row in rows) if rows else 1

    for model, cost, calls, prompt, completion in rows:
        model_short = model.split("/")[-1][:25]
        bar_width = int((cost / max_cost) * 20) if max_cost > 0 else 0
        bar = "█" * bar_width + "░" * (20 - bar_width)
        print(f"  {model_short:<25} {bar} ${cost:.4f} ({calls} calls)")

    total = sum(row[1] for row in rows)
    print(f"\n  {YELLOW}Total: ${total:.4f}{NC}")


def cmd_context(args):
    """Show context health / compaction stats."""
    if not COST_DB_PATH.exists():
        print("No context data available yet.")
        return

    import sqlite3
    from datetime import timedelta

    days = args.days or 7
    conn = sqlite3.connect(COST_DB_PATH)
    cursor = conn.cursor()

    cutoff = (datetime.now() - timedelta(days=days)).isoformat()

    cursor.execute(
        """SELECT reserved_tokens, used_tokens, ratio, timestamp
           FROM compaction_events WHERE timestamp >= ?
           ORDER BY timestamp DESC
           LIMIT 20""",
        (cutoff,),
    )
    rows = cursor.fetchall()
    conn.close()

    if not rows:
        print(f"No compaction data in the last {days} days.")
        return

    print(f"\n{GREEN}Context Health (last {days} days, last {len(rows)} compactions){NC}\n")

    high_count = sum(1 for _, _, ratio, _ in rows if ratio > 0.8)
    if high_count > 3:
        print(f"{YELLOW}⚠️ Warning: {high_count} runs had >80% reserve usage{NC}")
        print(f"   Consider lowering reserveTokens or raising maxHistoryShare\n")

    for reserved, used, ratio, timestamp in rows:
        bar_width = int(ratio * 20)
        bar = "█" * bar_width + "░" * (20 - bar_width)
        status = "🟢" if ratio < 0.8 else "🟡" if ratio < 0.9 else "🔴"
        ts = timestamp[:19] if timestamp else ""
        print(f"  {status} {bar} {ratio * 100:5.1f}% ({used:>6}/{reserved:<6}) {ts}")

    print()


def main():
    parser = argparse.ArgumentParser(
        description="OpenClaw Model Manager -- discover, switch, and track models.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  openclaw-model-manager list --free-only --sort cost
  openclaw-model-manager switch burns
  openclaw-model-manager switch anthropic/claude-sonnet-4-5
  openclaw-model-manager search "claude"
  openclaw-model-manager info minimax/MiniMax-M2.7
  openclaw-model-manager cost --days 1
  openclaw-model-manager cost --model minimax/MiniMax-M2.7
        """,
    )
    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # list
    list_parser = subparsers.add_parser("list", help="List available OpenRouter models")
    list_parser.add_argument("--provider", help="Filter by provider (e.g., 'anthropic', 'openai')")
    list_parser.add_argument("--free-only", action="store_true", help="Show only free models")
    list_parser.add_argument(
        "--sort",
        choices=["name", "cost", "context"],
        default="name",
        help="Sort order",
    )
    list_parser.add_argument("--refresh", action="store_true", help="Force refresh from API")

    # switch
    switch_parser = subparsers.add_parser("switch", help="Switch to a model")
    switch_parser.add_argument("model", help="Model alias or ID to switch to")
    switch_parser.add_argument("--agent", help="Target agent (default: global default)")

    # info
    info_parser = subparsers.add_parser("info", help="Show detailed model info")
    info_parser.add_argument("model", help="Model alias or ID")

    # search
    search_parser = subparsers.add_parser("search", help="Search models by name/ID")
    search_parser.add_argument("query", help="Search query")

    # current
    current_parser = subparsers.add_parser("current", help="Show current default model")
    current_parser.add_argument("--agent", help="Check specific agent")

    # cost
    cost_parser = subparsers.add_parser("cost", help="Show cost breakdown")
    cost_parser.add_argument("--days", type=int, help="Number of days to look back")
    cost_parser.add_argument("--model", help="Filter by specific model")

    # context
    context_parser = subparsers.add_parser("context", help="Show context health")
    context_parser.add_argument("--days", type=int, help="Number of days to look back")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Route to handler
    handlers = {
        "list": cmd_list,
        "switch": cmd_switch,
        "info": cmd_info,
        "search": cmd_search,
        "current": cmd_current,
        "cost": cmd_cost,
        "context": cmd_context,
    }

    handler = handlers.get(args.command)
    if not handler:
        log_error(f"Unknown command: {args.command}")
        sys.exit(1)

    handler(args)


if __name__ == "__main__":
    main()
