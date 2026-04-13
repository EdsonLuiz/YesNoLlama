# TODO

- Create animated GIF of the web UI in use (for README)

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

## Benchmark: NPU vs GPU vs CPU

Compare identical workloads across all three devices. Methodology:
- Warm up each device first (discard warmup run)
- Run 5 tests per workload per device
- Discard earlier outliers if present, average the rest
- Report tokens/sec and wall-clock time

### Test workloads

**Vision (VLM):** Two images of vehicles — "Is this the same vehicle?"

**LLM with thinking:** "Explain the Egyptian method for multiplication"
- With thinking enabled
- With no-think (direct answer)

**LLM simple:** "Count to 100"
- With thinking enabled
- With no-think (direct answer)
