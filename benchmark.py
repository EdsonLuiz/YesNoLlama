#!/usr/bin/env python3
"""NoLlama benchmark — compare workloads across devices.

Usage:
    python benchmark.py                     # use running server at localhost:8000
    python benchmark.py --url http://host:9000
    python benchmark.py --runs 3            # fewer runs for quick test

Runs the test suite from TODO.md:
  - VLM: "Is this the same vehicle?" (two images)
  - LLM thinking: "Explain the Egyptian method for multiplication"
  - LLM no-think: same prompt with no-think system message
  - LLM simple thinking: "Count to 100"
  - LLM simple no-think: same with no-think

Each test: 1 warmup + N runs. Discards outliers, reports averages.
"""

import argparse
import base64
import json
import os
import statistics
import sys
import time

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# VLM tests use 4 image paths: two pairs (same-vehicle, different-vehicle).
# Pass them via --same-1/--same-2/--diff-1/--diff-2 or set NOLLAMA_IMAGES_DIR
# and put matching files named same-1.jpg, same-2.jpg, diff-1.jpg, diff-2.jpg.
DEFAULT_IMAGES_DIR = os.environ.get("NOLLAMA_IMAGES_DIR", "")

NO_THINK_SYSTEM = "Respond directly and concisely. Do not use <think> blocks or internal reasoning."


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def image_to_b64(path):
    with open(path, "rb") as f:
        return "data:image/jpeg;base64," + base64.b64encode(f.read()).decode()


def stream_request(url, body):
    """Send a streaming chat request, return (full_text, token_count, elapsed)."""
    import urllib.request

    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url + "/v1/chat/completions",
        data=data,
        headers={"Content-Type": "application/json"},
    )

    t0 = time.perf_counter()
    tokens = 0
    full_text = ""

    with urllib.request.urlopen(req, timeout=300) as resp:
        buffer = ""
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            buffer += chunk.decode("utf-8", errors="replace")
            lines = buffer.split("\n")
            buffer = lines.pop()
            for line in lines:
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                if payload == "[DONE]":
                    continue
                try:
                    obj = json.loads(payload)
                    delta = obj.get("choices", [{}])[0].get("delta", {})
                    content = delta.get("content", "")
                    if content:
                        full_text += content
                        tokens += 1
                except json.JSONDecodeError:
                    pass

    elapsed = time.perf_counter() - t0
    return full_text, tokens, elapsed


def non_stream_request(url, body):
    """Send a non-streaming chat request, return (full_text, token_count, elapsed)."""
    import urllib.request

    body["stream"] = False
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url + "/v1/chat/completions",
        data=data,
        headers={"Content-Type": "application/json"},
    )

    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=300) as resp:
        result = json.loads(resp.read().decode())

    elapsed = time.perf_counter() - t0
    text = result.get("choices", [{}])[0].get("message", {}).get("content", "")
    tokens = len(text.split())  # rough estimate for non-streaming
    return text, tokens, elapsed


def get_models(url):
    """Fetch available models from the server."""
    import urllib.request
    req = urllib.request.Request(url + "/v1/models")
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
    return data.get("data", [])


def check_health(url):
    """Check server health."""
    import urllib.request
    req = urllib.request.Request(url + "/health")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode())


# ---------------------------------------------------------------------------
# Test definitions
# ---------------------------------------------------------------------------

def make_vlm_test(name, img1_path, img2_path, prompt):
    """VLM test: two images + question. Non-streaming (VLM limitation)."""
    def run(url, model):
        b64_1 = image_to_b64(img1_path)
        b64_2 = image_to_b64(img2_path)
        body = {
            "model": model,
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": b64_1}},
                {"type": "image_url", "image_url": {"url": b64_2}},
            ]}],
            "max_tokens": 512,
        }
        return non_stream_request(url, body)
    return name, run


def make_llm_test(name, prompt, no_think=False, max_tokens=4096, force_no_stream=False):
    """LLM test: text prompt, streaming unless force_no_stream."""
    def run(url, model):
        messages = []
        if no_think:
            messages.append({"role": "system", "content": NO_THINK_SYSTEM})
        messages.append({"role": "user", "content": prompt})
        body = {
            "model": model,
            "messages": messages,
            "stream": not force_no_stream,
            "max_tokens": max_tokens,
        }
        if force_no_stream:
            return non_stream_request(url, body)
        return stream_request(url, body)
    return name, run


def build_vlm_tests(same_1, same_2, diff_1, diff_2):
    return [
        make_vlm_test(
            "VLM: same vehicle?",
            same_1, same_2,
            "Are these two images of the same vehicle? Answer yes or no, then explain briefly.",
        ),
        make_vlm_test(
            "VLM: different vehicles?",
            diff_1, diff_2,
            "Are these two images of the same vehicle? Answer yes or no, then explain briefly.",
        ),
    ]

TESTS_GPU_TEXT = [
    make_llm_test(
        "GPU text: say hello (thinking)",
        "Say hello.",
        max_tokens=64,
        force_no_stream=True,
    ),
    make_llm_test(
        "GPU text: say hello (no-think)",
        "Say hello.",
        no_think=True,
        max_tokens=64,
        force_no_stream=True,
    ),
    make_llm_test(
        "GPU text: what is 2+2 (thinking)",
        "What is 2+2?",
        max_tokens=64,
        force_no_stream=True,
    ),
    make_llm_test(
        "GPU text: what is 2+2 (no-think)",
        "What is 2+2?",
        no_think=True,
        max_tokens=64,
        force_no_stream=True,
    ),
]

TESTS_LLM = [
    make_llm_test(
        "LLM: say hello (thinking)",
        "Say hello.",
        max_tokens=64,
    ),
    make_llm_test(
        "LLM: say hello (no-think)",
        "Say hello.",
        no_think=True,
        max_tokens=64,
    ),
    make_llm_test(
        "LLM: what is 2+2 (thinking)",
        "What is 2+2?",
        max_tokens=64,
    ),
    make_llm_test(
        "LLM: what is 2+2 (no-think)",
        "What is 2+2?",
        no_think=True,
        max_tokens=64,
    ),
]


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def run_test(url, model, test_name, test_fn, n_runs, warmup=True):
    """Run a test N times with optional warmup. Returns list of (tokens, elapsed, tps)."""
    results = []

    if warmup:
        print(f"    warmup...", end="", flush=True)
        try:
            _, _, w_elapsed = test_fn(url, model)
            print(f" {w_elapsed:.1f}s", flush=True)
        except Exception as e:
            print(f" FAILED: {e}")
            return []

    for i in range(n_runs):
        print(f"    run {i+1}/{n_runs}...", end="", flush=True)
        try:
            text, tokens, elapsed = test_fn(url, model)
            tps = tokens / elapsed if elapsed > 0 else 0
            results.append((tokens, elapsed, tps))
            print(f" {tokens} tok, {elapsed:.1f}s, {tps:.1f} tok/s", flush=True)
        except Exception as e:
            print(f" FAILED: {e}")

    return results


def discard_outliers(values):
    """Remove values more than 1.5 IQR from Q1/Q3."""
    if len(values) < 4:
        return values
    q1 = statistics.quantiles(values, n=4)[0]
    q3 = statistics.quantiles(values, n=4)[2]
    iqr = q3 - q1
    lo = q1 - 1.5 * iqr
    hi = q3 + 1.5 * iqr
    filtered = [v for v in values if lo <= v <= hi]
    return filtered if filtered else values


def summarize(results):
    """Compute averages after discarding outliers."""
    if not results:
        return None
    elapsed_vals = [r[1] for r in results]
    tps_vals = [r[2] for r in results]
    tok_vals = [r[0] for r in results]

    elapsed_clean = discard_outliers(elapsed_vals)
    tps_clean = discard_outliers(tps_vals)

    return {
        "runs": len(results),
        "runs_after_outliers": len(elapsed_clean),
        "avg_tokens": statistics.mean(tok_vals),
        "avg_elapsed": statistics.mean(elapsed_clean),
        "avg_tps": statistics.mean(tps_clean),
        "stdev_elapsed": statistics.stdev(elapsed_clean) if len(elapsed_clean) > 1 else 0,
        "stdev_tps": statistics.stdev(tps_clean) if len(tps_clean) > 1 else 0,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://localhost:8000",
                        help="Server URL (default: http://localhost:8000)")
    parser.add_argument("--runs", type=int, default=5,
                        help="Number of test runs per workload (default: 5)")
    parser.add_argument("--llm-only", action="store_true",
                        help="Skip VLM tests")
    parser.add_argument("--vlm-only", action="store_true",
                        help="Skip LLM tests")
    parser.add_argument("--images-dir", default=DEFAULT_IMAGES_DIR,
                        help="Directory with same-1/2.jpg, diff-1/2.jpg "
                             "(or set NOLLAMA_IMAGES_DIR)")
    parser.add_argument("--same-1", help="Path to 'same vehicle' image A")
    parser.add_argument("--same-2", help="Path to 'same vehicle' image B")
    parser.add_argument("--diff-1", help="Path to 'different vehicle' image A")
    parser.add_argument("--diff-2", help="Path to 'different vehicle' image B")
    args = parser.parse_args()

    # Resolve image paths (explicit flags win over --images-dir)
    def resolve(explicit, default_name):
        if explicit:
            return explicit
        if args.images_dir:
            return os.path.join(args.images_dir, default_name)
        return None

    same_1 = resolve(args.same_1, "same-1.jpg")
    same_2 = resolve(args.same_2, "same-2.jpg")
    diff_1 = resolve(args.diff_1, "diff-1.jpg")
    diff_2 = resolve(args.diff_2, "diff-2.jpg")

    # Only require images if VLM tests will actually run (--llm-only skips them)
    vlm_paths = (same_1, same_2, diff_1, diff_2)
    vlm_paths_ok = all(p and os.path.isfile(p) for p in vlm_paths)
    if not args.llm_only and not vlm_paths_ok:
        missing = [p or "(unset)" for p in vlm_paths if not p or not os.path.isfile(p)]
        print("ERROR: VLM images missing or unset:")
        for m in missing:
            print(f"  {m}")
        print("\nPass --images-dir, --same-1/--same-2/--diff-1/--diff-2, "
              "or set NOLLAMA_IMAGES_DIR.")
        print("Or use --llm-only to skip vision tests.")
        sys.exit(1)

    TESTS_VLM = build_vlm_tests(same_1, same_2, diff_1, diff_2) if vlm_paths_ok else []

    # Check server
    print(f"Connecting to {args.url}...")
    try:
        health = check_health(args.url)
    except Exception as e:
        print(f"ERROR: Cannot reach server: {e}")
        sys.exit(1)

    if health["status"] != "ready":
        print(f"ERROR: Server not ready (status: {health['status']})")
        sys.exit(1)

    models = get_models(args.url)
    print(f"Server ready. Models:")
    for m in models:
        print(f"  {m['id']}")
    print()

    # Find VLM and LLM models from health endpoint (has type info)
    vlm_model = None
    llm_model = None
    devices = health.get("devices", {})
    for dev_name, dev_info in devices.items():
        if dev_info.get("status") != "ready":
            continue
        model_id = f"{dev_info['model']}@{dev_name.upper()}"
        if dev_info.get("type") == "vlm":
            vlm_model = model_id
        elif dev_info.get("type") == "llm":
            llm_model = model_id

    all_results = {}

    # --- VLM tests ---
    if vlm_model and not args.llm_only:
        print(f"=== VLM Benchmark: {vlm_model} ===\n")
        for test_name, test_fn in TESTS_VLM:
            print(f"  [{test_name}]")
            results = run_test(args.url, vlm_model, test_name, test_fn, args.runs)
            summary = summarize(results)
            all_results[test_name] = summary
            if summary:
                print(f"    => avg: {summary['avg_elapsed']:.1f}s "
                      f"({summary['avg_tps']:.1f} tok/s), "
                      f"{summary['avg_tokens']:.0f} tokens\n")
            else:
                print(f"    => NO RESULTS\n")
    elif not args.llm_only:
        print("No VLM model found, skipping vision tests.\n")

    # --- GPU text tests (text-only queries to VLM, non-streaming) ---
    if vlm_model and not args.llm_only:
        print(f"=== GPU Text Benchmark: {vlm_model} ===\n")
        for test_name, test_fn in TESTS_GPU_TEXT:
            print(f"  [{test_name}]")
            results = run_test(args.url, vlm_model, test_name, test_fn, args.runs)
            summary = summarize(results)
            all_results[test_name] = summary
            if summary:
                print(f"    => avg: {summary['avg_elapsed']:.1f}s "
                      f"({summary['avg_tps']:.1f} tok/s), "
                      f"{summary['avg_tokens']:.0f} tokens\n")
            else:
                print(f"    => NO RESULTS\n")

    # --- LLM tests ---
    if llm_model and not args.vlm_only:
        print(f"=== LLM Benchmark: {llm_model} ===\n")
        for test_name, test_fn in TESTS_LLM:
            print(f"  [{test_name}]")
            results = run_test(args.url, llm_model, test_name, test_fn, args.runs)
            summary = summarize(results)
            all_results[test_name] = summary
            if summary:
                print(f"    => avg: {summary['avg_elapsed']:.1f}s "
                      f"({summary['avg_tps']:.1f} tok/s), "
                      f"{summary['avg_tokens']:.0f} tokens\n")
            else:
                print(f"    => NO RESULTS\n")
    elif not args.vlm_only:
        print("No LLM model found, skipping text tests.\n")

    # --- Summary table ---
    print("=" * 70)
    print(f"{'Test':<45} {'Time':>7} {'Tok/s':>7} {'Tokens':>7}")
    print("-" * 70)
    for name, s in all_results.items():
        if s:
            print(f"{name:<45} {s['avg_elapsed']:>6.1f}s {s['avg_tps']:>6.1f} {s['avg_tokens']:>7.0f}")
        else:
            print(f"{name:<45} {'FAILED':>7}")
    print("=" * 70)


if __name__ == "__main__":
    main()
