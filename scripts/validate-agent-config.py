#!/usr/bin/env python3
# scripts/validate-agent-config.py
#
# Phase-1 validator for per-agent `.openclaw/agent-config.yaml` files.
# Validates a single document against `schemas/agent-config.schema.json`.
#
# Design notes
# ------------
# - Two validation paths:
#   * Full path: uses `jsonschema` + `yaml` if both are importable.
#   * Manual path: a stdlib-only subset JSON Schema validator and a
#     minimal YAML parser, covering exactly the constraints in
#     schemas/agent-config.schema.json. The manual path is the
#     load-bearing one for BATS suites that don't have jsonschema /
#     PyYAML installed in the test image.
# - Exit codes match the repo convention (see lib-parse-memory-status.py):
#   * 0 = document is valid.
#   * 1 = document is invalid (a field failed a constraint). The error
#         message names the field and the reason.
#   * 2 = probe failure (file missing, unreadable, or YAML/JSON
#         structurally broken before validation could even run).
#
# Refs:
#   DarojaAI/openclaw-gateway#31
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

DEFAULT_SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schemas" / "agent-config.schema.json"

# Schema-level constants (canonical, from rfc-31-shared-schema.md).
HANDLE_PATTERN = re.compile(r"^@[a-z0-9]([a-z0-9._-]*[a-z0-9])?$")
SLUG_PATTERN = re.compile(r"^[a-z][a-z0-9-]*$")
CHANNEL_PATTERN = re.compile(r"^#?[a-z0-9][a-z0-9_-]*$")
CONTRACT_VERSIONS = ("v1",)
ROLES = ("executor", "advisor")
HEARTBEAT_MIN_HOURS = 1
HEARTBEAT_MAX_HOURS = 168


def _resolve_schema_path(arg_value: str | None) -> Path:
    """Resolve the schema path from --schema or the default."""
    if arg_value:
        return Path(arg_value).expanduser().resolve()
    return DEFAULT_SCHEMA_PATH


def _read_document(path: Path) -> Any:
    """Read and parse a YAML or JSON document from disk.

    Tries PyYAML first, then a stdlib-only minimal YAML parser, then
    JSON as a last resort. Raises SystemExit(2) on probe failure
    (missing file, unreadable, unparseable).
    """
    if not path.exists():
        print(f"ERROR: document not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    if not path.is_file():
        print(f"ERROR: not a regular file: {path}", file=sys.stderr)
        raise SystemExit(2)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc

    # JSON path first: tolerant of leading whitespace and tabs. PyYAML
    # rejects tabs in YAML-mode indentation, so JSON-looking bodies
    # (the format we use in BATS) must hit the JSON parser.
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            print(f"ERROR: JSON parse error in {path}: {exc}", file=sys.stderr)
            raise SystemExit(2) from exc

    # YAML path: prefer PyYAML when available.
    try:
        import yaml  # type: ignore[import-not-found]
    except ImportError:
        yaml = None  # type: ignore[assignment]
    if yaml is not None:
        try:
            return yaml.safe_load(text)
        except yaml.YAMLError as exc:
            print(f"ERROR: YAML parse error in {path}: {exc}", file=sys.stderr)
            raise SystemExit(2) from exc

    # Manual YAML parser (stdlib only).
    try:
        return _parse_simple_yaml(text)
    except ValueError as exc:
        print(f"ERROR: cannot parse {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


def _parse_simple_yaml(text: str) -> Any:
    """A stdlib-only YAML subset parser sufficient for agent-config.yaml.

    Supports:
      - `key: value` mappings (strings, ints, floats, bools, null)
      - `key:` followed by indented children
      - `- item` list items (scalars or inline mappings)
      - `# comment` lines
      - Quoted strings (single or double)
    """
    # Strip comments and blank lines, keeping indentation.
    raw_lines = text.splitlines()
    lines: list[tuple[int, str]] = []
    for raw in raw_lines:
        # Remove trailing comments only when not inside quotes.
        stripped = _strip_comment(raw.rstrip())
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append((indent, stripped[indent:]))

    if not lines:
        return None

    pos, value = _parse_block(lines, 0, lines[0][0])
    return value


def _strip_comment(line: str) -> str:
    """Remove `# ...` comments outside of quoted strings."""
    in_single = False
    in_double = False
    for idx, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:idx].rstrip()
    return line


def _parse_block(lines: list[tuple[int, str]], start: int, indent: int) -> tuple[int, Any]:
    """Parse a block at the given indent level. Returns (next_pos, value)."""
    if start >= len(lines):
        return start, None
    first_indent, first_content = lines[start]
    if first_indent != indent:
        return start, None

    if first_content.startswith("- "):
        return _parse_list(lines, start, indent)
    return _parse_mapping(lines, start, indent)


def _parse_mapping(lines: list[tuple[int, str]], start: int, indent: int) -> tuple[int, dict[str, Any]]:
    result: dict[str, Any] = {}
    pos = start
    while pos < len(lines):
        cur_indent, cur_content = lines[pos]
        if cur_indent < indent:
            break
        if cur_indent > indent:
            # Shouldn't happen if input is well-formed.
            pos += 1
            continue
        if cur_content.startswith("- "):
            break
        if ":" not in cur_content:
            raise ValueError(f"invalid mapping line: {cur_content!r}")
        key, _, rest = cur_content.partition(":")
        key = key.strip()
        rest = rest.strip()
        pos += 1
        if rest == "":
            # Nested block (mapping or list) at greater indent.
            if pos < len(lines) and lines[pos][0] > indent:
                child_indent = lines[pos][0]
                _, value = _parse_block(lines, pos, child_indent)
                # Advance past the entire nested block.
                pos = _advance_to_dedent(lines, pos, indent)
                result[key] = value
            else:
                result[key] = None
        elif rest == "|" or rest == ">":
            # Literal / folded block scalar — not used by our schema.
            raise ValueError(f"block scalars are not supported: {key}")
        else:
            result[key] = _parse_scalar(rest)
    return pos, result


def _parse_list(lines: list[tuple[int, str]], start: int, indent: int) -> tuple[int, list[Any]]:
    result: list[Any] = []
    pos = start
    while pos < len(lines):
        cur_indent, cur_content = lines[pos]
        if cur_indent != indent or not cur_content.startswith("- "):
            break
        item_body = cur_content[2:]
        if item_body == "":
            # Dash on its own line; nested block follows.
            pos += 1
            if pos < len(lines) and lines[pos][0] > indent:
                child_indent = lines[pos][0]
                _, value = _parse_block(lines, pos, child_indent)
                pos = _advance_to_dedent(lines, pos, indent)
                result.append(value)
            else:
                result.append(None)
            continue
        if ":" in item_body and not (item_body.startswith('"') or item_body.startswith("'")):
            # Inline mapping: `- key: value`. Treat as a one-line mapping.
            key, _, rest = item_body.partition(":")
            inline = {key.strip(): _parse_scalar(rest.strip())}
            # If the next line is deeper indented, extend this mapping.
            if pos + 1 < len(lines) and lines[pos + 1][0] > indent and not lines[pos + 1][1].startswith("- "):
                nested_pos, nested = _parse_mapping(lines, pos + 1, lines[pos + 1][0])
                inline.update(nested)
                pos = nested_pos
            else:
                pos += 1
            result.append(inline)
        else:
            result.append(_parse_scalar(item_body))
            pos += 1
    return pos, result


def _advance_to_dedent(lines: list[tuple[int, str]], pos: int, target_indent: int) -> int:
    while pos < len(lines) and lines[pos][0] > target_indent:
        pos += 1
    return pos


def _parse_scalar(text: str) -> Any:
    """Parse a scalar value: quoted string, bool, int, float, null, or bare string."""
    text = text.strip()
    if text == "" or text == "~" or text.lower() == "null":
        return None
    if text.lower() == "true":
        return True
    if text.lower() == "false":
        return False
    if (text.startswith('"') and text.endswith('"')) or (
        text.startswith("'") and text.endswith("'")
    ):
        return text[1:-1]
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        pass
    return text


def _validate_with_jsonschema(doc: Any, schema: dict[str, Any]) -> list[str]:
    """Full validation path using jsonschema. Returns a list of error messages."""
    import jsonschema  # type: ignore[import-not-found]
    from jsonschema import Draft202012Validator  # type: ignore[import-not-found]

    errors: list[str] = []
    validator = Draft202012Validator(schema)
    for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path)):
        path = "/".join(str(x) for x in err.absolute_path) or "<root>"
        errors.append(f"{path}: {err.message}")
    return errors


def _validate_manual(doc: Any, schema: dict[str, Any]) -> list[str]:
    """Stdlib-only validator covering the constraints in the agent-config schema.

    Returns a list of error messages (empty list = valid).
    """
    errors: list[str] = []
    expected_type = schema.get("type")
    if expected_type and not _matches_type(doc, expected_type):
        errors.append(f"<root>: expected type {expected_type}, got {type(doc).__name__}")
        return errors

    if not isinstance(doc, dict):
        return errors

    if schema.get("additionalProperties") is False:
        allowed = set(schema.get("properties", {}).keys())
        for key in doc.keys():
            if key not in allowed:
                errors.append(f"{key}: additional property not allowed")

    for req in schema.get("required", []):
        if req not in doc:
            errors.append(f"{req}: required property is missing")

    properties = schema.get("properties", {})
    for key, value in doc.items():
        prop_schema = properties.get(key)
        if prop_schema is None:
            continue
        _validate_property(key, value, prop_schema, errors)

    return errors


def _matches_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    return True


def _validate_property(name: str, value: Any, schema: dict[str, Any], errors: list[str]) -> None:
    expected_type = schema.get("type")
    if expected_type:
        # Handle union types (e.g., ["string", "null"]) and single types.
        types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(_matches_type(value, t) for t in types):
            errors.append(f"{name}: expected type {'|'.join(types)}, got {type(value).__name__}")
            return

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{name}: value {value!r} not in enum {schema['enum']}")
    if "const" in schema and value != schema["const"]:
        errors.append(f"{name}: value {value!r} != const {schema['const']!r}")
    if "pattern" in schema and isinstance(value, str):
        if not re.search(schema["pattern"], value):
            errors.append(f"{name}: value {value!r} does not match pattern {schema['pattern']!r}")
    if "minimum" in schema or "maximum" in schema:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            minimum = schema.get("minimum")
            maximum = schema.get("maximum")
            if minimum is not None and value < minimum:
                errors.append(f"{name}: value {value} < minimum {minimum}")
            if maximum is not None and value > maximum:
                errors.append(f"{name}: value {value} > maximum {maximum}")
    if "minItems" in schema or "maxItems" in schema:
        if isinstance(value, list):
            minimum = schema.get("minItems")
            maximum = schema.get("maxItems")
            if minimum is not None and len(value) < minimum:
                errors.append(f"{name}: array length {len(value)} < minItems {minimum}")
            if maximum is not None and len(value) > maximum:
                errors.append(f"{name}: array length {len(value)} > maxItems {maximum}")
    if "uniqueItems" in schema and schema["uniqueItems"] and isinstance(value, list):
        seen: list[Any] = []
        for item in value:
            if item in seen:
                errors.append(f"{name}: duplicate item {item!r} (uniqueItems required)")
                break
            seen.append(item)

    if expected_type == "array" and isinstance(value, list) and "items" in schema:
        for idx, item in enumerate(value):
            _validate_property(f"{name}[{idx}]", item, schema["items"], errors)

    if expected_type == "object" and isinstance(value, dict):
        if schema.get("additionalProperties") is False:
            allowed = set(schema.get("properties", {}).keys())
            for k in value.keys():
                if k not in allowed:
                    errors.append(f"{name}.{k}: additional property not allowed")
        for req in schema.get("required", []):
            if req not in value:
                errors.append(f"{name}.{req}: required property is missing")
        sub_props = schema.get("properties", {})
        for k, v in value.items():
            sub_schema = sub_props.get(k)
            if sub_schema is not None:
                _validate_property(f"{name}.{k}", v, sub_schema, errors)


def _format_error(err: str) -> str:
    return f"INVALID: {err}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    parser.add_argument("document", help="Path to the agent-config.yaml file to validate")
    parser.add_argument(
        "--schema",
        default=None,
        help="Path to the JSON Schema (default: schemas/agent-config.schema.json next to this script)",
    )
    args = parser.parse_args()

    schema_path = _resolve_schema_path(args.schema)
    if not schema_path.exists():
        print(f"ERROR: schema not found: {schema_path}", file=sys.stderr)
        return 2
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot load schema {schema_path}: {exc}", file=sys.stderr)
        return 2

    doc_path = Path(args.document).expanduser().resolve()
    document = _read_document(doc_path)
    if not isinstance(document, dict):
        print(_format_error("<root>: document must be a mapping"), file=sys.stderr)
        return 1

    # Prefer jsonschema if importable; otherwise use the manual validator.
    try:
        import jsonschema  # noqa: F401  # type: ignore[import-not-found]
    except ImportError:
        errors = _validate_manual(document, schema)
    else:
        errors = _validate_with_jsonschema(document, schema)

    if errors:
        for err in errors:
            print(_format_error(err), file=sys.stderr)
        return 1

    print("VALID")
    return 0


if __name__ == "__main__":
    sys.exit(main())
