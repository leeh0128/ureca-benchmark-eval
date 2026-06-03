#!/usr/bin/env bash
#=========================================================================
# run-batch-eval.sh — Drive a VerilogEval v2 agentic batch evaluation
#=========================================================================
#
# Runs the VerilogEval v2 harness with the agentic generator
# (sv-generate-agentic) instead of the stock single-shot sv-generate,
# using a free-tier model (Gemini 2.0 Flash by default).
#
# v2 of this script — hardened against container environment leaks.
# The IIC-OSIC-TOOLS container exports variables like EXAMPLES=/foss/...
# which previously clobbered the script's config. This version HARD-SETS
# all config below and does NOT inherit those names from the environment.
# To change a setting, edit the CONFIG block directly.
#
# USAGE:
#   ./run-batch-eval.sh [smoke|full] [num_problems_for_smoke]
#
#=========================================================================

set -u

#=========================================================================
# CONFIG — edit these directly. Do NOT rely on environment variables;
# the container exports some of these names with unrelated values.
#=========================================================================

VERILOG_EVAL_DIR="/foss/designs/URECA/verilog-eval-mine"
SCRIPTS_DIR="/foss/designs/URECA/veval_agentic_integration"

# VerilogEval requires iverilog/vvp v12. The system ships v13 which
# rejects forward references in VerilogEval's testbenches (tb_mismatch
# is declared after first use on line 62). Prepend the locally-built
# v12 to PATH so both `iverilog` and `vvp` resolve to v12 in both
# the harness Makefile recipes AND in sv-generate-agentic's internal
# iverilog calls.
if [[ -x "$HOME/local/bin/iverilog" && -x "$HOME/local/bin/vvp" ]]; then
  export PATH="$HOME/local/bin:$PATH"
fi

# Model: gemini-2.0-flash was RETIRED by Google in March 2026.
# Supported models in this script:
#   gemini-2.5-flash       ~250 requests/day  — free, smoke test
#   gemini-2.5-flash-lite  ~1000 requests/day — free, full sweep
#   claude-sonnet-4-6      paid, Tier-1 cap 50 RPM / 30K input TPM
#   claude-opus-4-7        paid, Tier-1 cap 50 RPM
#   claude-haiku-4-5       paid, cheaper than Sonnet
#
# Suggested EVAL_RPM by model:
#   gemini-*               8     (free-tier ~10 RPM cap)
#   claude-sonnet/opus-*   4     (Tier-1 30K input TPM / ~7K avg per call)
#   claude-haiku-*         8     (Tier-1 has more headroom for Haiku)
EVAL_MODEL="claude-sonnet-4-6"
EVAL_TASK="spec-to-rtl"
EVAL_TEMPERATURE="0"
EVAL_TOP_P="0.01"
EVAL_EXAMPLES="0"          # in-context examples, integer 0-4
EVAL_MAX_ITERS="5"         # agentic feedback-loop iterations
EVAL_RPM="4"               # requests/min — see model guide above
EVAL_JOBS="1"              # make -j parallelism; KEEP 1 for free tier

# URECA lint-driven feedback. Set to the path of ureca_designs/ to enable
# the URECA Makefile (make lint + make report) on every iteration, in
# addition to iverilog functional sim. Leave blank to disable (the agent
# falls back to iverilog-only feedback, identical to the prior runs).
URECA_DIR="/foss/designs/URECA/ureca_designs"

#=========================================================================
# (end of CONFIG)
#=========================================================================

MODE="${1:-smoke}"
SMOKE_N="${2:-5}"

echo "=================================================================="
echo " URECA — VerilogEval v2 Agentic Batch Evaluation"
echo "=================================================================="
echo " Mode        : $MODE"
echo " Model       : $EVAL_MODEL"
case "$EVAL_MODEL" in
  claude-*|gpt-*|openai-*)
    echo "             ** PAID MODEL — this run will incur API charges **"
    ;;
esac
echo " Task        : $EVAL_TASK"
echo " Examples    : $EVAL_EXAMPLES"
echo " Max iters   : $EVAL_MAX_ITERS"
echo " Rate limit  : $EVAL_RPM req/min"
echo " Harness dir : $VERILOG_EVAL_DIR"
echo " Scripts dir : $SCRIPTS_DIR"
IVERILOG_PATH=$(command -v iverilog 2>/dev/null || echo "not found")
IVERILOG_VER=$(iverilog -V 2>/dev/null | head -1 | awk '{print $4}' || echo "?")
echo " iverilog    : $IVERILOG_PATH ($IVERILOG_VER)"
if [[ "$IVERILOG_VER" != "12.0" ]]; then
  echo "             ^^^ WARNING: VerilogEval requires v12.0. Current version may fail."
fi
if [[ -n "$URECA_DIR" ]]; then
  echo " URECA lint  : ENABLED ($URECA_DIR)"
else
  echo " URECA lint  : disabled (iverilog-only feedback)"
fi
echo "------------------------------------------------------------------"

#-------------------------------------------------------------------------
# Validate config — catch bad values early
#-------------------------------------------------------------------------

# EXAMPLES must be a single digit 0-4. If the environment leaked a path
# into it, this catches it.
if ! [[ "$EVAL_EXAMPLES" =~ ^[0-4]$ ]]; then
  echo "ERROR: EVAL_EXAMPLES must be an integer 0-4, got: '$EVAL_EXAMPLES'"
  echo "Edit the CONFIG block at the top of this script."
  exit 1
fi

if [[ ! -d "$VERILOG_EVAL_DIR" ]]; then
  echo "ERROR: VERILOG_EVAL_DIR does not exist: $VERILOG_EVAL_DIR"
  echo "Edit the CONFIG block to point at your writable verilog-eval copy."
  exit 1
fi

CONFIGURE="$VERILOG_EVAL_DIR/configure"
if [[ ! -x "$CONFIGURE" ]]; then
  echo "ERROR: configure not found or not executable: $CONFIGURE"
  ls -la "$VERILOG_EVAL_DIR" 2>/dev/null | head -20
  exit 1
fi

# Pick the right API key check by model family.
case "$EVAL_MODEL" in
  claude-*)
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
      echo "ERROR: ANTHROPIC_API_KEY is not set."
      echo "  export ANTHROPIC_API_KEY=sk-ant-..."
      echo "  Get one at https://console.anthropic.com"
      exit 1
    fi
    # Check the SDK is installed since we'll need it at runtime
    python3 -c "import anthropic" 2>/dev/null || {
      echo "ERROR: python 'anthropic' package not installed."
      echo "  Run: pip install anthropic"
      exit 1
    }
    ;;
  gemini-*)
    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
      echo "ERROR: GEMINI_API_KEY is not set."
      echo "  export GEMINI_API_KEY=your_key"
      exit 1
    fi
    ;;
  *)
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
      echo "ERROR: OPENAI_API_KEY is not set for model $EVAL_MODEL."
      exit 1
    fi
    ;;
esac

if ! command -v iverilog >/dev/null 2>&1; then
  echo "ERROR: iverilog not found on PATH."
  exit 1
fi

if [[ ! -x "$SCRIPTS_DIR/sv-generate-agentic" ]]; then
  echo "ERROR: $SCRIPTS_DIR/sv-generate-agentic missing or not executable."
  echo "  chmod +x $SCRIPTS_DIR/sv-generate-agentic"
  exit 1
fi

if [[ ! -f "$SCRIPTS_DIR/aggregate-tokens.py" ]]; then
  echo "ERROR: $SCRIPTS_DIR/aggregate-tokens.py missing."
  exit 1
fi

python3 -c "import openai" 2>/dev/null || {
  echo "ERROR: python 'openai' package not installed. Run: pip install openai"
  exit 1
}

# Confirm the verilog-eval copy is actually writable (configure + make
# both write into it).
if ! touch "$VERILOG_EVAL_DIR/_writetest" 2>/dev/null; then
  echo "ERROR: $VERILOG_EVAL_DIR is not writable by this user."
  echo "Make a writable copy you own and update VERILOG_EVAL_DIR."
  exit 1
fi
rm -f "$VERILOG_EVAL_DIR/_writetest"

# If URECA lint is enabled, validate that workspace is usable.
if [[ -n "$URECA_DIR" ]]; then
  if [[ ! -d "$URECA_DIR" ]]; then
    echo "ERROR: URECA_DIR does not exist: $URECA_DIR"
    echo "Set URECA_DIR='' in CONFIG to disable URECA lint, or fix the path."
    exit 1
  fi
  if [[ ! -f "$URECA_DIR/Makefile" ]]; then
    echo "ERROR: $URECA_DIR/Makefile missing — not a URECA workspace?"
    exit 1
  fi
  if ! touch "$URECA_DIR/rtl/_writetest" 2>/dev/null; then
    echo "ERROR: $URECA_DIR/rtl/ is not writable by this user."
    echo "URECA lint stages candidate.sv into rtl/ each iteration."
    exit 1
  fi
  rm -f "$URECA_DIR/rtl/_writetest"
fi

#-------------------------------------------------------------------------
# Build directory naming
#-------------------------------------------------------------------------

MODE_SUFFIX="agentic"
[[ "$EVAL_MAX_ITERS" == "1" ]] && MODE_SUFFIX="singleshot"
# If URECA lint is on AND we're iterating, tag the build dir distinctly
# so single-channel-agentic and lint+sim-agentic runs are side by side.
if [[ -n "$URECA_DIR" && "$EVAL_MAX_ITERS" != "1" ]]; then
  MODE_SUFFIX="agentic_lint"
fi
BUILD_NAME="build_${EVAL_TASK}_${EVAL_MODEL}_shots${EVAL_EXAMPLES}_n1_${MODE_SUFFIX}"
if [[ "$MODE" == "smoke" ]]; then
  BUILD_NAME="${BUILD_NAME}_smoke${SMOKE_N}"
fi
BUILD_DIR="$VERILOG_EVAL_DIR/$BUILD_NAME"

echo " Build dir   : $BUILD_DIR"
echo "------------------------------------------------------------------"

#-------------------------------------------------------------------------
# Configure the harness
#-------------------------------------------------------------------------

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || exit 1

echo "[1/4] Configuring harness..."
"$CONFIGURE" \
  --with-task="$EVAL_TASK" \
  --with-model="$EVAL_MODEL" \
  --with-examples="$EVAL_EXAMPLES" \
  --with-samples=1 \
  --with-temperature="$EVAL_TEMPERATURE" \
  --with-top-p="$EVAL_TOP_P" \
  > configure.log 2>&1

if [[ ! -f Makefile ]]; then
  echo "ERROR: configure did not produce a Makefile. configure.log tail:"
  tail -25 configure.log
  exit 1
fi

# Belt-and-suspenders: VerilogEval's Makefile uses bash-only syntax
# (${PIPESTATUS[0]}, [[ ]]) in its test recipe. On this container
# /bin/sh is dash, which errors with "Bad substitution". Passing
# SHELL=/bin/bash on the make command line handles it, but if the
# Makefile sets SHELL internally that would override us — so we also
# inject an explicit SHELL line at the top of the generated Makefile.
if ! grep -qE '^SHELL[[:space:]]*[:?]?=[[:space:]]*/bin/bash' Makefile; then
  sed -i '1i SHELL := /bin/bash' Makefile
  echo "       (patched Makefile to use /bin/bash for recipes)"
fi

#-------------------------------------------------------------------------
# Smoke mode — trim problems.mk to the first N problems
#-------------------------------------------------------------------------

if [[ "$MODE" == "smoke" ]]; then
  echo "[2/4] Smoke mode — trimming to first $SMOKE_N problems..."
  if [[ -f problems.mk ]]; then
    # problems.mk lists one problem per line, backslash-continued:
    #   problems = \
    #     Prob001_zero \
    #     Prob002_m2014_q4i \
    # Extract the ProbNNN_* tokens directly rather than parsing the
    # line-continuation structure (the header line is just "problems = \").
    mapfile -t ALL_PROBS < <(grep -oE 'Prob[0-9]+_[A-Za-z0-9_]+' problems.mk)
    if [[ ${#ALL_PROBS[@]} -eq 0 ]]; then
      echo "ERROR: no problems found in problems.mk — cannot trim."
      exit 1
    fi
    SUBSET=("${ALL_PROBS[@]:0:$SMOKE_N}")
    # Rewrite problems.mk in the backslash-continued format the
    # Makefile expects.
    {
      echo "problems = \\"
      for p in "${SUBSET[@]}"; do
        echo "  $p \\"
      done
      echo ""
    } > problems.mk
    echo "       Problems (${#SUBSET[@]}): ${SUBSET[*]}"
  else
    echo "WARNING: problems.mk not found; running full set."
  fi
else
  echo "[2/4] Full mode — all problems."
fi

#-------------------------------------------------------------------------
# Run the evaluation
#-------------------------------------------------------------------------

echo "[3/4] Running evaluation..."
echo "      Each problem may issue up to $EVAL_MAX_ITERS LLM calls."
echo "      At $EVAL_RPM req/min, budget time accordingly."
echo ""

START_TS=$(date +%s)

make -j"$EVAL_JOBS" \
  SHELL=/bin/bash \
  GENERATE_VERILOG="$SCRIPTS_DIR/sv-generate-agentic" \
  GENERATE_FLAGS="--model=$EVAL_MODEL --task=$EVAL_TASK --examples=$EVAL_EXAMPLES --temperature=$EVAL_TEMPERATURE --top-p=$EVAL_TOP_P --max-iters=$EVAL_MAX_ITERS --rpm=$EVAL_RPM ${URECA_DIR:+--ureca-dir=$URECA_DIR}" \
  2>&1 | tee make.log

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo ""
echo "      Evaluation wall time: $((ELAPSED / 60))m $((ELAPSED % 60))s"

#-------------------------------------------------------------------------
# Analyze
#-------------------------------------------------------------------------

echo "[4/4] Analyzing results..."
echo ""

if [[ -f summary.txt ]]; then
  echo "--- VerilogEval pass/fail summary ---"
  cat summary.txt
  echo ""
fi

echo "--- Token usage + cost extrapolation ---"
python3 "$SCRIPTS_DIR/aggregate-tokens.py" "$BUILD_DIR"

echo ""
echo "=================================================================="
echo " DONE."
echo " Build dir : $BUILD_DIR"
echo " Key files : summary.txt  summary.csv  token_detail.csv  make.log"
echo "=================================================================="

if [[ "$MODE" == "smoke" ]]; then
  echo ""
  echo " Smoke run complete. If results look sane, run the full sweep:"
  echo "   ./run-batch-eval.sh full"
fi