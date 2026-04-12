# TODO

- Create animated GIF of the web UI in use (for README)

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
