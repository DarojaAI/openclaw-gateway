#!/usr/bin/env python3
"""
OpenRouter Model Import Script for OpenClaw

Fetches model metadata from the OpenRouter API and updates the local
OpenClaw configuration file (openclaw-defaults.json) with correct
context window, max tokens, pricing, and input modalities.

Usage:
    python3 scripts/openclaw-import-model.py --model-id tencent/hy3-preview:free --alias frida --force
    python3 scripts/openclaw-import-model.py --model-id google/gemini-2.5-pro --alias gemini --set-default --dry-run

Exit codes:
    0 - Success
    1 - Error (model not found, config invalid, write failed, etc.)
"""

import argparse
import json
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError

OPENROUTER_MODELS_API = "https://openrouter.ai/api/v1/models"
DEFAULT_CONFIG_PATH = Path("config/openclaw-defaults.json")

# Heuristic keywords for detecting reasoning models
REASONING_KEYWORDS = ["reasoning", "r1", "o1", "o3", "deepseek-r"]


def fetch_openrouter_models():
    """Fetch the full model list from OpenRouter's public API."""
    try:
        req = Request(OPENROUTER_MODELS_API, headers={"User-Agent": "OpenClaw-Model-Importer/1.0"})
        with urlopen(req, timeout=30) as response:
            data = json.loads(response.read().decode("utf-8"))
            # The API returns {"data": [...]} or just [...] depending on version
            if isinstance(data, dict) and "data" in data:
                return data["data"]
            if isinstance(data, list):
                return data
            raise RuntimeError(f"Unexpected API response structure: {type(data)}")
    except URLError as e:
        raise RuntimeError(f"Failed to fetch OpenRouter models: {e}") from e
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Invalid JSON from OpenRouter API: {e}") from e
    raise RuntimeError("Failed to fetch OpenRouter models")


def find_model(models, model_id):
    """Find a model by its ID in the OpenRouter model list."""
    for model in models:
        if model.get("id") == model_id:
            return model
    return None


def map_openrouter_to_openclaw(openrouter_model):
    """Map an OpenRouter model object to an OpenClaw model config object."""
    modality = openrouter_model.get("architecture", {}).get("modality", "text->text")
    inputs = []
    if "text" in modality:
        inputs.append("text")
    if "image" in modality:
        inputs.append("image")

    pricing = openrouter_model.get("pricing", {})
    cost = {
        "input": float(pricing.get("prompt", 0) or 0),
        "output": float(pricing.get("completion", 0) or 0),
        "cacheRead": float(pricing.get("prompt", 0) or 0),
        "cacheWrite": float(pricing.get("prompt", 0) or 0),
    }

    name = openrouter_model.get("name", openrouter_model["id"])
    reasoning = any(kw in name.lower() for kw in REASONING_KEYWORDS)

    return {
        "id": openrouter_model["id"],
        "name": name,
        "api": "openai-completions",
        "contextWindow": openrouter_model.get("context_length", 128000),
        "maxTokens": openrouter_model.get("max_completion_tokens", 4096),
        "input": inputs,
        "cost": cost,
        "reasoning": reasoning,
    }


def load_config(config_path):
    """Load and return the OpenClaw config JSON."""
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"Error: Config file not found: {config_path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in config file: {e}", file=sys.stderr)
        sys.exit(1)


def save_config(config_path, config):
    """Write the OpenClaw config JSON back to disk."""
    try:
        with open(config_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
            f.write("\n")
    except OSError as e:
        print(f"Error: Failed to write config file: {e}", file=sys.stderr)
        sys.exit(1)


def get_openrouter_models_list(config):
    """Return the models array under models.providers.openrouter.models."""
    try:
        return config["models"]["providers"]["openrouter"]["models"]
    except KeyError as e:
        print(f"Error: Config missing expected key path models.providers.openrouter.models: {e}", file=sys.stderr)
        sys.exit(1)


def find_model_index(models_list, model_id):
    """Return the index of a model with the given ID, or None."""
    for idx, model in enumerate(models_list):
        if model.get("id") == model_id:
            return idx
    return None


def print_diff(old_model, new_model):
    """Print a human-readable diff between two model config objects."""
    all_keys = set(old_model.keys()) | set(new_model.keys())
    for key in sorted(all_keys):
        old_val = old_model.get(key, "<missing>")
        new_val = new_model.get(key, "<missing>")
        if old_val != new_val:
            print(f"  {key}: {old_val} -> {new_val}")


def main():
    parser = argparse.ArgumentParser(
        description="Import an OpenRouter model into the OpenClaw configuration."
    )
    parser.add_argument(
        "--model-id",
        required=True,
        help="OpenRouter model ID, e.g. tencent/hy3-preview:free",
    )
    parser.add_argument(
        "--alias",
        default=None,
        help="Alias name for the model in agents.defaults.models (optional)",
    )
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG_PATH),
        help=f"Path to openclaw-defaults.json (default: {DEFAULT_CONFIG_PATH})",
    )
    parser.add_argument(
        "--set-default",
        action="store_true",
        help="Set this model as the default model in agents.defaults.model",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would change without writing to the config file",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing model entry if the ID already exists",
    )

    args = parser.parse_args()
    config_path = Path(args.config)

    # Fetch model data from OpenRouter
    print(f"Fetching model list from {OPENROUTER_MODELS_API} ...")
    all_models = fetch_openrouter_models()
    openrouter_model = find_model(all_models, args.model_id)

    if openrouter_model is None:
        print(f"Error: Model '{args.model_id}' not found in OpenRouter API.", file=sys.stderr)
        print(f"       Available models: {len(all_models)}", file=sys.stderr)
        print(f"       Tip: Check the exact ID at https://openrouter.ai/{args.model_id}", file=sys.stderr)
        sys.exit(1)

    new_model_config = map_openrouter_to_openclaw(openrouter_model)
    print(f"Found model: {new_model_config['name']}")
    print(f"  contextWindow: {new_model_config['contextWindow']}")
    print(f"  maxTokens: {new_model_config['maxTokens']}")
    print(f"  input: {new_model_config['input']}")
    print(f"  reasoning: {new_model_config['reasoning']}")

    # Load local config
    config = load_config(config_path)
    models_list = get_openrouter_models_list(config)

    existing_idx = find_model_index(models_list, args.model_id)
    existing_model = models_list[existing_idx] if existing_idx is not None else None

    if existing_model is not None and not args.force and not args.dry_run:
        print(f"\nError: Model '{args.model_id}' already exists in config.", file=sys.stderr)
        print("Differences between existing and fetched config:", file=sys.stderr)
        print_diff(existing_model, new_model_config)
        print("\nUse --force to overwrite, or --dry-run to preview.", file=sys.stderr)
        sys.exit(1)

    # Determine what changes will be made
    changes = []

    if existing_model is not None:
        changes.append(f"Update model '{args.model_id}' in models.providers.openrouter.models")
    else:
        changes.append(f"Add model '{args.model_id}' to models.providers.openrouter.models")

    if args.alias:
        alias_key = f"openrouter/{args.model_id}"
        agent_models = config.setdefault("agents", {}).setdefault("defaults", {}).setdefault("models", {})
        if alias_key in agent_models:
            if agent_models[alias_key].get("alias") != args.alias:
                changes.append(f"Update alias for '{alias_key}' to '{args.alias}'")
        else:
            changes.append(f"Add alias '{args.alias}' -> '{alias_key}' in agents.defaults.models")

    if args.set_default:
        default_model_key = f"openrouter/{args.model_id}"
        current_default = config.get("agents", {}).get("defaults", {}).get("model", "")
        if current_default != default_model_key:
            changes.append(f"Set default model to '{default_model_key}'")

    if not changes:
        print("\nNo changes needed. Config is already up to date.")
        sys.exit(0)

    print("\nPlanned changes:")
    for change in changes:
        print(f"  - {change}")

    if args.dry_run:
        print("\n(Dry run - no changes written)")
        sys.exit(0)

    # Apply changes
    if existing_model is not None:
        models_list[existing_idx] = new_model_config
    else:
        models_list.append(new_model_config)

    if args.alias:
        alias_key = f"openrouter/{args.model_id}"
        agent_models = config.setdefault("agents", {}).setdefault("defaults", {}).setdefault("models", {})
        agent_models[alias_key] = {"alias": args.alias}

    if args.set_default:
        default_model_key = f"openrouter/{args.model_id}"
        config.setdefault("agents", {}).setdefault("defaults", {})["model"] = default_model_key

    # Update metadata timestamp
    if "meta" not in config:
        config["meta"] = {}
    from datetime import datetime, timezone
    config["meta"]["lastTouchedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    save_config(config_path, config)
    print(f"\nConfig updated: {config_path}")
    print("Done.")


if __name__ == "__main__":
    main()
