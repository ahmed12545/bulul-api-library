"""
app.py — Bulul API demo service
Endpoints:
  GET  /health               → service liveness check
  POST /generate-podcast     → generate a podcast audio file
"""

from __future__ import annotations

import os
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from dotenv import load_dotenv
from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

load_dotenv()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    _load_tts_model()
    yield


app = FastAPI(title="Bulul API", version="0.1.0", lifespan=lifespan)

TMP_DIR = Path(os.getenv("TMP_AUDIO_DIR", "runtime/tmp"))
TMP_DIR.mkdir(parents=True, exist_ok=True)

GROQ_API_KEY = os.getenv("GROQ_API_KEY", "")

LANGUAGE_LEVELS = {"A1", "A2", "B1", "B2", "C1", "C2"}

# ── TTS model (loaded once at startup) ───────────────────────────────────────
_tts_model = None


def _load_tts_model():
    """Load StyleTTS2 onto GPU (or CPU) once at startup."""
    global _tts_model  # noqa: PLW0603
    if _tts_model is not None:
        return _tts_model

    models_dir = Path("models/styletts2")

    # Allow selecting which installed checkpoint the API uses via env var.
    # Valid values match the download_models.sh catalog labels: ljspeech, libri, libri-100.
    ckpt_name = os.getenv("STYLETTS2_CKPT_NAME", "ljspeech").strip()
    _ckpt_map = {
        "ljspeech":  ("epoch_2nd_00100.pth",      "config.yml"),
        "libri":     ("epoch_2nd_00020_libri.pth", "config_libri.yml"),
        "libri-100": ("epochs_2nd_00100_libri.pth", "config_libri.yml"),
    }
    if ckpt_name not in _ckpt_map:
        print(
            f"[app] WARNING: Unknown STYLETTS2_CKPT_NAME='{ckpt_name}'. "
            f"Valid values: {', '.join(_ckpt_map)}. Falling back to 'ljspeech'."
        )
        ckpt_name = "ljspeech"
    _ckpt_file, _cfg_file = _ckpt_map[ckpt_name]
    ckpt = models_dir / _ckpt_file
    cfg = models_dir / _cfg_file

    if not ckpt.exists() or not cfg.exists():
        # Model not downloaded yet — run in stub/demo mode
        print("[app] WARNING: StyleTTS2 model not found. Running in stub mode.")
        _tts_model = "stub"
        return _tts_model

    try:
        import torch  # noqa: F401 – optional at import time

        # StyleTTS2 uses its own inference helper; import lazily so the app
        # still starts in stub mode when the package is not installed.
        from styletts2 import tts as styletts2_tts  # type: ignore[import]

        # USE_CPU_INFERENCE=1 forces CPU even when a GPU is available.
        _use_cpu = os.getenv("USE_CPU_INFERENCE", "0").strip() in ("1", "true", "True", "yes")
        device = "cpu" if _use_cpu else ("cuda" if torch.cuda.is_available() else "cpu")
        print(f"[app] Loading StyleTTS2 ({ckpt_name}) on {device}…")
        _tts_model = styletts2_tts.StyleTTS2(
            model_checkpoint_path=str(ckpt),
            config_path=str(cfg),
        )
        print("[app] StyleTTS2 loaded ✅")
    except Exception as exc:  # noqa: BLE001
        print(f"[app] WARNING: Could not load StyleTTS2 ({exc}). Running in stub mode.")
        _tts_model = "stub"

    return _tts_model


# ── Schemas ───────────────────────────────────────────────────────────────────


class PodcastRequest(BaseModel):
    topic: str = Field(..., min_length=1, description="Podcast topic")
    language_level: str = Field(
        "B1",
        description="CEFR language level: A1 A2 B1 B2 C1 C2",
    )
    format: str = Field("mp3", description="Output format: wav or mp3")


# ── Helpers ───────────────────────────────────────────────────────────────────

LEVEL_WORD_TARGETS: dict[str, int] = {
    "A1": 600,
    "A2": 650,
    "B1": 750,
    "B2": 800,
    "C1": 875,
    "C2": 950,
}

LEVEL_INSTRUCTIONS: dict[str, str] = {
    "A1": "Use only very simple, short sentences and very basic vocabulary. Speak slowly and clearly.",
    "A2": "Use simple sentences and basic vocabulary. Avoid complex grammar.",
    "B1": "Use clear sentences and everyday vocabulary. Some complex sentences are fine.",
    "B2": "Use a range of vocabulary and moderately complex sentences naturally.",
    "C1": "Use varied vocabulary, idiomatic expressions, and complex sentence structures.",
    "C2": "Use rich, nuanced vocabulary and sophisticated sentence structures throughout.",
}


def _build_groq_prompt(topic: str, level: str) -> str:
    target_words = LEVEL_WORD_TARGETS.get(level, 750)
    level_instruction = LEVEL_INSTRUCTIONS.get(level, "")
    return (
        f"Write a spoken podcast script about: '{topic}'.\n\n"
        f"Language level: {level}. {level_instruction}\n\n"
        f"Target length: approximately {target_words} words (around 5–6 minutes when spoken).\n\n"
        "Format rules:\n"
        "- No bullet points or markdown.\n"
        "- Natural spoken language only.\n"
        "- Include a short intro, 3–5 body segments, and a brief outro.\n"
        "- Mark each segment with [SEGMENT] on its own line.\n"
        "- No stage directions, no (pause) notes.\n"
        "- Output only the script text."
    )


def _generate_script_groq(topic: str, level: str) -> str:
    """Call Groq API to generate podcast script."""
    if not GROQ_API_KEY:
        raise HTTPException(status_code=500, detail="GROQ_API_KEY not configured")

    from groq import Groq  # lazy import

    client = Groq(api_key=GROQ_API_KEY)
    response = client.chat.completions.create(
        model="llama3-8b-8192",
        messages=[{"role": "user", "content": _build_groq_prompt(topic, level)}],
        temperature=0.7,
        max_tokens=2048,
    )
    return response.choices[0].message.content or ""


def _synthesise_audio(script: str, output_path: Path, fmt: str) -> None:
    """Convert script to audio using StyleTTS2, or generate a silent stub."""
    model = _load_tts_model()

    if model == "stub":
        # Generate a short silent WAV as placeholder
        import struct
        import wave

        wav_path = output_path.with_suffix(".wav")
        duration_sec = 3
        sample_rate = 22050
        num_samples = duration_sec * sample_rate
        with wave.open(str(wav_path), "w") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(struct.pack("<" + "h" * num_samples, *([0] * num_samples)))

        if fmt == "mp3":
            try:
                import subprocess

                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(wav_path), str(output_path)],
                    check=True,
                    capture_output=True,
                )
                wav_path.unlink(missing_ok=True)
            except Exception:  # noqa: BLE001
                # ffmpeg not available — return wav instead
                output_path.parent.mkdir(parents=True, exist_ok=True)
                wav_path.rename(output_path.with_suffix(".wav"))
        return

    # Real StyleTTS2 synthesis
    import numpy as np
    import soundfile as sf

    segments = [s.strip() for s in script.split("[SEGMENT]") if s.strip()]
    chunks: list[np.ndarray] = []
    sample_rate = 24000

    for i, segment in enumerate(segments):
        print(f"[app] Synthesising segment {i + 1}/{len(segments)}…")
        audio = model.inference(segment, output_sample_rate=sample_rate)
        chunks.append(np.array(audio, dtype=np.float32))

    combined = np.concatenate(chunks) if chunks else np.zeros(sample_rate, dtype=np.float32)

    wav_path = output_path.with_suffix(".wav")
    sf.write(str(wav_path), combined, sample_rate)

    if fmt == "mp3":
        try:
            import subprocess

            subprocess.run(
                ["ffmpeg", "-y", "-i", str(wav_path), str(output_path)],
                check=True,
                capture_output=True,
            )
            wav_path.unlink(missing_ok=True)
        except Exception:  # noqa: BLE001
            output_path = wav_path  # fall back to wav


def _delete_file(path: str) -> None:
    try:
        Path(path).unlink(missing_ok=True)
    except Exception:  # noqa: BLE001
        pass


# ── Routes ────────────────────────────────────────────────────────────────────


@app.get("/health")
async def health():
    return {"status": "ok", "service": "bulul-api"}


@app.post("/generate-podcast")
async def generate_podcast(
    request: PodcastRequest,
    background_tasks: BackgroundTasks,
):
    # Validate language level
    level = request.language_level.upper()
    if level not in LANGUAGE_LEVELS:
        raise HTTPException(
            status_code=422,
            detail=f"language_level must be one of {sorted(LANGUAGE_LEVELS)}",
        )

    fmt = request.format.lower()
    if fmt not in {"wav", "mp3"}:
        raise HTTPException(status_code=422, detail="format must be 'wav' or 'mp3'")

    # Unique output path
    job_id = uuid.uuid4().hex
    output_path = TMP_DIR / f"{job_id}.{fmt}"

    # Generate script via Groq
    script = _generate_script_groq(request.topic, level)
    if not script.strip():
        raise HTTPException(status_code=500, detail="Empty script returned from LLM")

    # Synthesise audio
    _synthesise_audio(script, output_path, fmt)

    # Resolve actual file (synthesis may have fallen back to .wav)
    actual_path = output_path if output_path.exists() else output_path.with_suffix(".wav")
    if not actual_path.exists():
        raise HTTPException(status_code=500, detail="Audio generation failed")

    media_type = "audio/mpeg" if actual_path.suffix == ".mp3" else "audio/wav"

    # Schedule file deletion after response is sent
    background_tasks.add_task(_delete_file, str(actual_path))

    return FileResponse(
        path=str(actual_path),
        media_type=media_type,
        filename=actual_path.name,
        background=background_tasks,
    )
