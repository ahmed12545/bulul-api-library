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

# ── Headless / Kaggle compatibility ──────────────────────────────────────────
_mpl = os.environ.get("MPLBACKEND", "")
if not _mpl or _mpl.startswith("module://"):
    os.environ["MPLBACKEND"] = "Agg"


@asynccontextmanager
async def lifespan(_app: FastAPI):
    _load_tts_model()
    yield


app = FastAPI(title="Bulul API", version="0.2.0", lifespan=lifespan)

TMP_DIR = Path(os.getenv("TMP_AUDIO_DIR", "runtime/tmp"))
TMP_DIR.mkdir(parents=True, exist_ok=True)

GROQ_API_KEY = os.getenv("GROQ_API_KEY", "")

LANGUAGE_LEVELS = {"A1", "A2", "B1", "B2", "C1", "C2"}

# ── TTS model (loaded once at startup) ───────────────────────────────────────
_tts_model = None
_tts_device = "cpu"


def _find_default_ref_wav() -> Path | None:
    """Return the first .wav found in 'voice refs/', or None."""
    voice_refs = Path("voice refs")
    if voice_refs.is_dir():
        wavs = sorted(voice_refs.glob("*.wav"))
        if wavs:
            return wavs[0]
    return None


def _load_tts_model():
    """Load XTTS2 onto GPU (or CPU) once at startup."""
    global _tts_model, _tts_device  # noqa: PLW0603

    if _tts_model is not None:
        return _tts_model

    try:
        import torch
        from TTS.api import TTS  # type: ignore[import]

        _tts_device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"[app] Loading XTTS2 on {_tts_device}…")
        _tts_model = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(_tts_device)
        print("[app] XTTS2 loaded ✅")
    except Exception as exc:  # noqa: BLE001
        print(f"[app] WARNING: Could not load XTTS2 ({exc}). Running in stub mode.")
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
    """Convert script to audio using XTTS2, or generate a silent stub."""
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
                wav_path.rename(output_path.with_suffix(".wav"))
        return

    # Real XTTS2 synthesis
    import numpy as np
    import soundfile as sf

    ref_wav = _find_default_ref_wav()
    segments = [s.strip() for s in script.split("[SEGMENT]") if s.strip()]
    chunks: list[np.ndarray] = []
    sample_rate = 24000  # XTTS2 native rate

    for i, segment in enumerate(segments):
        print(f"[app] Synthesising segment {i + 1}/{len(segments)}…")
        if ref_wav:
            audio = model.tts(
                text=segment,
                speaker_wav=str(ref_wav),
                language="en",
            )
        else:
            audio = model.tts(
                text=segment,
                speaker=model.speakers[0] if model.speakers else None,
                language="en",
            )
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
