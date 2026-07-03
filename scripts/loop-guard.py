#!/usr/bin/env python3
"""Loop guard: check if an agent is allowed to respond to another agent.

Usage:
    loop-guard.py --source <agent-slug> --target <agent-slug>

Reads agents.lock.toml from config/ directory.
Default: agent should NOT respond (loop guard ON).
Per-agent override: loop_guard: false means agent CAN respond.

Output: JSON {"should_respond": true|false}
"""
import argparse
import json
import os
import sys


def load_lockfile(path: str) -> dict:
    """Load agents.lock.toml as a simple key-value parser."""
    try:
        with open(path) as f:
            return _parse_toml(f.read())
    except FileNotFoundError:
        return {}


def _parse_toml(content: str) -> dict:
    """Minimal TOML parser for agents.lock.toml structure.

    Handles [agents.<slug>] sections and key = "value" lines.
    Returns nested dict: agents -> slug -> {key: value}
    """
    result = {}
    current_section = None
    current_subsection = None

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue

        # Handle section headers like [agents.linux-desktop-seed]
        if line.startswith('[') and line.endswith(']'):
            section_name = line[1:-1].strip()
            parts = section_name.split('.')
            if len(parts) == 2:
                current_section = parts[0]
                current_subsection = parts[1]
                if current_section not in result:
                    result[current_section] = {}
                if current_subsection not in result[current_section]:
                    result[current_section][current_subsection] = {}
            else:
                current_section = section_name
                current_subsection = None
                if current_section not in result:
                    result[current_section] = {}
            continue

        # Handle key = "value" or key = true/false
        if '=' in line and current_section is not None:
            key, _, val = line.partition('=')
            key = key.strip()
            val = val.strip().strip('"')

            if val.lower() in ('true', 'false'):
                val = val.lower() == 'true'
            if current_subsection is not None:
                result[current_section][current_subsection][key] = val
            else:
                result[current_section][key] = val

    return result


def check_loop_guard(source: str, target: str, agents: dict) -> bool:
    """Check if target agent is allowed to respond to source agent.

    Returns True if target should respond, False otherwise.
    Default: False (loop guard ON).
    """
    agents_section = agents.get('agents', {})
    target_agent = agents_section.get(target, {})

    # If loop_guard is explicitly false, allow response
    if target_agent.get('loop_guard') is False:
        return True

    # Default: do not respond
    return False


def main():
    parser = argparse.ArgumentParser(description='Loop guard: check if agent should respond')
    parser.add_argument('--source', required=True, help='Source agent slug')
    parser.add_argument('--target', required=True, help='Target agent slug')
    parser.add_argument('--lockfile', default=None, help='Path to agents.lock.toml (default: config/agents.lock.toml)')
    args = parser.parse_args()

    # Find lockfile
    if args.lockfile:
        lockfile_path = args.lockfile
    else:
        # Try to find config/agents.lock.toml relative to script
        script_dir = os.path.dirname(os.path.abspath(__file__))
        lockfile_path = os.path.join(script_dir, '..', 'config', 'agents.lock.toml')

    agents = load_lockfile(lockfile_path)
    should_respond = check_loop_guard(args.source, args.target, agents)

    print(json.dumps({"should_respond": should_respond}))


if __name__ == '__main__':
    main()
