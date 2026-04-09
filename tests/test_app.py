"""
tests/test_app.py — smoke tests for the API routes.
Run with: pytest tests/test_app.py -v
"""

import importlib
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Minimal stubs so app.py can be imported without real heavy dependencies
# ---------------------------------------------------------------------------


def _stub_module(name: str, **attrs):
    """Insert a minimal stub module into sys.modules."""
    mod = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(mod, k, v)
    sys.modules[name] = mod
    return mod


# Stub groq
groq_stub = _stub_module("groq")
groq_stub.Groq = MagicMock()  # type: ignore[attr-defined]

# Stub dotenv
dotenv_stub = _stub_module("dotenv")
dotenv_stub.load_dotenv = lambda: None  # type: ignore[attr-defined]

# Make sure the repo root is on the path
sys.path.insert(0, str(Path(__file__).parent.parent))


@pytest.fixture(scope="module")
def client():
    """Return a TestClient with the TTS model forced into stub mode."""
    with patch.dict("os.environ", {"GROQ_API_KEY": "test-key", "TMP_AUDIO_DIR": "/tmp/bulul_api_test"}):
        # Reload app so env vars are picked up and model loads as stub
        import app as app_module

        importlib.reload(app_module)
        app_module._tts_model = "stub"  # force stub mode

        from fastapi.testclient import TestClient

        return TestClient(app_module.app)


# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert "service" in data


# ---------------------------------------------------------------------------
# /generate-podcast — input validation
# ---------------------------------------------------------------------------


def test_generate_podcast_missing_topic(client):
    resp = client.post("/generate-podcast", json={"language_level": "B1"})
    assert resp.status_code == 422


def test_generate_podcast_invalid_level(client):
    resp = client.post(
        "/generate-podcast",
        json={"topic": "space exploration", "language_level": "Z9"},
    )
    assert resp.status_code == 422


def test_generate_podcast_invalid_format(client):
    resp = client.post(
        "/generate-podcast",
        json={"topic": "space exploration", "language_level": "B1", "format": "ogg"},
    )
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# /generate-podcast — happy path (stub TTS + mocked Groq)
# ---------------------------------------------------------------------------


@patch("app._generate_script_groq", return_value="[SEGMENT] Hello world. This is a test podcast.")
def test_generate_podcast_stub(mock_groq, client):
    resp = client.post(
        "/generate-podcast",
        json={"topic": "science", "language_level": "B1", "format": "wav"},
    )
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("audio/")


@patch("app._generate_script_groq", return_value="[SEGMENT] Another test.")
def test_generate_podcast_all_levels(mock_groq, client):
    """All valid CEFR levels should be accepted."""
    for level in ("A1", "A2", "B1", "B2", "C1", "C2"):
        resp = client.post(
            "/generate-podcast",
            json={"topic": "history", "language_level": level, "format": "wav"},
        )
        assert resp.status_code == 200, f"Failed for level {level}"


@patch("app._generate_script_groq", return_value="")
def test_generate_podcast_empty_script(mock_groq, client):
    """Empty script from LLM should return 500."""
    resp = client.post(
        "/generate-podcast",
        json={"topic": "anything", "language_level": "A1", "format": "wav"},
    )
    assert resp.status_code == 500
