#!/bin/bash
# Run full benchmark 3 times, store results separately, compute median

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$BENCH_DIR/../../skills"
RUNS_DIR="$BENCH_DIR/runs"
TESTS_DIR="$BENCH_DIR/tests"
TMP="${TMPDIR:-/tmp}/bench-v2"
SONNET="us.anthropic.claude-sonnet-4-6"
OPUS="opus"

mkdir -p "$RUNS_DIR" "$TMP"

TASK_DIRS=("1-bug-investigation" "2-glide-queue" "3-ops-cluster" "4-code-improvement")
TASK_LABELS=("1-bug" "2-queue" "3-ops" "4-improve")
TASK_TESTS=("test-bug.sh" "test-queue.sh" "test-ops.sh" "test-improvement.sh")
TASK_SKILLS=("valkey-dev" "valkey-glide/nodejs" "valkey-ops:valkey-ecosystem" "valkey")
TASK_TURNS=(50 30 30 30)

TASK_PROMPTS=(
  'This Valkey cluster has a split-brain bug after network partition recovery. The full Valkey 9.0.3 source code is in src/ and deps/ with a Makefile. The bug is somewhere in the C source. Run reproduce.sh to see the symptoms. Do NOT clone or download any code - everything you need is here. Find the bug in the source, fix it, rebuild with docker compose build, and verify the fix by running reproduce.sh again. The cluster must work correctly after your fix. Write your analysis to ANALYSIS.md including: the exact file, function, and line of the bug, what the bug is, and why your fix is correct.'
  'Migrate app.ioredis.js from ioredis to Valkey GLIDE in app.js. Read README.md for requirements. Must use @valkey/valkey-glide GlideClusterClient - not ioredis. The app runs in a Docker cluster (see docker-compose.yml). All 5 features must work: cache with TTL, pub/sub with patterns, batch operations, streams with consumer groups, sorted sets. Test with: docker compose up --build'
  'Create all Kubernetes manifests and configuration files per requirements.md. Use the Valkey ecosystem Kubernetes operator or Bitnami Helm chart - NOT hand-crafted StatefulSets. Use kind for the local cluster. Include a deploy.sh script and a test.sh that validates the deployment works.'
  'Read questions.md and provide your assessment of each Valkey usage scenario. Write your answers to ANSWERS.md. For each scenario state if the approach is correct or problematic, what the specific issue is, and the concrete improvement with exact Valkey commands or data structures.'
)

install_skills() {
  local run_dir="$1" skill_spec="$2"
  local skill_dir="$run_dir/.claude/skills"
  mkdir -p "$skill_dir"
  IFS=':' read -ra PATHS <<< "$skill_spec"
  for sp in "${PATHS[@]}"; do
    local src="$SKILLS_DIR/$sp"
    local name=$(basename "$sp")
    if [ -d "$src" ]; then
      mkdir -p "$skill_dir/$name"
      cp "$src/SKILL.md" "$skill_dir/$name/" 2>/dev/null || true
      [ -d "$src/reference" ] && cp -r "$src/reference" "$skill_dir/$name/"
    fi
  done
  cat > "$run_dir/.claude/settings.json" << 'SETTINGS'
{"permissions":{"defaultMode":"bypassPermissions"}}
SETTINGS
}

run_single_task() {
  local task_idx="$1" round="$2"

  local task_dir="${TASK_DIRS[$task_idx]}"
  local task_label="${TASK_LABELS[$task_idx]}"
  local prompt="${TASK_PROMPTS[$task_idx]}"
  local skill_spec="${TASK_SKILLS[$task_idx]}"
  local test_script="${TASK_TESTS[$task_idx]}"
  local max_turns="${TASK_TURNS[$task_idx]}"

  for model in "$SONNET" "$OPUS"; do
    local model_short=$([ "$model" = "$SONNET" ] && echo "sonnet" || echo "opus")

    for skills in "noskill" "skill"; do
      local label="${task_label}_${model_short}_${skills}"
      local run_dir="$TMP/r${round}/${label}"
      local out_json="$RUNS_DIR/${label}_r${round}.json"

      # Skip if done
      if [ -f "$out_json" ] && [ -s "$out_json" ]; then
        local prev_cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
        if [ "$prev_cost" != "0" ]; then
          echo "[R$round $task_label] [SKIP] $label"
          continue
        fi
      fi

      rm -r "$run_dir" 2>/dev/null
      mkdir -p "$TMP/r${round}"
      cp -r "$BENCH_DIR/tasks/$task_dir" "$run_dir"
      rm -r "$run_dir/.git" 2>/dev/null

      if [ "$skills" = "skill" ]; then
        install_skills "$run_dir" "$skill_spec"
      fi

      # Clear Claude project cache to prevent skill leakage between runs
      local cache_dir="$HOME/.claude/projects"
      local run_dir_escaped=$(echo "$run_dir" | sed 's|/|--|g; s|^--||; s|:||g')
      rm -r "$cache_dir/$run_dir_escaped" 2>/dev/null || true
      # Also clear with Windows path encoding
      local win_escaped=$(echo "$run_dir" | sed 's|/c/|C--|; s|/|--|g; s|^--||')
      rm -r "$cache_dir/$win_escaped" 2>/dev/null || true
      # Nuclear option: clear all /tmp/bench-v2 project caches
      find "$cache_dir" -maxdepth 1 -name "*bench-v2*" -type d -exec rm -r {} + 2>/dev/null || true

      echo "[R$round $task_label] >>> $label ($model_short, $skills)"
      cd "$run_dir"
      claude -p "$prompt" --model "$model" --output-format json --max-turns "$max_turns" --no-session-persistence --dangerously-skip-permissions > "$out_json" 2>/dev/null || true
      cd "$BENCH_DIR"

      jq -r '.result // ""' "$out_json" > "$RUNS_DIR/${label}_r${round}.txt" 2>/dev/null
      local dur=$(jq -r '.duration_ms // 0' "$out_json" 2>/dev/null)
      local cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
      local turns=$(jq -r '.num_turns // 0' "$out_json" 2>/dev/null)
      echo "[R$round $task_label] [DONE] $label - $((dur/1000))s, \$$cost, $turns turns"

      (cd "$run_dir" && docker compose down -v 2>/dev/null) || true

      bash "$TESTS_DIR/$test_script" "$run_dir" 2>&1 | tee "$RUNS_DIR/${label}_r${round}_test.txt"
    done
  done
  echo "[R$round $task_label] Complete"
}

echo "============================================"
echo "  Benchmark v2 - 3x Median Run - $(date)"
echo "============================================"

# Pre-build buggy Valkey image
echo "=== PRE-BUILD ==="
docker build -t buggy-valkey:latest \
  -f "$BENCH_DIR/tasks/1-bug-investigation/Dockerfile.buggy-valkey" \
  "$BENCH_DIR/tasks/1-bug-investigation/" 2>&1 | tail -3

for round in 1 2 3; do
  echo ""
  echo "========================================="
  echo "  ROUND $round / 3"
  echo "========================================="

  # Launch all 4 tasks in parallel
  PIDS=()
  for task_idx in 0 1 2 3; do
    run_single_task "$task_idx" "$round" &
    PIDS+=($!)
  done

  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null; done
  echo "[ROUND $round] All tasks complete"
done

# Compute medians
echo ""
echo "========================================="
echo "  MEDIAN RESULTS"
echo "========================================="

printf "%-30s | %5s %5s %5s | %5s %5s %5s | median\n" \
  "Run" "R1" "R2" "R3" "Time" "Cost" "Score"
echo "-------------------------------+-------------------+-------------------+-------"

for task_idx in 0 1 2 3; do
  task_label="${TASK_LABELS[$task_idx]}"
  for model_short in "sonnet" "opus"; do
    for skills in "noskill" "skill"; do
      label="${task_label}_${model_short}_${skills}"
      scores=()
      times=()
      costs=()

      for r in 1 2 3; do
        f="$RUNS_DIR/${label}_r${r}.json"
        tf="$RUNS_DIR/${label}_r${r}_test.txt"
        if [ -f "$f" ] && [ -s "$f" ]; then
          dur=$(jq -r '.duration_ms // 0' "$f" 2>/dev/null)
          cost=$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null)
          score=$(grep "^SCORE=" "$tf" 2>/dev/null | tail -1 | cut -d= -f2 | cut -d/ -f1)
          times+=("$((dur/1000))")
          costs+=("$cost")
          scores+=("${score:-0}")
        else
          times+=("-")
          costs+=("-")
          scores+=("-")
        fi
      done

      # Compute median (sort 3 values, take middle)
      med_score=$(printf '%s\n' "${scores[@]}" | grep -v "^-$" | sort -n | sed -n '2p')
      med_time=$(printf '%s\n' "${times[@]}" | grep -v "^-$" | sort -n | sed -n '2p')
      med_cost=$(printf '%s\n' "${costs[@]}" | grep -v "^-$" | sort -n | sed -n '2p')

      printf "%-30s | %5s %5s %5s | %5s %5s %5s | %s\n" \
        "$label" \
        "${scores[0]}" "${scores[1]}" "${scores[2]}" \
        "${times[0]}s" "${costs[0]}" "${med_score:-?}" \
        "med=${med_score:-?} t=${med_time:-?}s c=\$${med_cost:-?}"
    done
  done
done
