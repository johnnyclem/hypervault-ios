#!/usr/bin/env python3
"""Prints the failures recorded in an .xcresult bundle: which test, and the sentence it failed with.

    summarize_xcresult.py <result.xcresult>

The UI tests fail with sentences that name what was missing ("Never saw the Paste button."), and the raw build log
only has them among thousands of lines; this reads them from the bundle. It never fails the build.
"""
import json
import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        return 0
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", sys.argv[1]],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print("xcresulttool could not summarise the bundle:", (result.stderr or result.stdout).strip()[:300])
        return 0
    try:
        summary = json.loads(result.stdout)
    except ValueError:
        print("xcresulttool printed something that is not JSON.")
        return 0

    print(
        "tests: {passed} passed, {failed} failed, {skipped} skipped".format(
            passed=summary.get("passedTests", "?"), failed=summary.get("failedTests", "?"), skipped=summary.get("skippedTests", "?")
        )
    )
    for failure in summary.get("testFailures", []):
        name = failure.get("testIdentifierString") or failure.get("testName") or "unknown test"
        text = " ".join(str(failure.get("failureText", "")).split())
        print(f"  FAILED {name}: {text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
