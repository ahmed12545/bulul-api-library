#!/usr/bin/env python3
"""
scripts/rvc_convert.py — REMOVED (legacy stub).

RVC voice conversion has been removed from this project.
XTTS2 has also been removed.

This project now uses StyleTTS2 for voice synthesis and cloning.
See 'voice refs/README.md' and README.md for instructions.

If you run this script, it will exit with a clear error message.
"""

from __future__ import annotations

import sys


def log(msg: str) -> None:
    print(f"[rvc_convert] {msg}", flush=True)


def main() -> None:
    log("ERROR: scripts/rvc_convert.py is no longer available.")
    log("  RVC voice conversion has been removed from this project.")
    log("  XTTS2 has also been removed by user request.")
    log("")
    log("  This project now uses StyleTTS2 for voice synthesis.")
    log("")
    log("  New workflow — voice synthesis/cloning with StyleTTS2:")
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
