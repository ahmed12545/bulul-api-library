#!/usr/bin/env python3
"""
scripts/synthesize.py — StyleTTS2 text-to-speech inference helper.

Usage:
    python -u scripts/synthesize.py --text "Hello world." --output out.wav

All print statements use flush=True for Kaggle-friendly unbuffered output
(avoids apparent hangs in notebook cells).
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path


def log(msg: str) -> None:
    print(f"[synthesize] {msg}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="StyleTTS2 inference helper")
    parser.add_argument("--text", required=True, help="Text to synthesize")
    parser.add_argument("--output", required=True, help="Output .wav path")
    parser.add_argument(
        "--ckpt",
        default=None,
        help="Checkpoint path (default: models/styletts2/epoch_2nd_00100.pth)",
    )
    parser.add_argument(
        "--config",
        default=None,
        help="Config YAML path (default: models/styletts2/config.yml)",
    )
    parser.add_argument(
        "--diffusion-steps",
        type=int,
        default=10,
        help="Diffusion steps (default: 10; higher = slower but smoother)",
    )
    parser.add_argument(
        "--embedding-scale",
        type=float,
        default=1.0,
        help="Embedding scale / style strength (default: 1.0)",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).parent.parent
    ckpt = Path(args.ckpt) if args.ckpt else repo_root / "models/styletts2/epoch_2nd_00100.pth"
    cfg = Path(args.config) if args.config else repo_root / "models/styletts2/config.yml"
    styletts2_src = repo_root / "models/StyleTTS2"

    log(f"StyleTTS2 source : {styletts2_src}")
    log(f"Checkpoint       : {ckpt}")
    log(f"Config           : {cfg}")
    log(f"Output           : {args.output}")

    # ── Validate required assets ──────────────────────────────────────────────
    missing: list[str] = []
    if not styletts2_src.is_dir():
        missing.append(f"StyleTTS2 source directory not found: {styletts2_src}")
    if not ckpt.exists():
        missing.append(f"Checkpoint not found: {ckpt}")
    if not cfg.exists():
        missing.append(f"Config not found: {cfg}")

    if missing:
        for m in missing:
            log(f"ERROR: {m}")
        log("Run 'bash setup_kaggle.sh' (or 'bash download_models.sh') to download assets.")
        sys.exit(1)

    # ── Add StyleTTS2 source to import path ───────────────────────────────────
    sys.path.insert(0, str(styletts2_src))

    log("Importing torch…")
    import torch  # noqa: F401

    device = "cuda" if torch.cuda.is_available() else "cpu"
    log(f"Device: {device}")
    if device == "cuda":
        log(f"GPU: {torch.cuda.get_device_name(0)}")

    log("Importing StyleTTS2…")
    try:
        from styletts2 import tts as styletts2_tts  # type: ignore[import]
    except ImportError as exc:
        log(f"ERROR: Could not import StyleTTS2 pip package: {exc}")
        # Diagnose the local source tree layout to give an actionable message.
        _py_files = sorted(styletts2_src.glob("*.py")) if styletts2_src.is_dir() else []
        _has_pkg = (styletts2_src / "styletts2").is_dir()
        if _has_pkg:
            log("  models/StyleTTS2/styletts2/ directory found but import still failed.")
            log("  Possible cause: missing dependency (e.g. einops_exts, phonemizer).")
        elif _py_files:
            _names = [f.name for f in _py_files[:6]]
            log(f"  models/StyleTTS2 contains {len(_py_files)} .py file(s): {_names} …")
            log("  This is the yl4579/StyleTTS2 training-layout tree — it does NOT")
            log("  expose an installable 'styletts2' Python package on its own.")
        else:
            log("  models/StyleTTS2 is empty or missing Python files.")
        log("  Fix: install the pip package in your active environment:")
        log("    pip install 'styletts2==0.1.6' einops_exts")
        log("  Or re-run setup to install all dependencies:")
        log("    bash setup_kaggle.sh")
        sys.exit(1)

    log("Loading model (may take a few minutes on first run)…")
    t0 = time.time()
    try:
        model = styletts2_tts.StyleTTS2(
            model_checkpoint_path=str(ckpt),
            config_path=str(cfg),
        )
    except (RuntimeError, OSError, ValueError) as exc:
        log(f"ERROR: Failed to load StyleTTS2 model: {exc}")
        sys.exit(1)
    log(f"Model loaded in {time.time() - t0:.1f}s")

    # ── Synthesise ────────────────────────────────────────────────────────────
    import numpy as np
    import soundfile as sf

    segments = [s.strip() for s in args.text.split("[SEGMENT]") if s.strip()]
    if not segments:
        log("ERROR: No text to synthesise (empty after stripping)")
        sys.exit(1)

    chunks: list[np.ndarray] = []
    sample_rate = 24000

    log(f"Synthesising {len(segments)} segment(s) ({len(args.text)} chars total)…")
    for i, segment in enumerate(segments, 1):
        log(f"  Segment {i}/{len(segments)} ({len(segment)} chars)…")
        t_seg = time.time()
        audio = model.inference(
            segment,
            diffusion_steps=args.diffusion_steps,
            embedding_scale=args.embedding_scale,
            output_sample_rate=sample_rate,
        )
        chunks.append(np.array(audio, dtype=np.float32))
        log(f"  Segment {i} done in {time.time() - t_seg:.1f}s")

    combined = np.concatenate(chunks) if chunks else np.zeros(sample_rate, dtype=np.float32)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_path), combined, sample_rate)
    sz = out_path.stat().st_size
    log(f"Saved → {out_path} ({sz:,} bytes, {len(combined)/sample_rate:.1f}s audio)")


if __name__ == "__main__":
    main()
