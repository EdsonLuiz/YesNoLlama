# TODO

## Text-to-Speech (TTS) — `/v1/audio/speech`

`openvino_genai.Text2SpeechPipeline` exists. Only SpeechT5 supported so far.

**Export:**
```bash
optimum-cli export openvino \
  --model microsoft/speecht5_tts \
  --weight-format int4 \
  --model-kwargs '{"vocoder":"microsoft/speecht5_hifigan"}' \
  speecht5_tts
```

**What's needed:**
- `--tts-dir` flag, similar to `--whisper-dir`
- `POST /v1/audio/speech` endpoint (OpenAI-compatible)
- Speaker embedding files (512×float32 `.bin`), map OpenAI voice names (`alloy`, `echo`, etc.) to them
- CPU or GPU only — no NPU support for encoder-decoder models

**Caveats:**
- SpeechT5 is serviceable but clearly first-gen neural TTS, not ElevenLabs quality
- English-centric — Norwegian output would be rough
- Voice selection via embedding files, not named presets — UX is awkward
- Small model (~few hundred MB), fast on CPU

**Verdict:** Clean API surface, completes the OpenAI compatibility story. Worth adding
once STT (Whisper) is proven. Low priority until then.

---

## Spinoff project idea: Ollama API wrapper for any OpenAI-compatible server

**Not part of NoLlama.** Separate repo if pursued.

### Honest assessment (verified 2026-04-13)

Initial motivation was "tools that speak Ollama but not OpenAI." This
turned out to be weaker than hoped:

- **Major tools support both.** Continue.dev, Zed, Cursor, Open WebUI,
  VS Code extensions — all take custom OpenAI-compatible base URLs.
- **Walled-garden tools don't help either way.** Android Studio's AI
  (Gemini-only) and JetBrains AI Assistant (their own backend) won't
  accept any local endpoint, Ollama or OpenAI.
- **Genuinely Ollama-only tools are niche**: Llama Coder (VS Code),
  Enchanted (macOS), Maid, various mobile clients. Real but small audience.

### The narrower valid case

- Protocol quirks: `/api/tags` vs `/v1/models` have different shapes.
  Some tools nominally "OpenAI" still call Ollama-specific endpoints
  (`/api/show` for metadata).
- Ollama NDJSON vs OpenAI SSE framing trips tools tested against only one.
- Dev ecosystems built around `ollama` CLI expect a real Ollama server.

### If pursued

| Ollama endpoint | Upstream call | Translation |
|---|---|---|
| `GET /api/tags` | `GET /v1/models` | reshape model list |
| `POST /api/show` | `GET /v1/models` | pick one, reshape |
| `POST /api/chat` | `POST /v1/chat/completions` | SSE → NDJSON |
| `POST /api/generate` | `POST /v1/chat/completions` | wrap prompt as user msg |
| `POST /api/pull`/`delete`/`copy` | stub — return success | |

One Python file, single config (`--upstream http://ovms:8080 --port 11434`).
Reusable chunks already exist in nollama.py's `ollama_app` and
`_ollama_stream_*` functions.

**Verdict**: Interesting afternoon project, but the audience is smaller
than the initial Reddit comment suggested. Not urgent.
