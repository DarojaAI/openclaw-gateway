#!/usr/bin/env python3
"""Inject actual secret values into OpenCLAW JSON config.

OpenCLAW does not reliably support ${VAR} env substitution in its JSON
config, so we write the real token/API key values directly after the
base config has been copied/merged.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: inject-config-secrets.py <config_file> [discord_token] [openrouter_api_key]", file=sys.stderr)
        return 1

    config_file = sys.argv[1]
    discord_token = sys.argv[2] if len(sys.argv) > 2 else ""
    openrouter_api_key = sys.argv[3] if len(sys.argv) > 3 else ""

    with open(config_file, "r") as f:
        config = json.load(f)

    updated = False

    if discord_token:
        if "channels" in config and "discord" in config["channels"]:
            old = config["channels"]["discord"].get("token", "")
            if old != discord_token:
                config["channels"]["discord"]["token"] = discord_token
                print("Updated Discord token")
                updated = True

    if openrouter_api_key:
        if "models" in config and "providers" in config["models"]:
            if "openrouter" in config["models"]["providers"]:
                old = config["models"]["providers"]["openrouter"].get("apiKey", "")
                if old != openrouter_api_key:
                    config["models"]["providers"]["openrouter"]["apiKey"] = openrouter_api_key
                    print("Updated OpenRouter API key")
                    updated = True

    if updated:
        with open(config_file, "w") as f:
            json.dump(config, f, indent=2)

    return 0


if __name__ == "__main__":
    sys.exit(main())
