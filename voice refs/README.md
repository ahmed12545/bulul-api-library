# voice refs

Place your reference WAV files here for XTTS2 voice cloning.

## How it works

XTTS2 clones a target voice from a short audio sample (3–30 seconds of clean speech).
Any `.wav` file you place in this folder can be used as a cloning reference.

## Usage

```bash
# Synthesise with a specific reference WAV
python -u scripts/synthesize.py \
    --text "Hello, welcome to the podcast." \
    --output output.wav \
    --ref-wav "voice refs/my_voice.wav"

# The test script also accepts a reference WAV
bash tests/test.sh \
    --text "Hello, welcome." \
    --ref-wav "voice refs/my_voice.wav"

# If --ref-wav is omitted, the first WAV found in this folder is used automatically.
```

## Guidelines for reference audio

| Attribute | Recommendation |
|---|---|
| Duration | 6–30 seconds (longer = better similarity) |
| Format | WAV, 22050 or 44100 Hz, mono or stereo |
| Content | Clear speech, minimal background noise |
| Language | Should match the synthesis language |

## Notes

- WAV files in this folder are gitignored by default (to keep the repo lightweight).
  Commit your reference files manually if you want them tracked:
  `git add -f "voice refs/my_voice.wav"`
- The XTTS2 model is multilingual. Set `--language` to match your reference audio
  (e.g. `en`, `ar`, `fr`, `de`, `es`, `pt`, `pl`, `tr`, `ru`, `nl`, `cs`, `it`, `zh-cn`).
