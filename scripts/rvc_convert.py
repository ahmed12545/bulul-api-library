#!/usr/bin/env python3
"""
scripts/rvc_convert.py — RVC (Retrieval-based Voice Conversion) inference helper.

Converts an existing WAV file to a target voice using a pre-trained RVC model.
Intended to be used after scripts/synthesize.py to apply a different voice
identity to StyleTTS2-generated audio while preserving the original prosody.

Usage:
    python -u scripts/rvc_convert.py \
        --input  base.wav \
        --output converted.wav \
        --model  models/rvc/my_voice.pth \
        [--index  models/rvc/my_voice.index] \
        [--pitch  0] \
        [--method rmvpe]

All print statements use flush=True for Kaggle-friendly unbuffered output.

Required model assets
---------------------
  models/rvc/<voice_name>.pth    — RVC model checkpoint
  models/rvc/<voice_name>.index  — (optional) faiss index; improves similarity

Download custom RVC voice models from https://huggingface.co/models?search=rvc
and place the .pth (and optional .index) files in models/rvc/.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


def log(msg: str) -> None:
    print(f"[rvc_convert] {msg}", flush=True)


def _find_rvc_src(repo_root: Path) -> Path | None:
    candidate = repo_root / "models/RVC"
    if (candidate / "infer").is_dir():
        return candidate
    return None


def _run_rvc_python_api(
    rvc_src: Path,
    input_path: Path,
    output_path: Path,
    model_path: Path,
    index_path: Path | None,
    pitch: int,
    method: str,
    index_rate: float,
    filter_radius: int,
    rms_mix_rate: float,
    protect: float,
) -> None:
    """Run RVC conversion via its Python API (preferred)."""
    sys.path.insert(0, str(rvc_src))
    os.chdir(rvc_src)  # RVC loads relative resource paths at import time

    log("Importing RVC config…")
    from configs.config import Config  # type: ignore[import]
    from infer.modules.vc.modules import VC  # type: ignore[import]

    config = Config()
    vc = VC(config)

    log(f"Loading VC model: {model_path.name}…")
    vc.get_vc(str(model_path), protect, protect)

    log("Running voice conversion…")
    idx_str = str(index_path) if index_path else ""
    _, audio_opt = vc.vc_single(
        0,
        str(input_path),
        pitch,
        None,
        method,
        idx_str,
        None,
        index_rate,
        filter_radius,
        0,           # resample_sr (0 = keep original)
        rms_mix_rate,
        protect,
    )

    import soundfile as sf

    if isinstance(audio_opt, tuple):
        sr, data = audio_opt
    else:
        sr, data = 40000, audio_opt

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(output_path), data, sr)


def _run_rvc_cli(
    rvc_src: Path,
    input_path: Path,
    output_path: Path,
    model_path: Path,
    index_path: Path | None,
    pitch: int,
    method: str,
    index_rate: float,
    filter_radius: int,
    rms_mix_rate: float,
    protect: float,
) -> None:
    """Fallback: call RVC infer_cli.py via subprocess."""
    cli = rvc_src / "tools" / "infer_cli.py"
    if not cli.exists():
        raise FileNotFoundError(f"RVC CLI not found: {cli}")

    cmd = [
        sys.executable, "-u", str(cli),
        "--model_name", str(model_path),
        "--input_path", str(input_path),
        "--output_path", str(output_path),
        "--f0up_key", str(pitch),
        "--f0method", method,
        "--index_rate", str(index_rate),
        "--filter_radius", str(filter_radius),
        "--rms_mix_rate", str(rms_mix_rate),
        "--protect", str(protect),
    ]
    if index_path:
        cmd += ["--index_path", str(index_path)]

    log(f"CLI command: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(rvc_src), text=True, capture_output=False)
    if result.returncode != 0:
        raise RuntimeError(f"RVC CLI exited with code {result.returncode}")


def main() -> None:
    parser = argparse.ArgumentParser(description="RVC voice conversion helper")
    parser.add_argument("--input", required=True, help="Input .wav file (StyleTTS2 output)")
    parser.add_argument("--output", required=True, help="Output .wav path after voice conversion")
    parser.add_argument(
        "--model",
        required=True,
        help="Path to RVC .pth model checkpoint (e.g. models/rvc/voice.pth)",
    )
    parser.add_argument(
        "--index",
        default=None,
        help="Path to RVC .index file (optional; improves voice similarity)",
    )
    parser.add_argument(
        "--pitch",
        type=int,
        default=0,
        help="Pitch shift in semitones (default: 0; positive=higher, negative=lower)",
    )
    parser.add_argument(
        "--method",
        default="rmvpe",
        choices=["rmvpe", "harvest", "crepe", "pm"],
        help="Pitch extraction method (default: rmvpe)",
    )
    parser.add_argument("--index-rate", type=float, default=0.75, help="Index mix rate 0–1 (default: 0.75)")
    parser.add_argument("--filter-radius", type=int, default=3, help="Median filter radius (default: 3)")
    parser.add_argument("--rms-mix-rate", type=float, default=0.25, help="RMS mix rate 0–1 (default: 0.25)")
    parser.add_argument("--protect", type=float, default=0.33, help="Consonant protection 0–0.5 (default: 0.33)")
    args = parser.parse_args()

    repo_root = Path(__file__).parent.parent
    input_path = Path(args.input)
    output_path = Path(args.output)
    model_path = Path(args.model)
    index_path = Path(args.index) if args.index else None

    log(f"Input  : {input_path}")
    log(f"Output : {output_path}")
    log(f"Model  : {model_path}")
    if index_path:
        log(f"Index  : {index_path}")
    log(f"Pitch  : {args.pitch:+d} semitones  Method: {args.method}")

    # ── Validate inputs ───────────────────────────────────────────────────────
    errors: list[str] = []
    if not input_path.exists():
        errors.append(f"Input file not found: {input_path}")
    if not model_path.exists():
        errors.append(
            f"RVC model not found: {model_path}\n"
            "  → Place your .pth file in models/rvc/ and pass --model models/rvc/<file>.pth\n"
            "  → Download RVC models from https://huggingface.co/models?search=rvc"
        )
    if index_path and not index_path.exists():
        log(f"WARNING: Index file not found ({index_path}) — continuing without it")
        index_path = None

    if errors:
        for e in errors:
            log(f"ERROR: {e}")
        sys.exit(1)

    # ── Locate RVC source ─────────────────────────────────────────────────────
    rvc_src = _find_rvc_src(repo_root)
    if rvc_src is None:
        log("ERROR: RVC source not found at models/RVC/")
        log("  → Run 'bash setup_kaggle.sh' or 'bash download_models.sh' to clone it.")
        sys.exit(1)
    log(f"RVC source: {rvc_src}")

    # ── Run conversion ────────────────────────────────────────────────────────
    t0 = time.time()
    try:
        _run_rvc_python_api(
            rvc_src=rvc_src,
            input_path=input_path,
            output_path=output_path,
            model_path=model_path,
            index_path=index_path,
            pitch=args.pitch,
            method=args.method,
            index_rate=args.index_rate,
            filter_radius=args.filter_radius,
            rms_mix_rate=args.rms_mix_rate,
            protect=args.protect,
        )
    except (ImportError, RuntimeError, OSError, ValueError) as api_exc:
        log(f"Python API failed ({api_exc}) — trying CLI fallback…")
        try:
            _run_rvc_cli(
                rvc_src=rvc_src,
                input_path=input_path,
                output_path=output_path,
                model_path=model_path,
                index_path=index_path,
                pitch=args.pitch,
                method=args.method,
                index_rate=args.index_rate,
                filter_radius=args.filter_radius,
                rms_mix_rate=args.rms_mix_rate,
                protect=args.protect,
            )
        except (ImportError, RuntimeError, OSError, FileNotFoundError) as cli_exc:
            log("ERROR: Both RVC methods failed.")
            log(f"  Python API error: {api_exc}")
            log(f"  CLI error: {cli_exc}")
            sys.exit(1)

    elapsed = time.time() - t0
    if output_path.exists():
        sz = output_path.stat().st_size
        log(f"Conversion done in {elapsed:.1f}s → {output_path} ({sz:,} bytes)")
    else:
        log(f"ERROR: Output file not created: {output_path}")
        sys.exit(1)


if __name__ == "__main__":
    main()
