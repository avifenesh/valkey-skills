#!/usr/bin/env bash
set -euo pipefail

# Valkey Skills Benchmark v3 Runner
# Usage: ./run.sh [--task N] [--model sonnet|opus] [--condition skill|noskill] [--runs N] [--batch N]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
TASKS_DIR="$BENCH_DIR/tasks"
RESULTS_DIR="$BENCH_DIR/results"
JUDGES_DIR="$BENCH_DIR/judges"

# Defaults
TASK_FILTER=""
MODEL_FILTER=""
CONDITION_FILTER=""
RUNS=3
BATCH_SIZE=10
MAX_PARALLEL_JUDGES=20

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK_FILTER="$2"; shift 2 ;;
    --model) MODEL_FILTER="$2"; shift 2 ;;
    --condition) CONDITION_FILTER="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --batch) BATCH_SIZE="$2"; shift 2 ;;
    --clean-cache) CLEAN_CACHE=1; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# Task configs: name, max_turns, skills
declare -A TASK_TURNS=(
  [1-valkey-bug]=50
  [2-glide-nodejs-app]=60
  [3-ops-hardening]=40
  [4-rust-module]=60
  [5-bloom-feature]=50
  [6-redis-py-migration]=50
  [7-search-debug]=40
  [8-json-operations]=40
  [9-bloom-capacity]=40
  [10-spring-java]=60
)

declare -A TASK_SKILLS=(
  [1-valkey-bug]="skills/valkey-dev"
  [2-glide-nodejs-app]="skills/valkey,skills/valkey-glide/nodejs"
  [3-ops-hardening]="skills/valkey-ops"
  [4-rust-module]="skills/valkey-module-dev"
  [5-bloom-feature]="skills/valkey-bloom-dev"
  [6-redis-py-migration]="skills/migrate-redis-py,skills/valkey-glide/python"
  [7-search-debug]="skills/valkey-modules"
  [8-json-operations]="skills/valkey-modules"
  [9-bloom-capacity]="skills/valkey-modules"
  [10-spring-java]="skills/spring-data-valkey,skills/valkey-glide/java"
)

declare -A TASK_MODELS=(
  [sonnet]="sonnet"
  [opus]="opus"
)

# Scoring weights
# correctness=3, judge=1, time=1, cost=1
# Total possible = tests_passed/tests_total * 3 + judge_avg/10 * 1 + time_score * 1 + cost_score * 1
# time_score: 1.0 if under budget, linear decay to 0 at 3x budget
# cost_score: 1.0 if under $1, linear decay to 0 at $5

clean_global_cache() {
  echo "[CLEAN] Clearing global Claude cache..."
  rm -rf ~/.claude/plugins/cache/* 2>/dev/null || true
  rm -rf ~/.claude/statsig_cache/* 2>/dev/null || true
  echo "[CLEAN] Done"
}

run_single() {
  local task="$1" model="$2" condition="$3" run_num="$4"
  local task_dir="$TASKS_DIR/$task"
  local run_id="${task}_${model}_${condition}_run${run_num}"
  local run_dir="$RESULTS_DIR/$run_id"
  local max_turns="${TASK_TURNS[$task]}"

  mkdir -p "$run_dir"

  # Prepare work directory (isolated copy)
  local work_dir="$run_dir/work"
  cp -r "$task_dir/workspace" "$work_dir" 2>/dev/null || mkdir -p "$work_dir"

  # Build skill args
  local skill_args=""
  if [[ "$condition" == "skill" ]]; then
    IFS=',' read -ra SKILL_DIRS <<< "${TASK_SKILLS[$task]}"
    for sd in "${SKILL_DIRS[@]}"; do
      skill_args="$skill_args --plugin-dir $BENCH_DIR/../../$sd"
    done
  fi

  # Build prompt
  local prompt
  prompt=$(cat "$task_dir/prompt.md")

  # Record start
  local start_time
  start_time=$(date +%s)

  echo "[RUN] $run_id (max_turns=$max_turns, model=$model)"

  # Run agent
  claude -p "$prompt" \
    --max-turns "$max_turns" \
    --model "$model" \
    --output-format json \
    --cwd "$work_dir" \
    $skill_args \
    > "$run_dir/agent_output.json" 2>"$run_dir/agent_stderr.log" || true

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Extract cost from output
  local cost
  cost=$(python3 -c "
import json, sys
try:
    d = json.load(open('$run_dir/agent_output.json'))
    print(d.get('cost_usd', d.get('usage', {}).get('cost_usd', 0)))
except: print(0)
" 2>/dev/null || echo "0")

  local turns
  turns=$(python3 -c "
import json, sys
try:
    d = json.load(open('$run_dir/agent_output.json'))
    print(d.get('num_turns', 0))
except: print(0)
" 2>/dev/null || echo "0")

  # Run tests
  echo "[TEST] $run_id"
  bash "$task_dir/test.sh" "$work_dir" > "$run_dir/test_output.txt" 2>&1 || true
  local test_passed test_total
  test_passed=$(grep -c "^PASS:" "$run_dir/test_output.txt" 2>/dev/null || echo "0")
  test_total=$(grep -c "^PASS:\|^FAIL:" "$run_dir/test_output.txt" 2>/dev/null || echo "0")

  # Write metadata
  cat > "$run_dir/metadata.json" <<EOFMETA
{
  "task": "$task",
  "model": "$model",
  "condition": "$condition",
  "run": $run_num,
  "duration_secs": $duration,
  "cost_usd": $cost,
  "turns": $turns,
  "max_turns": $max_turns,
  "tests_passed": $test_passed,
  "tests_total": $test_total
}
EOFMETA

  echo "[DONE] $run_id: ${test_passed}/${test_total} tests, ${duration}s, \$${cost}"

  # Spawn judge immediately (non-blocking)
  spawn_judge "$run_id" "$run_dir" "$task_dir" &
}

spawn_judge() {
  local run_id="$1" run_dir="$2" task_dir="$3"
  local judge_prompt
  judge_prompt=$(cat "$JUDGES_DIR/judge-prompt.md")
  local task_criteria
  task_criteria=$(cat "$task_dir/judge-criteria.md" 2>/dev/null || echo "No specific criteria.")

  # Collect agent output for judging
  local agent_files=""
  for f in "$run_dir/work"/*.md "$run_dir/work"/*.py "$run_dir/work"/*.ts "$run_dir/work"/*.java "$run_dir/work"/*.rs "$run_dir/work"/src/*.rs "$run_dir/work"/src/*.py; do
    [[ -f "$f" ]] && agent_files="$agent_files\n--- $(basename "$f") ---\n$(cat "$f")"
  done

  local full_prompt="$judge_prompt

## Task-Specific Criteria
$task_criteria

## Agent Output Files
$agent_files

## Test Results
$(cat "$run_dir/test_output.txt" 2>/dev/null || echo "No test output")
"

  # Run Codex as judge
  echo "[JUDGE] $run_id"
  codex exec -q "$full_prompt" \
    --model o3 \
    > "$run_dir/judge_output.txt" 2>/dev/null || true

  # Extract score
  local judge_score
  judge_score=$(grep -oP 'SCORE:\s*(\d+(\.\d+)?)' "$run_dir/judge_output.txt" | head -1 | grep -oP '[\d.]+' || echo "0")

  # Append to metadata
  python3 -c "
import json
with open('$run_dir/metadata.json') as f: d = json.load(f)
d['judge_score'] = float('$judge_score' or 0)
with open('$run_dir/metadata.json', 'w') as f: json.dump(d, f, indent=2)
" 2>/dev/null || true

  echo "[JUDGE] $run_id: score=$judge_score"
}

# Build run list
RUNS_LIST=()
for task_dir in "$TASKS_DIR"/*/; do
  task=$(basename "$task_dir")
  [[ -n "$TASK_FILTER" && "$task" != *"$TASK_FILTER"* ]] && continue
  [[ ! -f "$task_dir/prompt.md" ]] && continue

  for model in sonnet opus; do
    [[ -n "$MODEL_FILTER" && "$model" != "$MODEL_FILTER" ]] && continue
    for condition in noskill skill; do
      [[ -n "$CONDITION_FILTER" && "$condition" != "$CONDITION_FILTER" ]] && continue
      for run_num in $(seq 1 "$RUNS"); do
        RUNS_LIST+=("$task|$model|$condition|$run_num")
      done
    done
  done
done

echo "=== Valkey Skills Benchmark v3 ==="
echo "Tasks: $(echo "${RUNS_LIST[@]}" | tr ' ' '\n' | cut -d'|' -f1 | sort -u | wc -l)"
echo "Total runs: ${#RUNS_LIST[@]}"
echo "Batch size: $BATCH_SIZE"
echo ""

# Clean cache if requested
[[ "${CLEAN_CACHE:-0}" == "1" ]] && clean_global_cache

# Run in batches
batch_num=0
for ((i=0; i<${#RUNS_LIST[@]}; i+=BATCH_SIZE)); do
  batch_num=$((batch_num + 1))
  batch=("${RUNS_LIST[@]:i:BATCH_SIZE}")
  echo "=== Batch $batch_num (${#batch[@]} runs) ==="

  pids=()
  for entry in "${batch[@]}"; do
    IFS='|' read -r task model condition run_num <<< "$entry"
    run_single "$task" "$model" "$condition" "$run_num" &
    pids+=($!)
  done

  # Wait for batch to complete
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  echo "=== Batch $batch_num complete ==="
done

# Wait for any remaining judges
wait

# Generate summary
echo ""
echo "=== Generating summary ==="
python3 "$SCRIPT_DIR/summarize.py" "$RESULTS_DIR"
