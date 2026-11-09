#!/usr/bin/env python3
"""Combine two actual WK process results; fail closed on missing/weak evidence."""
import argparse
import json
import re
from pathlib import Path

CASE_IDS = (
    "normal_execution", "denial", "approval_expiry", "target_drift",
    "duplicate_request", "post_dispatch_disconnect", "crash_recovery", "log_failure", "post_validation_change",
    "rescan_relocation_swap", "pointer_sequence_swap",
    "model_driven_recovery", "model_driven_recovery_insufficient",
)

def missing_case(name, reason):
    return {"id": name, "passed": False, "status": "fail",
            "checks": [{"assertion": "runtime evidence must exist", "passed": False}],
            "evidence": {"error": reason}}

def combine(first, restart, sha):
    errors = []
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        errors.append("expected SHA must be a full commit ID")
    for name, result in (("preflight", first), ("restart", restart)):
        for key, expected in (("schemaVersion", 1), ("round", 1), ("runtime", "WKWebView"),
                              ("environment", "Codemagic iOS Simulator"), ("buildSHA", sha)):
            if result.get(key) != expected:
                errors.append(f"{name}: {key} mismatch")
        if result.get("passed") is not True:
            errors.append(f"{name}: suite did not pass")
    rows = first.get("cases", []) + restart.get("cases", [])
    if not isinstance(rows, list) or len(rows) != 13 or {r.get("id") for r in rows} != set(CASE_IDS):
        errors.append("require exactly thirteen unique named cases across both processes")
    for row in rows:
        name = row.get("id", "missing")
        if row.get("passed") is not True or row.get("status") != "pass":
            errors.append(f"{name}: failed")
        checks = row.get("checks")
        if not isinstance(checks, list) or not checks or any(
            c.get("passed") is not True or not c.get("assertion") for c in checks
        ):
            errors.append(f"{name}: missing or failed assertions")
        if not isinstance(row.get("evidence"), dict) or not row["evidence"]:
            errors.append(f"{name}: missing evidence")
    by_id = {row.get("id"): row for row in rows}
    expiry = by_id.get("approval_expiry", {}).get("evidence", {}).get("elapsedSeconds", 0)
    if not isinstance(expiry, (int, float)) or expiry < 60:
        errors.append("approval_expiry: must measure at least 60 real seconds")
    marker = first.get("crashCheckpoint", {})
    if marker.get("ready") is not True or marker.get("buildSHA") != sha:
        errors.append("crash checkpoint missing or wrong SHA")
    crash = by_id.get("crash_recovery", {}).get("evidence", {})
    if crash.get("processID") == marker.get("processID") or not crash.get("processID"):
        errors.append("crash recovery must run in a different App process")
    if crash.get("checkpoint") != marker:
        errors.append("restart did not consume the first process checkpoint")
    return {
        "schemaVersion": 1, "round": 1, "runtime": "WKWebView",
        "environment": "Codemagic iOS Simulator", "buildSHA": sha,
        "driver": "bundled controlled WK fixture; production gates; real App process restart",
        "passed": not errors, "validationErrors": errors,
        "cases": [next((r for r in rows if r.get("id") == name),
                       missing_case(name, "No runtime row collected")) for name in CASE_IDS],
        "sourceArtifacts": ["gate-batch1-preflight.json", "gate-batch1-restart.json"],
        "scope": "Controlled fixture evidence; does not replace real-site or real-device acceptance",
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    directory = args.directory
    try:
        first = json.loads((directory / "gate-batch1-preflight.json").read_text())
        restart = json.loads((directory / "gate-batch1-restart.json").read_text())
        result = combine(first, restart, args.sha)
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
        result = {"schemaVersion": 1, "round": 1, "runtime": "unavailable", "buildSHA": args.sha,
                  "passed": False, "validationErrors": [str(error)],
                  "cases": [missing_case(name, str(error)) for name in CASE_IDS]}
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "gate-batch1-result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"passed": result["passed"], "validationErrors": result["validationErrors"]}, ensure_ascii=False))
    return 0 if result["passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
