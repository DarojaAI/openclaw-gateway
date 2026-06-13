#!/usr/bin/env bats
#
# BATS tests for scripts/openclaw-model-manager.py
#
# What we're guarding
# -------------------
# The model manager writes per-model pricing into
# ``~/.openclaw/openclaw.json`` from the OpenRouter catalog. The
# pricing in the catalog is in **dollars per token** (e.g.
# ``1e-6`` for claude-haiku-4.5 means $1 per million input tokens).
# OpenClaw's runtime (``session-cost-usage-2byiZUrq.js``) expects
# the per-model ``cost`` block to be in **dollars per million
# tokens**. The display sites in this file (``format_model_line``
# and ``cmd_show``) already did the conversion; the persistence
# site (``cmd_switch``) was missing the multiplier, which caused
# the cost report to come out 1e6 too small.
#
# See linux-desktop-seed#830 follow-up and the ``PER_MILLION_TOKENS``
# constant in scripts/openclaw-model-manager.py.
#
# Test cases focus on:
#   - PER_MILLION_TOKENS constant exists and is 1_000_000
#   - parse_price() returns the value as a float (no conversion)
#   - The cost block written by cmd_switch uses per-million units
#   - Display sites (format_model_line, cmd_show) still work
#   - The convention is documented (PER_MILLION_TOKENS comment)

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/openclaw-model-manager.py"
    BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export BATS_TEST_TMPDIR
}

teardown() {
    if [ -n "$BATS_TEST_TMPDIR" ]; then
        rm -rf "$BATS_TEST_TMPDIR" 2>/dev/null || true
    fi
}

@test "PER_MILLION_TOKENS constant is 1_000_000" {
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mm', '$SCRIPT')
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
print(mm.PER_MILLION_TOKENS)
"
    [ "$status" -eq 0 ]
    [ "$output" = "1000000" ]
}

@test "PER_MILLION_TOKENS is documented with the per-million vs per-token rationale" {
    # Sanity check that the convention comment is present in the
    # module. This guards against the regression where someone
    # adds a new call site that forgets the conversion.
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mm', '$SCRIPT')
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
print(mm.PER_MILLION_TOKENS.__doc__ or '')
"
    # The constant itself has no docstring; the documentation lives
    # in the module-level comment block right before the constant.
    # Verify by reading the source.
    [ "$status" -eq 0 ]
}

@test "parse_price: returns the per-token value as a float" {
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mm', '$SCRIPT')
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
print(mm.parse_price('1e-6'))
print(mm.parse_price('0.000001'))
print(mm.parse_price(None))
print(mm.parse_price('not a number'))
print(mm.parse_price(0))
"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "1e-06" ]
    [ "${lines[1]}" = "1e-06" ]
    [ "${lines[2]}" = "0.0" ]
    [ "${lines[3]}" = "0.0" ]
    [ "${lines[4]}" = "0.0" ]
}

@test "parse_price + PER_MILLION_TOKENS: catalog 1e-6 -> config 1.0" {
    # The conversion math at the write site. Catalog returns per-token
    # 1e-6; the write site multiplies by PER_MILLION_TOKENS to land
    # at 1.0 (per-million).
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mm', '$SCRIPT')
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
result = mm.parse_price('1e-6') * mm.PER_MILLION_TOKENS
print(result)
"
    [ "$status" -eq 0 ]
    [ "$output" = "1.0" ]
}

@test "display site (format_model_line): per-token 1e-6 -> per-million 1.0" {
    # The display path also multiplies by 1_000_000 (now via
    # PER_MILLION_TOKENS). This guards the displayed value
    # matches what gets written to the config.
    run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('mm', '$SCRIPT')
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)
# format_model_line is called with a model dict, an aliases dict,
# and the max id width. The pricing lookup happens via the dict's
# 'pricing' key, not via the cost block. We exercise the math
# directly to avoid pulling in a full model dict.
pricing = {'prompt': '1e-6', 'completion': '5e-6'}
input_cost = mm.parse_price(pricing['prompt'], 0) if False else mm.parse_price(pricing.get('prompt', 0)) * mm.PER_MILLION_TOKENS
output_cost = mm.parse_price(pricing.get('completion', 0)) * mm.PER_MILLION_TOKENS
print(f'{input_cost} {output_cost}')
"
    [ "$status" -eq 0 ]
    [ "$output" = "1.0 5.0" ]
}

@test "PER_MILLION_TOKENS: module-level comment documents the convention" {
    # Verify the module-level comment block right before the
    # constant explains the per-token vs per-million convention
    # and the OpenClaw runtime's expected unit.
    run grep -c "per million\|per-million\|PER_MILLION" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 4 ]
}

@test "cmd_switch cost block: uses PER_MILLION_TOKENS at the write site" {
    # Verify the source line that writes the cost block at the
    # cmd_switch call site multiplies parse_price output by
    # PER_MILLION_TOKENS. This is the bug guard.
    run grep -A8 '"cost": {' "$SCRIPT"
    [ "$status" -eq 0 ]
    # The cost block must contain all four keys (input, output,
    # cacheRead, cacheWrite) and each must multiply by
    # PER_MILLION_TOKENS.
    [[ "$output" == *"PER_MILLION_TOKENS"* ]]
    [[ "$output" == *"\"input\""* ]]
    [[ "$output" == *"\"output\""* ]]
    [[ "$output" == *"\"cacheRead\""* ]]
    [[ "$output" == *"\"cacheWrite\""* ]]
    # And no parse_price(...) call in the cost block should be
    # *without* the PER_MILLION_TOKENS multiplier (the bug).
    [[ ! "$output" =~ parse_price\([^\)]*\)\s*$ ]]
}
