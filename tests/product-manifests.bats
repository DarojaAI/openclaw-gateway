#!/usr/bin/env bats
# Product manifests that linux-desktop-seed consumes as a pinned release.

setup() {
	REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	TMP_ROOT="$(mktemp -d)"
	mkdir -p "$TMP_ROOT/config"
	cp "$REPO_ROOT"/config/openclaw-*.json "$REPO_ROOT"/config/openclaw-version* "$TMP_ROOT/config/"
}

teardown() {
	rm -rf "$TMP_ROOT"
}

@test "the repository's product manifests validate" {
	run python3 "$REPO_ROOT/scripts/ci/validate-product-manifests.py" "$REPO_ROOT"
	[ "$status" -eq 0 ]
}

@test "a gateway_release without a digest fails" {
	python3 - "$TMP_ROOT/config/openclaw-plugins.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gateway_release"] = "9.9.9"
json.dump(d, open(p, "w"))
PY
	run python3 "$REPO_ROOT/scripts/ci/validate-product-manifests.py" "$TMP_ROOT"
	[ "$status" -eq 1 ]
	[[ "$output$stderr" == *"no digest"* ]]
}

@test "a retired id still listed as a plugin fails" {
	python3 - "$TMP_ROOT/config/openclaw-plugins.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["retired"] = ["discord"]
json.dump(d, open(p, "w"))
PY
	run python3 "$REPO_ROOT/scripts/ci/validate-product-manifests.py" "$TMP_ROOT"
	[ "$status" -eq 1 ]
}

@test "a malformed env pin fails" {
	echo "latest" > "$TMP_ROOT/config/openclaw-version.test"
	run python3 "$REPO_ROOT/scripts/ci/validate-product-manifests.py" "$TMP_ROOT"
	[ "$status" -eq 1 ]
}
