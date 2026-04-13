# TODO

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
