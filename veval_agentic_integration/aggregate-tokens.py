#!/usr/bin/env python3
#=========================================================================
# aggregate-tokens.py [build_dir ...]
#=========================================================================
#
# Walks a VerilogEval build directory after an agentic run, collects
# every *.tokens.json sidecar written by sv-generate-agentic, and
# reports:
#
#   - total prompt / completion / total tokens
#   - per-problem and per-iteration breakdown
#   - pass rate and iteration distribution
#   - EXTRAPOLATED cost for paid models, using the free-tier token
#     counts as the estimate basis
#
# This is the deliverable for estimating Sonnet 4.6 (etc.) API spend
# before committing to a paid run.
#
# Usage:
#   python3 aggregate-tokens.py build_spec-to-rtl_gemini-2.0-flash_shots0_n1
#
#=========================================================================

import glob
import json
import os
import sys

#-------------------------------------------------------------------------
# Pricing table (USD per 1M tokens).
# Verified against Anthropic published rates, May 2026.
# Standard (non-batch) rates. Output tokens cost 5x input across all
# current Claude models.
#
# The Batch API gives a flat 50% discount on both input and output and
# processes asynchronously within 24h — a 156-problem benchmark sweep
# is exactly the kind of workload that fits batch, so a batch estimate
# is shown alongside the standard one.
#-------------------------------------------------------------------------

PRICING = {
    # model              : (input_per_1M, output_per_1M)
    "gemini-2.0-flash"   : (0.00,  0.00),   # free tier
    "claude-haiku-4-5"   : (1.00,  5.00),   # verified May 2026
    "claude-sonnet-4-6"  : (3.00, 15.00),   # verified May 2026
    "claude-opus-4-7"    : (5.00, 25.00),   # verified May 2026
}

# Batch API discount factor (applies to both input and output).
BATCH_DISCOUNT = 0.50


def collect_sidecars(build_dir):
    """Find all *.tokens.json files under a build directory."""
    pattern = os.path.join(build_dir, "**", "*.tokens.json")
    return sorted(glob.glob(pattern, recursive=True))


def load_records(sidecar_paths):
    records = []
    for path in sidecar_paths:
        try:
            with open(path) as f:
                records.append(json.load(f))
        except (json.JSONDecodeError, OSError) as e:
            print(f"[WARN] could not read {path}: {e}", file=sys.stderr)
    return records


def summarize(records):
    n = len(records)
    if n == 0:
        return None

    total_prompt = sum(r["cumulative"]["prompt_tokens"] for r in records)
    total_comp   = sum(r["cumulative"]["completion_tokens"] for r in records)
    total_all    = sum(r["cumulative"]["total_tokens"] for r in records)
    total_calls  = sum(r["cumulative"]["num_calls"] for r in records)

    passed = sum(1 for r in records if r.get("passed"))
    testable = sum(1 for r in records if r.get("can_test"))

    iters = [r.get("iterations_used", 0) for r in records]
    iters_sorted = sorted(iters)
    median_iters = iters_sorted[n // 2] if n else 0

    return {
        "num_problems": n,
        "passed": passed,
        "testable": testable,
        "pass_rate": passed / n if n else 0.0,
        "total_prompt_tokens": total_prompt,
        "total_completion_tokens": total_comp,
        "total_tokens": total_all,
        "total_llm_calls": total_calls,
        "avg_tokens_per_problem": total_all / n if n else 0,
        "avg_calls_per_problem": total_calls / n if n else 0,
        "max_iterations": max(iters) if iters else 0,
        "median_iterations": median_iters,
        "avg_iterations": sum(iters) / n if n else 0,
    }


def extrapolate_cost(summ, model):
    """Estimate cost if the SAME token volume ran on a paid model."""
    if model not in PRICING:
        return None
    in_rate, out_rate = PRICING[model]
    cost_in  = summ["total_prompt_tokens"]     / 1_000_000 * in_rate
    cost_out = summ["total_completion_tokens"] / 1_000_000 * out_rate
    return cost_in + cost_out


def main():
    build_dirs = sys.argv[1:]
    if not build_dirs:
        build_dirs = ["."]

    for build_dir in build_dirs:
        print(f"\n{'='*70}")
        print(f"Build directory: {build_dir}")
        print('='*70)

        sidecars = collect_sidecars(build_dir)
        if not sidecars:
            print("  No *.tokens.json sidecars found. "
                  "Was this run done with sv-generate-agentic?")
            continue

        records = load_records(sidecars)
        summ = summarize(records)
        if summ is None:
            print("  No valid token records.")
            continue

        print(f"\n  Problems evaluated : {summ['num_problems']}")
        print(f"  Testable (had ref) : {summ['testable']}")
        print(f"  Passed             : {summ['passed']}")
        print(f"  Pass rate          : {summ['pass_rate']*100:.1f}%")
        print()
        print(f"  Total LLM calls    : {summ['total_llm_calls']}")
        print(f"  Avg calls/problem  : {summ['avg_calls_per_problem']:.2f}")
        print(f"  Iterations         : avg {summ['avg_iterations']:.2f}, "
              f"median {summ['median_iterations']}, "
              f"max {summ['max_iterations']}")
        print()
        print(f"  Prompt tokens      : {summ['total_prompt_tokens']:,}")
        print(f"  Completion tokens  : {summ['total_completion_tokens']:,}")
        print(f"  Total tokens       : {summ['total_tokens']:,}")
        print(f"  Avg tokens/problem : {summ['avg_tokens_per_problem']:,.0f}")

        # Cost extrapolation
        print()
        print("  Cost extrapolation (same token volume on paid models):")
        print("  " + "-"*64)
        print(f"    {'model':22s} {'standard':>12s} {'batch -50%':>12s}")
        print("  " + "-"*64)
        for model in PRICING:
            cost = extrapolate_cost(summ, model)
            if cost is None:
                continue
            rate = PRICING[model]
            if rate == (0.0, 0.0):
                print(f"    {model:22s} {'free tier':>12s} {'—':>12s}")
            else:
                batch_cost = cost * BATCH_DISCOUNT
                print(f"    {model:22s} ${cost:>10.2f} ${batch_cost:>10.2f}")
        print("  " + "-"*64)
        print()
        print("  Extrapolation basis: assumes a paid model would consume the")
        print("  SAME token volume as this free-tier run. A stronger model")
        print("  may converge in fewer iterations (less tokens) or attempt")
        print("  harder problems (more tokens) — treat as an order-of-")
        print("  magnitude estimate, not a precise quote.")
        print()
        print("  Prices verified May 2026. Batch API = 50% off, async <24h,")
        print("  well-suited to a one-shot benchmark sweep.")

        # Per-problem detail dump (CSV-friendly)
        detail_path = os.path.join(build_dir, "token_detail.csv")
        with open(detail_path, "w") as f:
            f.write("problem,passed,iterations,prompt_tokens,"
                    "completion_tokens,total_tokens,num_calls\n")
            for r in sorted(records, key=lambda x: x.get("problem", "")):
                c = r["cumulative"]
                f.write(f"{r.get('problem','?')},{r.get('passed',False)},"
                        f"{r.get('iterations_used',0)},"
                        f"{c['prompt_tokens']},{c['completion_tokens']},"
                        f"{c['total_tokens']},{c['num_calls']}\n")
        print(f"  Per-problem detail written to: {detail_path}")


if __name__ == "__main__":
    main()
