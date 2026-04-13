# TODO

## Proxy mode: wrap OVMS (or any OpenAI-compatible backend)

Add `--upstream <url>` flag. In proxy mode, NoLlama doesn't load models
locally — it forwards generation requests to an upstream OpenAI-compatible
server (OVMS, llama.cpp server, vLLM, etc.) and keeps its own value-add:

- Ollama API translation (upstream only needs OpenAI)
- Built-in web UI
- Device badge / health polling (via upstream's /v1/models)

Architecture: replace DeviceSlot.generate_* with HTTP proxy calls. Router
becomes trivial (only one upstream). Cancel endpoint proxies through.

Use case: someone running OVMS in a datacenter wants Ollama API + chat UI
without rewriting their inference stack. NoLlama becomes the lightweight
Ollama-compatible frontend for any OpenAI backend.
