# VerilogEval v2 — Agentic Batch Evaluation Integration

This package plugs the URECA agentic feedback loop into the VerilogEval v2
benchmark harness, so all 156 problems can be evaluated with the
generate → test → feed-back-errors → regenerate loop instead of a single
LLM call.

It is built for the **free-tier first** plan: run on Gemini 2.0 Flash,
measure token usage per problem, then extrapolate what a paid model
(Sonnet 4.6, Opus 4.7) would cost before committing budget.

## Files

| File | Role |
|---|---|
| `sv-generate-agentic` | Drop-in replacement for VerilogEval's `sv-generate`. Runs the agentic feedback loop, writes the `.sv` sample, and logs token usage to a `.tokens.json` sidecar. |
| `aggregate-tokens.py` | Walks all token sidecars after a run, reports total usage, pass rate, iteration stats, and paid-model cost extrapolation. |
| `run-batch-eval.sh` | Orchestrates the whole thing — configures the harness, runs it, analyzes results. Has a `smoke` mode for a small test run first. |

## One-time setup

Inside the IIC-OSIC-TOOLS container:

```bash
# 1. VerilogEval v2 should already be cloned. Confirm location:
ls /foss/designs/URECA/verilog-eval

# 2. Copy the three integration files into the harness scripts/ dir
cp sv-generate-agentic aggregate-tokens.py /foss/designs/URECA/verilog-eval/scripts/
chmod +x /foss/designs/URECA/verilog-eval/scripts/sv-generate-agentic
chmod +x /foss/designs/URECA/verilog-eval/scripts/aggregate-tokens.py

# 3. Put run-batch-eval.sh wherever convenient (e.g. project root)
chmod +x run-batch-eval.sh

# 4. Install the one Python dependency
pip install openai

# 5. Get a free Gemini key at https://aistudio.google.com, then:
export GEMINI_API_KEY=your_key_here
```

## Running it

**Always smoke-test first.** A 5-problem run validates the whole flow
without burning quota:

```bash
./run-batch-eval.sh smoke 5
```

Check that `summary.txt` shows pass/fail results and the token
extrapolation prints. If it looks sane, run the full sweep:

```bash
./run-batch-eval.sh full
```

Tunable via environment variables (defaults in parentheses):

```bash
MODEL=gemini-2.0-flash   # the free-tier model
MAX_ITERS=5              # agentic feedback-loop iterations per problem
RPM=12                   # requests/min — keep under the free-tier cap
EXAMPLES=0               # in-context learning examples (0-4)
JOBS=1                   # make parallelism — KEEP 1 for free tier
```

Example with overrides:

```bash
MAX_ITERS=3 RPM=10 ./run-batch-eval.sh full
```

## How the integration works

VerilogEval v2's Makefile, for each problem, calls a generation script
to produce a `.sv` file, then compiles that file with the problem's
`_ref.sv` and `_test.sv` using Icarus Verilog and scores the result.
The Makefile doesn't care *how* the `.sv` is produced — it only needs
the script to accept a prompt file and an `--output` path.

`sv-generate-agentic` is a drop-in for that script. Instead of one LLM
call, it:

1. Assembles the spec-to-rtl prompt (same Question/Answer framing,
   `[BEGIN]`/`[DONE]` tags, and optional coding rules as the stock script).
2. Calls the model, extracts the code.
3. Compiles + simulates the candidate with iverilog.
4. On failure, appends the diagnostic output to the conversation and
   asks for a correction.
5. Repeats up to `--max-iters`.
6. Writes the final `.sv` and a `.tokens.json` sidecar.

`run-batch-eval.sh` swaps it in by overriding `GENERATE_VERILOG` on the
make command line — no edits to the harness Makefile itself.

## Rate limiting (important for free tier)

Gemini's free tier caps requests per minute. An agentic loop fires
multiple calls per problem, so the integration:

- Spaces calls with a requests-per-minute limiter (`--rpm`, default 12).
- Backs off exponentially on HTTP 429 / quota errors.
- Keeps `make -j` at 1 job for free-tier runs (parallel jobs would
  multiply the request rate and trip the limit).

For a paid run later, raise `RPM` and `JOBS` to parallelize.

## Methodology note — read before quoting pass rates

The feedback loop tests each candidate against the problem's **own
`_ref.sv` and `_test.sv`** — the same files VerilogEval uses for final
scoring. This is deliberate: it mirrors the URECA pipeline, where the
agent iterates against a testbench. But it has a consequence the
mentors should be aware of:

**The reported pass rate measures "can the agent satisfy this
testbench within N iterations," not "can it produce correct RTL in one
shot."** The agentic number is therefore not directly comparable to
the single-shot pass@1 figures in the VerilogEval paper. The fair
comparisons are:

- Agentic pass rate vs a **single-shot baseline run with the same
  model** (run the stock `sv-generate` for that), and
- Pass rate reported **alongside iteration count** (median / max), so
  the compute cost of the agentic gain is visible.

For the mentors' stated goal — *does the whole flow work end-to-end* —
this setup answers it directly. For a publishable pass-rate claim, add
the single-shot baseline run as the comparison point. This is worth
raising at the next meeting.

## What you get out

After a run, in the build directory:

| File | Contents |
|---|---|
| `summary.txt` | VerilogEval's pass/fail summary, human-readable |
| `summary.csv` | Per-problem failure codes (syntax error, timeout, etc.) |
| `token_detail.csv` | Per-problem token usage and iteration count |
| `make.log` | Full run log |
| `ProbXXX/*.tokens.json` | Raw per-problem token sidecars |

The token aggregation prints total usage and a cost table — what the
same token volume would cost on Haiku 4.5, Sonnet 4.6, and Opus 4.7,
at both standard and Batch-API (50% off) pricing.

## Cost expectation (rough)

A full 156-problem run with an average of ~3 iterations per problem
and ~1-2K tokens per call lands in the low hundreds of thousands of
tokens total. On the free tier that's $0. Extrapolated to Sonnet 4.6
that is typically a few dollars; to Opus 4.7, under ~$10 — small enough
that once the free-tier run validates the flow, a paid run for better
pass rates is easily justified. The aggregation script gives you the
exact figure from real measured usage rather than this estimate.

## Known limitations

- If a problem's `_ref.sv` / `_test.sv` can't be found, that problem
  falls back to single-shot generation (no feedback possible) and is
  flagged `can_test: false` in its sidecar.
- The pass detection in `run_iverilog_test` keys off VerilogEval's
  mismatch-count convention. If a problem's testbench reports results
  differently, that problem may misreport — check `make.log` if a
  smoke run shows unexpected results.
- Token counts come from the API's `usage` field. If a provider
  doesn't return usage, counts will be zero for that call (the
  aggregator still works, it just under-counts).
