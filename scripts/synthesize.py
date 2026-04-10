#!/usr/bin/env python3
"""
scripts/synthesize.py — StyleTTS2 text-to-speech inference with voice cloning.

Usage:
    # Voice cloning from a reference WAV:
    python -u scripts/synthesize.py \\
        --text "Hello world." \\
        --output out.wav \\
        --ref-wav "voice refs/my_voice.wav"

    # Default voice (no reference WAV required):
    python -u scripts/synthesize.py \\
        --text "Hello world." \\
        --output out.wav

Place reference WAVs in the 'voice refs/' folder at the repo root.
If --ref-wav is omitted, the first .wav found in 'voice refs/' is used.
If no reference is found, the StyleTTS2 default voice is used.

StyleTTS2 parameters:
    --diffusion-steps N   Number of diffusion steps (default: 5)
    --embedding-scale F   Style intensity (default: 1.0)

All print statements use flush=True for Kaggle-friendly unbuffered output
(avoids apparent hangs in notebook cells).

Migration note: XTTS2 removed by user request. RVC removed.
  Legacy flags (--voice-id, --list-speakers, --voice-model, --voice-index,
  --no-rvc) are not accepted and will produce a clear error.
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
# --voice-id / --list-speakers were XTTS2-specific (built-in speakers).
# --voice-model / --voice-index / --no-rvc were RVC-specific.
# StyleTTS2 uses --ref-wav for voice cloning; no built-in speaker IDs.
_LEGACY_FLAGS = {
    "--voice-id",
    "--list-speakers",
    "--voice-model",
    "--voice-index",
    "--no-rvc",
    "--ckpt",
    "--ckpt-name",
    "--config",
}


def log(msg: str) -> None:
    print(f"[synthesize] {msg}", flush=True)


def _check_legacy_flags() -> None:
    for raw in sys.argv[1:]:
        name = raw.split("=")[0]
        if name in _LEGACY_FLAGS:
            log(f"ERROR: Legacy flag '{name}' is not supported.")
            if name in ("--voice-id", "--list-speakers"):
                log("  XTTS2 built-in speaker IDs have been removed.")
                log("  StyleTTS2 uses reference-WAV voice cloning (--ref-wav).")
            elif name in ("--voice-model", "--voice-index", "--no-rvc"):
                log("  RVC has been removed from this project.")
            elif name in ("--ckpt", "--ckpt-name"):
                log("  Custom checkpoint selection is not supported in this release.")
                log("  The styletts2 package downloads the default model automatically.")
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
        description="StyleTTS2 inference helper — voice cloning or default-voice synthesis"
    )
    parser.add_argument("--text", help="Text to synthesize")
    parser.add_argument("--output", help="Output .wav path")
    parser.add_argument(
        "--ref-wav",
        default=None,
        metavar="PATH",
        help=(
            "Reference WAV file for voice cloning (6–30 s of clean speech). "
            "If omitted, the first .wav found in 'voice refs/' is used. "
            "If none is found, the StyleTTS2 default voice is used."
        ),
    )
    parser.add_argument(
        "--diffusion-steps",
        type=int,
        default=5,
        metavar="N",
        help=(
            "Number of StyleTTS2 diffusion steps (default: 5). "
            "Higher values improve quality at the cost of speed."
        ),
    )
    parser.add_argument(
        "--embedding-scale",
        type=float,
        default=1.0,
        metavar="F",
        help="StyleTTS2 embedding / style intensity (default: 1.0).",
    )
    parser.add_argument(
        "--cpu",
        action="store_true",
        default=False,
        help="Force CPU inference even when a GPU is available (default: auto-select GPU)",
    )
    args = parser.parse_args()

    if not args.text:
        parser.error("--text is required")
    if not args.output:
        parser.error("--output is required")

    repo_root = Path(__file__).parent.parent
    voice_refs_dir = repo_root / "voice refs"
    out_path = Path(args.output)

    # Diagnostics: print interpreter and active conda env so env-mismatch failures
    # are immediately visible in the log.
    log(f"Python   : {sys.executable}")
    _conda_env = (
        os.environ.get("CONDA_DEFAULT_ENV")
        or os.environ.get("CONDA_PREFIX", "").rsplit("/", 1)[-1]
        or "(unknown)"
    )
    log(f"Conda env: {_conda_env}")
    log(f"Output   : {out_path}")

    # ── Resolve reference WAV ─────────────────────────────────────────────────
    ref_wav: Path | None = None
    if args.ref_wav:
        ref_wav = Path(args.ref_wav)
    else:
        ref_wav = _find_default_ref_wav(voice_refs_dir)
        if ref_wav:
            log(f"Ref WAV  : {ref_wav} (auto-detected from 'voice refs/')")
        else:
            log("Ref WAV  : (none found in 'voice refs/' — using StyleTTS2 default voice)")

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

    # ── Load StyleTTS2 model ──────────────────────────────────────────────────
    log("Loading StyleTTS2 model (first run downloads weights from HuggingFace)…")
    t0 = time.time()
    try:
        from styletts2 import tts as stts2  # type: ignore[import]
    except ImportError as exc:
        log(f"ERROR: Could not import styletts2 package: {exc}")
        log("  Install with:  pip install styletts2")
        log("  Also requires:  apt-get install espeak-ng")
        log("  Or re-run setup:  bash setup_kaggle.sh")
        sys.exit(1)

    try:
        model = stts2.StyleTTS2()
    except Exception as exc:  # noqa: BLE001
        log(f"ERROR: Failed to load StyleTTS2 model: {exc}")
        sys.exit(1)
    log(f"Model loaded in {time.time() - t0:.1f}s")

    if ref_wav:
        log(f"Mode     : voice cloning  (ref: {ref_wav})")
    else:
        log("Mode     : default voice  (no reference WAV)")

    # ── Synthesise ────────────────────────────────────────────────────────────
    import numpy as np
    import soundfile as sf

    # Split on [SEGMENT] markers for multi-segment podcast scripts.
    segments = [s.strip() for s in args.text.split("[SEGMENT]") if s.strip()]
    if not segments:
        log("ERROR: No text to synthesise (empty after stripping)")
        sys.exit(1)

    log(f"Synthesising {len(segments)} segment(s) ({len(args.text)} chars total)…")
    chunks: list[np.ndarray] = []
    sample_rate = 24000  # StyleTTS2 native output rate

    ref_wav_str = str(ref_wav) if ref_wav else None

    for i, segment in enumerate(segments, 1):
        log(f"  Segment {i}/{len(segments)} ({len(segment)} chars)…")
        t_seg = time.time()
        try:
            audio = model.inference(
                segment,
                target_voice_path=ref_wav_str,
                diffusion_steps=args.diffusion_steps,
                embedding_scale=args.embedding_scale,
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
