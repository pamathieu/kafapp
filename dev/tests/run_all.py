#!/usr/bin/env python3
"""
Run all KAFA integration test cases.

Usage (run from anywhere — venv is located automatically):
    python3 dev/tests/run_all.py

Each test case cleans up its own data. Tests run sequentially so DynamoDB
writes from one test don't interfere with the next.
"""

# Re-exec with the project venv if dependencies aren't available.
import sys, os
from pathlib import Path
_venv_py = Path(__file__).resolve().parents[2] / "dev" / "venv" / "bin" / "python3"
if _venv_py.exists() and Path(sys.executable).resolve() != _venv_py.resolve():
    os.execv(str(_venv_py), [str(_venv_py)] + sys.argv)

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import tc001_admin_adds_member as tc001
import tc002_prospect_to_member as tc002


def main() -> None:
    results: dict[str, int] = {}

    print("\n" + "=" * 60)
    print("  KAFA Integration Test Suite")
    print("=" * 60)

    for name, module in [("TC-001", tc001), ("TC-002", tc002)]:
        try:
            code = module.run()
        except SystemExit as e:
            code = int(e.code) if e.code is not None else 1
        except Exception as e:
            print(f"\n  {name} crashed: {e}")
            code = 1
        finally:
            try:
                module._teardown()
            except Exception:
                pass
        results[name] = code
        time.sleep(1)

    print("\n" + "=" * 60)
    print("  Suite Results")
    print("=" * 60)
    for name, code in results.items():
        status = "PASS ✓" if code == 0 else "FAIL ✗"
        print(f"  {name}: {status}")
    print("=" * 60)

    sys.exit(1 if any(c != 0 for c in results.values()) else 0)


if __name__ == "__main__":
    main()
