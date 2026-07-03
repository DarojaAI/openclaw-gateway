#!/usr/bin/env python3
# tests/test-merge-agents-lock.py
#
# Tests for scripts/ci/merge-agents-lock.py
#
# Validates that:
# 1. Single fragment is merged correctly
# 2. Multiple fragments are merged without collisions
# 3. Duplicate slug detection works
# 4. Missing fragments dir causes error
# 5. Empty fragments dir causes error
#
# Usage:
#   python3 tests/test-merge-agents-lock.py
#
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = str(Path(__file__).resolve().parent.parent / "scripts" / "ci" / "merge-agents-lock.py")


def run_merge(fragments_dir: str, output: str, expect_rc: int = 0) -> str:
    """Run merge-agents-lock.py and return stdout or raise on mismatch."""
    result = subprocess.run(
        [sys.executable, SCRIPT, "--fragments-dir", fragments_dir, "--output", output],
        capture_output=True,
        text=True,
    )
    if result.returncode != expect_rc:
        print(f"Expected exit code {expect_rc}, got {result.returncode}")
        print(f"STDOUT: {result.stdout}")
        print(f"STDERR: {result.stderr}")
        raise AssertionError(f"Exit code mismatch: expected {expect_rc}, got {result.returncode}")
    return result.stdout + result.stderr


def test_single_fragment():
    """Test merging a single fragment."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fragments_dir = Path(tmpdir) / "fragments"
        fragments_dir.mkdir()
        fragment = fragments_dir / "linux-desktop-seed.toml"
        fragment.write_text(
            '[agents.linux-desktop-seed]\n'
            'repo = "DarojaAI/linux-desktop-seed"\n'
            'handle = "@linux-desktop-seed"\n'
            'contract_version = "1"\n'
            'config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"\n'
            'config_sha = "abc1234567890abcdef1234567890abcdef123456"\n'
            'last_deploy_at = "2026-07-03T18:30:00Z"\n'
        )
        output = Path(tmpdir) / "agents.lock.toml"
        run_merge(str(fragments_dir), str(output))
        content = output.read_text()
        assert "[agents.linux-desktop-seed]" in content
        assert 'repo = "DarojaAI/linux-desktop-seed"' in content
        assert 'schema_version = "1"' in content
        print("PASS: test_single_fragment")


def test_multiple_fragments():
    """Test merging multiple fragments."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fragments_dir = Path(tmpdir) / "fragments"
        fragments_dir.mkdir()

        frag1 = fragments_dir / "linux-desktop-seed.toml"
        frag1.write_text(
            '[agents.linux-desktop-seed]\n'
            'repo = "DarojaAI/linux-desktop-seed"\n'
            'handle = "@linux-desktop-seed"\n'
            'contract_version = "1"\n'
            'config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"\n'
            'config_sha = "abc1234567890abcdef1234567890abcdef123456"\n'
            'last_deploy_at = "2026-07-03T18:30:00Z"\n'
        )

        frag2 = fragments_dir / "openclaw-agent.toml"
        frag2.write_text(
            '[agents.openclaw-agent]\n'
            'repo = "DarojaAI/openclaw-agent"\n'
            'handle = "@openclaw-agent"\n'
            'contract_version = "2"\n'
            'config_source = "https://github.com/DarojaAI/openclaw-agent/blob/main/.openclaw/agent-config.yaml"\n'
            'config_sha = "def1234567890abcdef1234567890abcdef123456"\n'
            'last_deploy_at = "2026-07-03T18:35:00Z"\n'
        )

        output = Path(tmpdir) / "agents.lock.toml"
        run_merge(str(fragments_dir), str(output))
        content = output.read_text()
        assert "[agents.linux-desktop-seed]" in content
        assert "[agents.openclaw-agent]" in content
        assert 'repo = "DarojaAI/linux-desktop-seed"' in content
        assert 'repo = "DarojaAI/openclaw-agent"' in content
        print("PASS: test_multiple_fragments")


def test_duplicate_slug():
    """Test that duplicate slugs cause an error."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fragments_dir = Path(tmpdir) / "fragments"
        fragments_dir.mkdir()

        frag1 = fragments_dir / "linux-desktop-seed-1.toml"
        frag1.write_text(
            '[agents.linux-desktop-seed]\n'
            'repo = "DarojaAI/linux-desktop-seed"\n'
            'handle = "@linux-desktop-seed"\n'
            'contract_version = "1"\n'
            'config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"\n'
            'config_sha = "abc1234567890abcdef1234567890abcdef123456"\n'
        )

        frag2 = fragments_dir / "linux-desktop-seed-2.toml"
        frag2.write_text(
            '[agents.linux-desktop-seed]\n'
            'repo = "DarojaAI/linux-desktop-seed"\n'
            'handle = "@linux-desktop-seed"\n'
            'contract_version = "2"\n'
            'config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"\n'
            'config_sha = "def1234567890abcdef1234567890abcdef123456"\n'
        )

        output = Path(tmpdir) / "agents.lock.toml"
        run_merge(str(fragments_dir), str(output), expect_rc=2)
        print("PASS: test_duplicate_slug")


def test_missing_dir():
    """Test that missing fragments directory causes error."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fragments_dir = Path(tmpdir) / "nonexistent"
        output = Path(tmpdir) / "agents.lock.toml"
        run_merge(str(fragments_dir), str(output), expect_rc=2)
        print("PASS: test_missing_dir")


def test_empty_dir():
    """Test that empty fragments directory causes error."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fragments_dir = Path(tmpdir) / "fragments"
        fragments_dir.mkdir()
        output = Path(tmpdir) / "agents.lock.toml"
        run_merge(str(fragments_dir), str(output), expect_rc=2)
        print("PASS: test_empty_dir")


def test_toml_format():
    """Test that output is valid TOML with correct fields."""
    with tempfile.TemporaryDirectory() as tmpdir:
        fragments_dir = Path(tmpdir) / "fragments"
        fragments_dir.mkdir()
        fragment = fragments_dir / "linux-desktop-seed.toml"
        fragment.write_text(
            '[agents.linux-desktop-seed]\n'
            'repo = "DarojaAI/linux-desktop-seed"\n'
            'handle = "@linux-desktop-seed"\n'
            'contract_version = "1"\n'
            'config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"\n'
            'config_sha = "abc1234567890abcdef1234567890abcdef123456"\n'
            'last_deploy_at = "2026-07-03T18:30:00Z"\n'
        )
        output = Path(tmpdir) / "agents.lock.toml"
        run_merge(str(fragments_dir), str(output))
        content = output.read_text()
        # Check schema_version
        assert 'schema_version = "1"' in content
        # Check required fields
        assert 'repo = "DarojaAI/linux-desktop-seed"' in content
        assert 'handle = "@linux-desktop-seed"' in content
        assert 'contract_version = "1"' in content
        assert 'config_source = "https://github.com/DarojaAI/linux-desktop-seed/blob/main/.openclaw/agent-config.yaml"' in content
        assert 'config_sha = "abc1234567890abcdef1234567890abcdef123456"' in content
        assert 'last_deploy_at = "2026-07-03T18:30:00Z"' in content
        print("PASS: test_toml_format")


if __name__ == "__main__":
    test_single_fragment()
    test_multiple_fragments()
    test_duplicate_slug()
    test_missing_dir()
    test_empty_dir()
    test_toml_format()
    print("\nAll tests passed!")
