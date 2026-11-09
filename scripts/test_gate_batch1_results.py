"""Result validator tests use synthetic JSON only, never count as WK evidence."""
import copy
import unittest
from validate_gate_batch1_results import CASE_IDS, combine

SHA = "a" * 40

def inputs():
    def envelope(rows):
        return {"schemaVersion": 1, "round": 1, "runtime": "WKWebView",
                "environment": "Codemagic iOS Simulator", "buildSHA": SHA,
                "passed": True, "cases": rows}
    def row(name):
        return {"id": name, "passed": True, "status": "pass",
                "checks": [{"assertion": "synthetic validator input", "passed": True}],
                "evidence": {"synthetic": True}}
    first = envelope([row(name) for name in CASE_IDS if name != "crash_recovery"])
    first["cases"][2]["evidence"]["elapsedSeconds"] = 61
    marker = {"ready": True, "buildSHA": SHA, "processID": 100}
    first["crashCheckpoint"] = marker
    restart = envelope([row("crash_recovery")])
    restart["cases"][0]["evidence"] = {"processID": 101, "checkpoint": copy.deepcopy(marker)}
    return first, restart

class GateResultValidation(unittest.TestCase):
    def test_complete_schema(self):
        first, restart = inputs()
        self.assertTrue(combine(first, restart, SHA)["passed"])

    def test_wrong_build_sha(self):
        first, restart = inputs()
        restart["buildSHA"] = "b" * 40
        self.assertFalse(combine(first, restart, SHA)["passed"])

    def test_missing_and_duplicate_case(self):
        first, restart = inputs()
        first["cases"][1] = copy.deepcopy(first["cases"][0])
        self.assertFalse(combine(first, restart, SHA)["passed"])

    def test_shortened_approval_window(self):
        first, restart = inputs()
        first["cases"][2]["evidence"]["elapsedSeconds"] = 59.99
        self.assertFalse(combine(first, restart, SHA)["passed"])

    def test_same_process_is_not_restart(self):
        first, restart = inputs()
        restart["cases"][0]["evidence"]["processID"] = 100
        self.assertFalse(combine(first, restart, SHA)["passed"])

    def test_false_assertion_cannot_be_overruled_by_summary(self):
        first, restart = inputs()
        first["cases"][0]["checks"][0]["passed"] = False
        self.assertFalse(combine(first, restart, SHA)["passed"])

    def test_no_evidence_cannot_pass(self):
        first, restart = inputs()
        first["cases"][0]["evidence"] = {}
        self.assertFalse(combine(first, restart, SHA)["passed"])

    def test_restart_checkpoint_must_match(self):
        first, restart = inputs()
        restart["cases"][0]["evidence"]["checkpoint"]["buildSHA"] = "b" * 40
        self.assertFalse(combine(first, restart, SHA)["passed"])

    def test_missing_runtime_row_emits_explicit_failure(self):
        first, restart = inputs()
        first["cases"].pop(0)
        result = combine(first, restart, SHA)
        self.assertFalse(result["passed"])
        self.assertEqual(len(result["cases"]), 8)
        self.assertEqual(result["cases"][0]["status"], "fail")

if __name__ == "__main__":
    unittest.main()
