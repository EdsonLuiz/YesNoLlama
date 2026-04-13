# TODO

## Spinoff project: Ollama API wrapper for any OpenAI-compatible server

**Not part of NoLlama.** Separate repo — different scope (general-purpose
API shim, not Intel-specific) and different audience (ops teams running
OVMS, vLLM, llama.cpp-server, LM Studio, TGI, etc. who want Ollama
clients to just work).

Naming ideas: `ollamify`, `o2ollama`, `ollama-front`, `fakeollama`.

### What it does

Listens on port 11434 (Ollama's default). Translates Ollama API calls
to the upstream OpenAI-compatible server:

| Ollama endpoint | Upstream call | Translation |
|---|---|---|
| `GET /api/tags` | `GET /v1/models` | reshape model list |
| `POST /api/show` | `GET /v1/models` | pick one, reshape |
| `POST /api/chat` | `POST /v1/chat/completions` | SSE → NDJSON |
| `POST /api/generate` | `POST /v1/chat/completions` | wrap prompt as single user message |
| `POST /api/pull`/`delete`/`copy` | stub — return success | |

### Why it's simple

- No model loading, no OpenVINO, no device detection
- Pure HTTP proxy with light payload reshaping
- The SSE → NDJSON translation is ~30 lines (already done in nollama.py,
  just lift it out)
- Single config: `--upstream http://ovms:8080` and `--port 11434`

### Value

Any tool that only speaks Ollama (Continue.dev, Android Studio's AI
features, some IDE plugins, shell tools) suddenly works with any
OpenAI-compatible backend. Small, focused utility — one Python file,
Docker image, done.

### Reusable from NoLlama

The Ollama API layer in `nollama.py` (`ollama_app`, `_ollama_stream_chat`,
`_ollama_stream_generate`) is the prototype — it talks to local DeviceSlots
instead of an upstream, but the response-shaping code transfers directly.
