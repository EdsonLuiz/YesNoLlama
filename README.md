# NoLlama

**Local LLM server for the full Intel stack.** NPU, ARC iGPU, ARC discrete, CPU.
OpenAI + Ollama APIs. One server, every Intel device.

No NVIDIA required. No Ollama install. No llama.cpp. **No problem.**

Runs on Intel Core Ultra laptops (NPU + ARC iGPU), desktops with ARC
discrete GPUs (A770, B580), or any Intel CPU. Automatically detects your
hardware, picks the best device, and exposes both OpenAI and Ollama
compatible APIs — so any client that speaks to either just works.

## Quick start

```powershell
.\install.ps1
.\start.ps1
```

That's it. `install.ps1` detects your hardware, lets you pick a model,
downloads it, and generates `start.ps1`. The launcher waits for the
model to load (with a progress indicator), then opens the built-in
chat UI in your browser at http://localhost:8000.

## What it does

- **OpenAI API** (`/v1/chat/completions`) — works with any OpenAI client, OpenWebUI, etc.
- **Ollama API** (`/api/chat`, `/api/generate`) — works with Ollama clients, OpenWebUI Ollama mode, etc.
- **Auto-detects** NPU, ARC iGPU, ARC discrete, CPU — picks the best available
- **VLM support** — send images via base64 or `file://` URIs for vision models
- **Streaming** — token-by-token for text chat, with collapsible thinking blocks
- **Dual device** — NPU for chat + GPU for vision, simultaneously
- **Built-in web UI** — chat, image drop zone, model selector, dark theme
- **Model menu** — curated list of verified models, no conversion nightmares

## Web UI

The server includes a built-in chat interface at http://localhost:8000.
No separate install, no Docker, no Node.js.

A native Windows GUI is planned to replace the browser-based UI.

Features:
- Streaming chat with tokens appearing in real-time
- Collapsible "Thinking..." blocks (Qwen3 reasoning models)
- Drag-and-drop / paste images for VLM queries
- Model selector showing loaded models and their devices
- Device badge on each response (`[NPU 1.2s]`, `[GPU 2.8s]`)
- Dark theme
- Keyboard shortcuts: Enter to send, Shift+Enter for newline,
  Ctrl+V to paste images, Ctrl+N for new chat, Escape to cancel

## Device support

| Device | Examples | What it does | Streaming? |
|---|---|---|---|
| NPU (Intel AI Boost) | Core Ultra 7 258V | Text chat via LLMPipeline | Yes |
| ARC iGPU | ARC 140V (Core Ultra) | Vision + text, or bigger LLM | VLM: no, LLM: yes |
| ARC discrete | A770, B580 | Same as iGPU, more VRAM for larger models | VLM: no, LLM: yes |
| CPU | Any Intel CPU | Fallback for everything | Yes (slowly) |

### Dual mode (NPU + GPU)

When you have both, text requests go to the NPU (streaming) and image
requests go to the GPU (VLM). Or put a bigger LLM on the GPU for
smarter chat. The routing is automatic — send a request and the right
device handles it.

```
POST /v1/chat/completions
  "What is the capital of Norway?"  --> NPU (streaming)
  [image + "What vehicle is this?"] --> GPU (VLM)
```

## Usage

```powershell
# Auto-detect (picks best device)
python nollama.py

# Force a specific device
python nollama.py --device NPU
python nollama.py --device GPU
python nollama.py --device CPU

# Dual mode: NPU chat + GPU vision
python nollama.py --model-dir model --gpu-model-dir gpu-model

# Different port
python nollama.py --port 9000
```

## API

Standard OpenAI `/v1/chat/completions`. Works with any OpenAI client.

### Text chat

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}'
```

### Image (VLM, requires GPU with vision model)

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages":[{"role":"user","content":[
      {"type":"text","text":"What is in this image?"},
      {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}
    ]}]
  }'
```

### Local file shortcut

When client and server are on the same machine, skip base64:

```python
{"type": "image_url", "image_url": {"url": "file:///C:/path/to/image.jpg"}}
```

**Note:** `file://` URIs only work locally. Remote clients must use base64.

### Streaming

```bash
curl -N http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Tell me a story"}],"stream":true}'
```

### Other endpoints

- `GET /health` — device status, model names, readiness
- `GET /v1/models` — list loaded models (OpenAI format)

### Response headers

Every response includes `X-Device` and `X-Model` headers so you can
see which device handled it:

```
X-Device: NPU
X-Model: qwen3-8b
```

## Using with the openai Python package

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8000/v1", api_key="unused")
resp = client.chat.completions.create(
    model="qwen3-8b",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=True,
)
for chunk in resp:
    print(chunk.choices[0].delta.content or "", end="")
```

## Ollama API

NoLlama also serves a full Ollama-compatible API on port 11434 (the
Ollama default). Any tool or client that talks to Ollama works without
modification — it thinks it's talking to a real Ollama instance.

Supported endpoints:

- `POST /api/chat` — chat with streaming (newline-delimited JSON)
- `POST /api/generate` — single-turn completion
- `GET /api/tags` — list models
- `POST /api/show` — model info

```bash
curl http://localhost:11434/api/chat \
  -d '{"model":"qwen3-8b-int4-cw","messages":[{"role":"user","content":"Hello!"}]}'
```

Disable with `--ollama-port 0` if you don't need it or port 11434 is taken.

## Using with OpenWebUI

OpenWebUI can connect via either API:

**OpenAI mode** (recommended):

| Field | Value |
|---|---|
| Base URL | `http://host.docker.internal:8000/v1` |
| API Key | `not-needed` |

**Ollama mode** (no config needed if NoLlama runs on default port):

| Field | Value |
|---|---|
| Ollama Base URL | `http://host.docker.internal:11434` |

## Models

`install.ps1` shows a curated menu of models known to work on Intel
hardware. All pre-exported models are download-only (no conversion).
The menu is defined in `models.json` — add entries when new models
are verified.

### NPU models (chat)

| Model | Size | Notes |
|---|---|---|
| Qwen3 8B (INT4-CW) | ~5 GB | Recommended. Best quality. |
| Phi 3.5 Mini (INT4-CW) | ~2 GB | Smaller, faster. |
| DeepSeek R1 Distill 7B (INT4-CW) | ~4 GB | Reasoning. |
| DeepSeek R1 Distill 1.5B (INT4-CW) | ~1 GB | Testing only. |
| Mistral 7B v0.3 (INT4-CW) | ~4 GB | General purpose. |

### GPU vision models

| Model | Size | Notes |
|---|---|---|
| Gemma 3 4B Vision (INT4) | ~3 GB | Fast, good quality. |
| Gemma 3 12B Vision (INT4) | ~7 GB | Excellent quality. |
| Qwen2.5-VL 7B (INT4) | ~5 GB | Proven architecture. |
| InternVL2 4B (INT4) | ~3 GB | Good small VLM. |

### GPU large LLMs (smarter than NPU)

| Model | Size | Notes |
|---|---|---|
| Qwen3 14B (INT4) | ~8 GB | Great reasoning. |
| Qwen3 30B-A3B MoE (INT4) | ~17 GB | 30B brain, 3B speed. |
| Phi 4 (INT4) | ~8 GB | Strong reasoning. |
| Phi 4 Reasoning (INT4) | ~8 GB | Chain-of-thought. |

## How it works

The server auto-detects your model type (VLM or LLM) from
`config.json` and loads the right OpenVINO GenAI pipeline:

- **VLMPipeline** for vision models — handles images + text
- **LLMPipeline** for text models — handles chat with streaming

In dual mode, both pipelines run on separate devices with separate
locks. They don't interfere with each other.

> **Future simplification:** OpenVINO GenAI may unify VLMPipeline and
> LLMPipeline into a single pipeline that handles both text and images.
> When that lands, the dual-pipeline detection and routing logic in
> NoLlama can be collapsed into one code path.

## Files

```
nollama.py       The server
install.ps1         Setup wizard
start.ps1           Auto-generated launcher (after install)
models.json         Curated model registry
model/              Primary model (NPU or GPU)
gpu-model/          Secondary GPU model (dual mode)
venv/               Python virtual environment
```

`model/`, `gpu-model/`, `venv/`, and `start.ps1` are gitignored.
The repo is pure code.

## Requirements

- Python 3.10+
- OpenVINO 2026.1+ with openvino-genai
- At least one of:
  - Intel Core Ultra (NPU + ARC iGPU)
  - Intel ARC discrete GPU (A770, B580, etc.)
  - Any Intel CPU (slower, but works)
- ~1-17 GB disk per model

## A note about small models

During initial NPU testing with DeepSeek R1 1.5B, we asked:
"What is the capital of Norway?"

The model's response:

> "I need to figure out the capital of Norway. I know it's a country
> in Norway. I remember that Norway is a small island..."

Norway is, in fact, not a small island.

Or *is* it? To paraphrase the greatest detective of all time, Ford
Fairlane: "...an island in an ocean of diarrhea."

The point: 1.5B parameter models are for testing the plumbing, not
for geography. Use Qwen3-8B or larger for actual chat. The small
models will catch up — they're getting smarter every month.

## License

MIT

## Author

Tommy Leonhardsen
