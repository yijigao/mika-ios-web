#!/usr/bin/env bash
# Run only on a disposable Codemagic simulator. No model or real site is used.
set -euo pipefail
EVIDENCE=build/gate-batch1-evidence
rm -rf "$EVIDENCE"
mkdir -p "$EVIDENCE"
SIM=""
CONTAINER=""
collect_evidence() {
  set +e
  if test -n "$CONTAINER"; then
    test ! -d "$CONTAINER/Documents/GateBatch1" || cp -R "$CONTAINER/Documents/GateBatch1/." "$EVIDENCE/"
    test ! -d "$CONTAINER/Library/Application Support/MikaWeb/Trace" || cp -R "$CONTAINER/Library/Application Support/MikaWeb/Trace" "$EVIDENCE/"
    test ! -d "$CONTAINER/Library/Application Support/MikaWeb/Diagnostics" || cp -R "$CONTAINER/Library/Application Support/MikaWeb/Diagnostics" "$EVIDENCE/"
    test ! -f "$CONTAINER/Library/Application Support/MikaWeb/verification-log.jsonl" || cp "$CONTAINER/Library/Application Support/MikaWeb/verification-log.jsonl" "$EVIDENCE/"
  fi
  set -e
}
cleanup() {
  status=$?
  trap - EXIT
  collect_evidence
  # Emit an explicit failed final JSON even on boot, launch or collection failure.
  python3 scripts/validate_gate_batch1_results.py "$EVIDENCE" --sha "$(git rev-parse HEAD)" || status=1
  test -z "$SIM" || xcrun simctl shutdown "$SIM" || true
  test -z "$SIM" || xcrun simctl delete "$SIM" || true
  exit "$status"
}
trap cleanup EXIT
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print(next(r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["name"]))')
DEVICE=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; print(next(d["identifier"] for d in json.load(sys.stdin)["devicetypes"] if "iPhone" in d["name"]))')
SIM=$(xcrun simctl create Mika-Gate-Batch1 "$DEVICE" "$RUNTIME")
xcrun simctl boot "$SIM"
xcrun simctl bootstatus "$SIM" -b
APP=build/GateBatch1/Build/Products/Debug-iphonesimulator/MikaWeb.app
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
SHA=$(git rev-parse HEAD)
APP_SHA=$(/usr/libexec/PlistBuddy -c 'Print MikaBuildSHA' "$APP/Info.plist")
test "$APP_SHA" = "$SHA"
xcrun simctl list -j > "$EVIDENCE/simulator-environment.json"
printf '%s\n' "$SHA" > "$EVIDENCE/build-sha.txt"
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$BUNDLE" --mika-gate-batch1-selftest > "$EVIDENCE/launch-first.log" 2>&1
CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
for attempt in $(seq 1 900); do
  test ! -f "$CONTAINER/Documents/GateBatch1/gate-batch1-preflight.json" || break
  sleep 1
done
collect_evidence
test -f "$EVIDENCE/gate-batch1-preflight.json"
# A real process boundary: do not merely instantiate a second AgentEngine.
xcrun simctl terminate "$SIM" "$BUNDLE"
xcrun simctl launch "$SIM" "$BUNDLE" --mika-gate-batch1-restart-check > "$EVIDENCE/launch-restart.log" 2>&1
for attempt in $(seq 1 180); do
  test ! -f "$CONTAINER/Documents/GateBatch1/gate-batch1-restart.json" || break
  sleep 1
done
collect_evidence
python3 scripts/validate_gate_batch1_results.py "$EVIDENCE" --sha "$SHA"
