#!/usr/bin/env python3
"""
scripts/synthesize.py — XTTS2 text-to-speech inference helper with voice cloning.

Usage:
    python -u scripts/synthesize.py \\
        --text "Hello world." \\
        --output out.wav \\
        --ref-wav "voice refs/my_voice.wav"

Place reference WAVs in the 'voice refs/' folder at the repo root.
If --ref-wav is omitted, the first .wav found in 'voice refs/' is used.

All print statements use flush=True for Kaggle-friendly unbuffered output
(avoids apparent hangs in notebook cells).

NOTE: This project is XTTS2-only.  StyleTTS2 and RVC have been removed.
      Legacy flags (--ckpt, --ckpt-name, --voice-model, --voice-index,
      --no-rvc) are no longer accepted and will produce a clear error.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

# ── Headless / Kaggle compatibility defaults ──────────────────────────────────
_mpl = os.environ.get("MPLBACKEND", "")
if not _mpl or _mpl.startswith("module://"):
    os.environ["MPLBACKEND"] = "Agg"

# ── Legacy flag detection (fail fast with a helpful message) ──────────────────
_LEGACY_FLAGS = {
    "--ckpt", "--ckpt-name", "--config",
    "--voice-model", "--voice-index", "--no-rvc",
    "--diffusion-steps", "--embedding-scale",
}


def log(msg: str) -> None:
    print(f"[synthesize] {msg}", flush=True)


def _check_legacy_flags() -> None:
    for raw in sys.argv[1:]:
        name = raw.split("=")[0]
        if name in _LEGACY_FLAGS:
            log(f"ERROR: Legacy flag '{name}' is not supported.")
            log("  This project is XTTS2-only. StyleTTS2 and RVC have been removed.")
            log("  New usage:")
            log("    python scripts/synthesize.py \\")
            log("        --text  'Your text here.' \\")
            log("        --output out.wav \\")
            log("        --ref-wav 'voice refs/my_voice.wav'")
            log("  Place reference WAVs in the 'voice refs/' folder.")
            sys.exit(1)


def _find_default_ref_wav(voice_refs_dir: Path) -> Path | None:
    """Return the first .wav in 'voice refs/' sorted by name, or None."""
    wavs = sorted(voice_refs_dir.glob("*.wav"))
    return wavs[0] if wavs else None


def main() -> None:
    _check_legacy_flags()

    parser = argparse.ArgumentParser(
        description="XTTS2 inference helper — voice cloning from reference WAV"
    )
    parser.add_argument("--text", required=True, help="Text to synthesize")
    parser.add_argument("--output", required=True, help="Output .wav path")
    parser.add_argument(
        "--ref-wav",
        default=None,
        metavar="PATH",
        help=(
            "Reference WAV file for voice cloning (3–30 s of clean speech). "
            "If omitted, the first .wav found in 'voice refs/' is used. "
            "Place reference files in the 'voice refs/' folder."
        ),
    )
    parser.add_argument(
        "--language",
        default="en",
        help=(
            "Language code for synthesis (default: en). "
            "Supported: en, ar, fr, de, es, pt, pl, tr, ru, nl, cs, it, zh-cn, …"
        ),
    )
    parser.add_argument(
        "--cpu",
        action="store_true",
        default=False,
        help="Force CPU inference even when a GPU is available (default: auto-select GPU)",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).parent.parent
    voice_refs_dir = repo_root / "voice refs"
    out_path = Path(args.output)

    log(f"Output   : {out_path}")
    log(f"Language : {args.language}")

    # ── Resolve reference WAV ─────────────────────────────────────────────────
    if args.ref_wav:
        ref_wav = Path(args.ref_wav)
    else:
        ref_wav = _find_default_ref_wav(voice_refs_dir)
        if ref_wav:
            log(f"Ref WAV  : {ref_wav} (auto-detected from 'voice refs/')")
        else:
            log("Ref WAV  : (none found in 'voice refs/' — using XTTS2 built-in speaker)")

    if ref_wav and not ref_wav.exists():
        log(f"ERROR: Reference WAV not found: {ref_wav}")
        log("  Place .wav reference files in the 'voice refs/' folder.")
        log("  See 'voice refs/README.md' for guidance.")
        sys.exit(1)

    # ── Device selection ──────────────────────────────────────────────────────
    log("Importing torch…")
    import torch  # noqa: F401

    if args.cpu:
        device = "cpu"
        log("Device   : cpu (--cpu flag set; GPU bypassed)")
    elif torch.cuda.is_available():
        device = "cuda"
        log(f"Device   : cuda (GPU: {torch.cuda.get_device_name(0)})")
    else:
        device = "cpu"
        log("Device   : cpu (no CUDA-capable GPU detected)")

    # ── Load XTTS2 model ──────────────────────────────────────────────────────
    log("Loading XTTS2 model (first run downloads ~2 GB from HuggingFace)…")
    t0 = time.time()
    try:
        from TTS.api import TTS  # type: ignore[import]
    except ImportError as exc:
        log(f"ERROR: Could not import TTS package: {exc}")
        log("  Install with:  pip install TTS")
        log("  Or re-run setup:  bash setup_kaggle.sh")
        sys.exit(1)

    try:
        tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
    except Exception as exc:  # noqa: BLE001
        log(f"ERROR: Failed to load XTTS2 model: {exc}")
        sys.exit(1)
    log(f"Model loaded in {time.time() - t0:.1f}s")

    # ── Synthesise ────────────────────────────────────────────────────────────
    import numpy as np
    import soundfile as sf

    # Split on [SEGMENT] markers (kept for backward-compat with multi-segment scripts).
    segments = [s.strip() for s in args.text.split("[SEGMENT]") if s.strip()]
    if not segments:
        log("ERROR: No text to synthesise (empty after stripping)")
        sys.exit(1)

    log(f"Synthesising {len(segments)} segment(s) ({len(args.text)} chars total)…")
    chunks: list[np.ndarray] = []
    sample_rate = 24000  # XTTS2 native output rate

    for i, segment in enumerate(segments, 1):
        log(f"  Segment {i}/{len(segments)} ({len(segment)} chars)…")
        t_seg = time.time()
        try:
            if ref_wav:
                audio = tts.tts(
                    text=segment,
                    speaker_wav=str(ref_wav),
                    language=args.language,
                )
            else:
                # No reference WAV — use a built-in XTTS2 speaker
                audio = tts.tts(
                    text=segment,
                    speaker=tts.speakers[0] if tts.speakers else None,
                    language=args.language,
                )
        except Exception as exc:  # noqa: BLE001
            log(f"ERROR: Synthesis failed on segment {i}: {exc}")
            sys.exit(1)
        chunks.append(np.array(audio, dtype=np.float32))
        log(f"  Segment {i} done in {time.time() - t_seg:.1f}s")

    combined = np.concatenate(chunks) if chunks else np.zeros(sample_rate, dtype=np.float32)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_path), combined, sample_rate)
    sz = out_path.stat().st_size
    log(f"Saved → {out_path} ({sz:,} bytes, {len(combined) / sample_rate:.1f}s audio)")


if __name__ == "__main__":
    main()
