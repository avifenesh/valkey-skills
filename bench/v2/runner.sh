#!/bin/bash
# Benchmark v2 Runner - Parallel execution
# All 4 tasks run in parallel (separate ports)
# Within each task, 4 conditions run sequentially (same ports)

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

TASK_PROMPTS=(
  'This Valkey cluster has a split-brain bug after network partition recovery. The full Valkey 9.0.3 source code is in src/ and deps/ with a Makefile. The bug is somewhere in the C source. Run reproduce.sh to see the symptoms. Do NOT clone or download any code - everything you need is here. Find the bug in the source, fix it, rebuild with docker compose build, and verify the fix by running reproduce.sh again. The cluster must work correctly after your fix. Write your analysis to ANALYSIS.md including: the exact file, function, and line of the bug, what the bug is, and why your fix is correct.'
  'Implement the message queue in queue.js using Valkey Streams and GLIDE Node.js. Read README.md for requirements. Must use @valkey/valkey-glide - not ioredis or node-redis. The app runs in Docker (see docker-compose.yml). Implement TaskQueue, Worker with consumer groups, dead letter handling, 3 concurrent workers, dashboard, and graceful shutdown. Test with: docker compose up --build'
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

run_task() {
  local task_idx="$1"
  local task_dir="${TASK_DIRS[$task_idx]}"
  local task_label="${TASK_LABELS[$task_idx]}"
  local prompt="${TASK_PROMPTS[$task_idx]}"
  local skill_spec="${TASK_SKILLS[$task_idx]}"
  local test_script="${TASK_TESTS[$task_idx]}"

  echo "[TASK $task_label] Starting"

  for model in "$SONNET" "$OPUS"; do
    local model_short=$([ "$model" = "$SONNET" ] && echo "sonnet" || echo "opus")

    for skills in "noskill" "skill"; do
      local label="${task_label}_${model_short}_${skills}"
      local run_dir="$TMP/$label"
      local out_json="$RUNS_DIR/${label}.json"

      # Skip if already completed
      if [ -f "$out_json" ] && [ -s "$out_json" ]; then
        local prev_cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
        if [ "$prev_cost" != "0" ]; then
          echo "[TASK $task_label] [SKIP] $label (already completed)"
          continue
        fi
      fi

      # Setup
      rm -r "$run_dir" 2>/dev/null
      mkdir -p "$TMP"
      cp -r "$BENCH_DIR/tasks/$task_dir" "$run_dir"
      rm -r "$run_dir/.git" 2>/dev/null

      if [ "$skills" = "skill" ]; then
        install_skills "$run_dir" "$skill_spec"
      fi

      # Run agent
      echo "[TASK $task_label] >>> $label (model: $model_short, skills: $skills)"
      cd "$run_dir"
      claude -p "$prompt" \
        --model "$model" \
        --output-format json \
        --max-turns 30 \
        --dangerously-skip-permissions \
        > "$out_json" 2>/dev/null || true
      cd "$BENCH_DIR"

      jq -r '.result // ""' "$out_json" > "$RUNS_DIR/${label}.txt" 2>/dev/null
      local dur=$(jq -r '.duration_ms // 0' "$out_json" 2>/dev/null)
      local cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
      local turns=$(jq -r '.num_turns // 0' "$out_json" 2>/dev/null)
      echo "[TASK $task_label] [DONE] $label - $((dur/1000))s, \$$cost, $turns turns"

      # Cleanup docker
      (cd "$run_dir" && docker compose down -v 2>/dev/null) || true

      # Validate
      bash "$TESTS_DIR/$test_script" "$run_dir" 2>&1 | tee "$RUNS_DIR/${label}_test.txt"
    done
  done

  echo "[TASK $task_label] Complete"
}

echo "============================================"
echo "  Benchmark v2 - $(date)"
echo "  All 4 tasks running in parallel"
echo "============================================"

# Pre-build buggy Valkey image
echo ""
echo "=== PRE-BUILD: Building buggy Valkey image ==="
docker build -t buggy-valkey:latest \
  -f "$BENCH_DIR/tasks/1-bug-investigation/Dockerfile.buggy-valkey" \
  "$BENCH_DIR/tasks/1-bug-investigation/" 2>&1 | tail -5
echo "[OK] Image built"

# Launch all 4 tasks in parallel
echo ""
echo "=== LAUNCHING 4 PARALLEL TASK GROUPS ==="
TASK_PIDS=()

for idx in 0 1 2 3; do
  run_task "$idx" &
  TASK_PIDS+=($!)
  echo "  Launched task ${TASK_LABELS[$idx]} (PID: ${TASK_PIDS[-1]})"
done

echo ""
echo "Waiting for all 4 task groups (16 agent runs total)..."
for pid in "${TASK_PIDS[@]}"; do
  wait "$pid" 2>/dev/null
done

echo ""
echo "=== ALL RUNS COMPLETE ==="

# Collect all labels
ALL_LABELS=()
for task_idx in 0 1 2 3; do
  for model_short in "sonnet" "opus"; do
    for skills in "noskill" "skill"; do
      ALL_LABELS+=("${TASK_LABELS[$task_idx]}_${model_short}_${skills}")
    done
  done
done

# Judge phase
echo ""
echo "=== JUDGING (3 per run, parallel) ==="

judge_one() {
  local label="$1" run="$2"
  local judge_out="$RUNS_DIR/judge_${label}_r${run}.json"
  [ -f "$judge_out" ] && [ -s "$judge_out" ] && return

  local response_file="$RUNS_DIR/${label}.txt"
  [ ! -f "$response_file" ] || [ ! -s "$response_file" ] && return

  local tmpfile=$(mktemp)
  cat > "$tmpfile" << 'CRITERIA'
You are a code review judge. Score this AI-generated code on 5 criteria, each 1-10. Return ONLY valid JSON, no markdown.

{"correctness": N, "completeness": N, "valkey_awareness": N, "production_quality": N, "specificity": N}
CRITERIA
  head -500 "$response_file" >> "$tmpfile"

  cat "$tmpfile" | claude -p - \
    --model "$OPUS" \
    --output-format json \
    --max-turns 1 \
    --dangerously-skip-permissions \
    2>/dev/null | jq -r '.result // ""' > "$judge_out" || true
  rm -f "$tmpfile"
  echo "  Judge $run/$label"
}

JUDGE_PIDS=()
for label in "${ALL_LABELS[@]}"; do
  for run in 1 2 3; do
    judge_one "$label" "$run" &
    JUDGE_PIDS+=($!)
  done
done

echo "Launched ${#JUDGE_PIDS[@]} judge calls, waiting..."
for pid in "${JUDGE_PIDS[@]}"; do
  wait "$pid" 2>/dev/null
done

# Results
echo ""
echo "=== FINAL RESULTS ==="
printf "%-30s | %6s %6s %5s | %5s | %5s %5s %5s %5s %5s | %5s\n" \
  "Run" "Time" "Cost" "Turns" "Test" "Corr" "Comp" "Valk" "Prod" "Spec" "Avg"
echo "-------------------------------+----------------------+-------+---------------------------------------+------"

for label in "${ALL_LABELS[@]}"; do
  f="$RUNS_DIR/${label}.json"
  [ ! -f "$f" ] && continue
  task=$(echo "$label" | cut -d_ -f1-2)
  model=$(echo "$label" | awk -F_ '{print $(NF-1)}')
  skills=$(echo "$label" | awk -F_ '{print $NF}')
  dur=$(jq -r '.duration_ms // 0' "$f" 2>/dev/null)
  cost=$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null)
  turns=$(jq -r '.num_turns // 0' "$f" 2>/dev/null)

  test_f="$RUNS_DIR/${label}_test.txt"
  score=$(grep "^SCORE=" "$test_f" 2>/dev/null | tail -1 | cut -d= -f2)

  # Judge scores
  scores=""
  for r in 1 2 3; do
    jf="$RUNS_DIR/judge_${label}_r${r}.json"
    if [ -f "$jf" ] && [ -s "$jf" ]; then
      clean=$(cat "$jf" | sed 's/```json//g; s/```//g' | tr -d '\n')
      echo "$clean" | jq . >/dev/null 2>&1 && scores="$scores $clean"
    fi
  done

  if [ -n "$scores" ]; then
    avg=$(echo "$scores" | jq -s '
      def avg(f): [.[] | f // empty] | if length > 0 then (add / length * 10 | round) / 10 else 0 end;
      {c: avg(.correctness), cm: avg(.completeness), v: avg(.valkey_awareness), p: avg(.production_quality), s: avg(.specificity)}
    ' 2>/dev/null)
    c=$(echo "$avg" | jq -r '.c'); cm=$(echo "$avg" | jq -r '.cm')
    v=$(echo "$avg" | jq -r '.v'); p=$(echo "$avg" | jq -r '.p')
    s=$(echo "$avg" | jq -r '.s')
    total=$(echo "$c $cm $v $p $s" | awk '{printf "%.1f", ($1+$2+$3+$4+$5)/5}')
    printf "%-30s | %5ss %5s %5s | %5s | %5s %5s %5s %5s %5s | %5s\n" \
      "$label" "$((dur/1000))" "\$$cost" "$turns" "$score" "$c" "$cm" "$v" "$p" "$s" "$total"
  else
    printf "%-30s | %5ss %5s %5s | %5s | pending\n" \
      "$label" "$((dur/1000))" "\$$cost" "$turns" "$score"
  fi
done
