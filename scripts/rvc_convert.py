#!/usr/bin/env python3
"""
scripts/rvc_convert.py — REMOVED (legacy stub).

This script has been removed as part of the migration to XTTS2-only.
RVC voice conversion is no longer supported.

This project now uses XTTS2 for zero-shot voice cloning directly from
reference WAV files.  See 'voice refs/README.md' for instructions.

If you run this script, it will exit with a clear error message.
"""

from __future__ import annotations

import sys


def log(msg: str) -> None:
    print(f"[rvc_convert] {msg}", flush=True)


def main() -> None:
    log("ERROR: scripts/rvc_convert.py is no longer available.")
    log("  This project has migrated to XTTS2-only voice synthesis.")
    log("  RVC voice conversion has been removed.")
    log("")
    log("  New workflow — voice cloning with XTTS2:")
    log("    1. Place a reference WAV in the 'voice refs/' folder.")
    log("    2. Run synthesis:")
    log("         python scripts/synthesize.py \\")
    log("             --text 'Your text here.' \\")
    log("             --output out.wav \\")
    log("             --ref-wav 'voice refs/my_voice.wav'")
    log("")
    log("  See README.md and 'voice refs/README.md' for full instructions.")
    sys.exit(1)


if __name__ == "__main__":
    main()
