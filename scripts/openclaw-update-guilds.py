import json
import sys

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 openclaw-update-guilds.py <config_file> <guild_id> [channel_ids...]", file=sys.stderr)
        sys.exit(1)

    config_file = sys.argv[1]
    guild_id = sys.argv[2]
    channels = sys.argv[3:]

    with open(config_file, "r") as f:
        config = json.load(f)

    if "channels" not in config:
        config["channels"] = {}
    if "discord" not in config["channels"]:
        config["channels"]["discord"] = {}
    # Disable streaming to prevent tool-level chatter from being posted to Discord
    if "streaming" not in config["channels"]["discord"]:
        config["channels"]["discord"]["streaming"] = {}
    config["channels"]["discord"]["streaming"]["mode"] = "off"
    if "guilds" not in config["channels"]["discord"]:
        config["channels"]["discord"]["guilds"] = {}
    if guild_id not in config["channels"]["discord"]["guilds"]:
        config["channels"]["discord"]["guilds"][guild_id] = {}

    guild = config["channels"]["discord"]["guilds"][guild_id]
    if "channels" not in guild:
        guild["channels"] = {}
    if "requireMention" not in guild:
        guild["requireMention"] = False

    for ch_id in channels:
        guild["channels"][ch_id] = {"requireMention": False}

    with open(config_file, "w") as f:
        json.dump(config, f, indent=2)

    print(f"Added {len(channels)} channels to guild config")

if __name__ == "__main__":
    main()
