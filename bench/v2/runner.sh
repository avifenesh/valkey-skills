#!/bin/bash
# Benchmark v2 Runner
# Runs tasks SEQUENTIALLY per task (to avoid port conflicts)
# but runs models/conditions in parallel within each task

set -e

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$BENCH_DIR/../../skills"
RUNS_DIR="$BENCH_DIR/runs"
TESTS_DIR="$BENCH_DIR/tests"
RESULTS_FILE="$RUNS_DIR/results.md"
SONNET="us.anthropic.claude-sonnet-4-6"
OPUS="us.anthropic.claude-opus-4-6"
TMP="${TMPDIR:-/tmp}/bench-v2"

mkdir -p "$RUNS_DIR"

# Task configs: dir|prompt|skill_paths|test_script
# skill_paths are colon-separated, relative to skills/
TASK_CONFIGS=(
  '1-bug|This cluster has a bug that causes split-brain after network partition recovery. The reproduce.sh script demonstrates it - run it to see the symptoms. Investigate the root cause in the Valkey server source code and explain what went wrong. Provide a fix or workaround. Write your analysis to ANALYSIS.md.|valkey-dev|test-bug.sh'
  '2-lock|Implement the distributed lock in this Java project using Valkey GLIDE. Read README.md for requirements. The lock must support TTL-based expiration, owner identification, retry with backoff, and safe release (compare-and-delete). Use GLIDE APIs correctly - not Jedis or Lettuce. Start Valkey with docker compose up -d first.|valkey-glide/java|test-lock.sh'
  '3-ops|Create all Kubernetes manifests and configuration files per requirements.md. Use kind for the local cluster. Include a deploy.sh script and a test.sh that validates the deployment works.|valkey-ops:valkey-ecosystem|test-ops.sh'
  '4-improve|Review app.js and improve it. Focus on Valkey-specific best practices, performance patterns, and production readiness. Fix all anti-patterns you find. Start Valkey with docker compose up -d first. The improved code must work - test it.|valkey|test-improvement.sh'
)

TASK_DIRS=("1-bug-investigation" "2-glide-lock" "3-ops-cluster" "4-code-improvement")
TASK_LABELS=("1-bug" "2-lock" "3-ops" "4-improve")

install_skills() {
  local run_dir="$1"
  local skill_spec="$2"

  # Create skills directory that Claude Code discovers
  local skill_dir="$run_dir/.claude/skills"
  mkdir -p "$skill_dir"

  IFS=':' read -ra PATHS <<< "$skill_spec"
  for sp in "${PATHS[@]}"; do
    local src="$SKILLS_DIR/$sp"
    local name=$(basename "$sp")
    if [ -d "$src" ]; then
      # Copy only the specific skill, not sibling directories
      mkdir -p "$skill_dir/$name"
      cp "$src/SKILL.md" "$skill_dir/$name/" 2>/dev/null || true
      # Copy reference/ if it exists (for router-pattern skills)
      [ -d "$src/reference" ] && cp -r "$src/reference" "$skill_dir/$name/"
      echo "    Installed: $sp"
    else
      echo "    [WARN] Not found: $sp"
    fi
  done

  # Create settings.json to register skills
  cat > "$run_dir/.claude/settings.json" << SETTINGS
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
SETTINGS
}

echo "============================================"
echo "  Benchmark v2 - $(date)"
echo "============================================"

# Pre-build the buggy Valkey image once
echo ""
echo "=== PRE-BUILD: Building buggy Valkey image ==="
cd "$BENCH_DIR/tasks/1-bug-investigation"
docker build -t buggy-valkey:latest -f Dockerfile.buggy-valkey . 2>&1 | tail -3
cd "$BENCH_DIR"

# docker-compose.yml already references buggy-valkey:latest

echo ""
echo "=== RUNNING BENCHMARK ==="

# Process one task at a time (avoids port conflicts)
# Within each task, run 4 conditions in parallel
for task_idx in 0 1 2 3; do
  IFS='|' read -r task_label prompt skill_spec test_script <<< "${TASK_CONFIGS[$task_idx]}"
  task_dir="${TASK_DIRS[$task_idx]}"

  echo ""
  echo "--- Task: $task_label ($task_dir) ---"

  PIDS=()
  LABELS=()

  for model in "$SONNET" "$OPUS"; do
    model_short=$([ "$model" = "$SONNET" ] && echo "sonnet" || echo "opus")

    for skills in "noskill" "skill"; do
      label="${task_label}_${model_short}_${skills}"
      run_dir="$TMP/$label"

      # Create isolated copy
      rm -rf "$run_dir" 2>/dev/null
      cp -r "$BENCH_DIR/tasks/$task_dir" "$run_dir"
      rm -rf "$run_dir/.git" 2>/dev/null

      # Install targeted skills if needed
      if [ "$skills" = "skill" ]; then
        echo "  Setting up $label (with skills)..."
        install_skills "$run_dir" "$skill_spec"
      else
        echo "  Setting up $label (no skills)..."
      fi

      # Launch agent
      out_json="$RUNS_DIR/${label}.json"
      (
        cd "$run_dir"
        claude -p "$prompt" \
          --model "$model" \
          --output-format json \
          --max-turns 30 \
          --dangerously-skip-permissions \
          > "$out_json" 2>/dev/null

        jq -r '.result // ""' "$out_json" > "$RUNS_DIR/${label}.txt" 2>/dev/null
        dur=$(jq -r '.duration_ms // 0' "$out_json" 2>/dev/null)
        cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
        echo "  [DONE] $label - $((dur/1000))s, \$$cost"
      ) &

      PIDS+=($!)
      LABELS+=("$label")
    done
  done

  echo "  Waiting for 4 agents (${LABELS[*]})..."
  set +e
  for pid in "${PIDS[@]}"; do wait "$pid"; done
  set -e

  # Clean up Docker resources for this task
  echo "  Cleaning up Docker resources..."
  for label in "${LABELS[@]}"; do
    (cd "$TMP/$label" && docker compose down -v 2>/dev/null) || true
  done

  # Run validation tests
  echo "  Running validation tests..."
  for label in "${LABELS[@]}"; do
    echo ""
    echo "  --- Testing $label ---"
    bash "$TESTS_DIR/$test_script" "$TMP/$label" 2>&1 | tee "$RUNS_DIR/${label}_test.txt"
  done
done

# Phase: Judging
echo ""
echo "=== JUDGING (3 per run) ==="

ALL_LABELS=()
for task_idx in 0 1 2 3; do
  task_label="${TASK_LABELS[$task_idx]}"
  for model_short in "sonnet" "opus"; do
    for skills in "noskill" "skill"; do
      ALL_LABELS+=("${task_label}_${model_short}_${skills}")
    done
  done
done

for label in "${ALL_LABELS[@]}"; do
  response_file="$RUNS_DIR/${label}.txt"
  [ ! -f "$response_file" ] && continue

  for run in 1 2 3; do
    judge_out="$RUNS_DIR/judge_${label}_r${run}.json"
    [ -f "$judge_out" ] && continue

    # Write prompt to temp file to avoid shell expansion issues
    tmpfile=$(mktemp)
    cat > "$tmpfile" << 'CRITERIA'
You are a code review judge. Score this AI-generated response on 5 criteria, each 1-10. Return ONLY valid JSON, no markdown, no explanation.

{"correctness": N, "completeness": N, "valkey_awareness": N, "production_quality": N, "specificity": N}

correctness: Does the code compile/work? Are APIs used correctly?
completeness: All requirements covered?
valkey_awareness: Uses Valkey-specific knowledge, not Redis patterns?
production_quality: Error handling, security, edge cases?
specificity: Concrete code and actual function/struct names vs generic descriptions?

Response to judge:

CRITERIA
    head -300 "$response_file" >> "$tmpfile"

    cat "$tmpfile" | claude -p - \
      --model "$SONNET" \
      --output-format json \
      --max-turns 1 \
      --dangerously-skip-permissions \
      2>/dev/null | jq -r '.result // ""' > "$judge_out"

    rm -f "$tmpfile"
    echo "  Judge $run for $label"
  done
done

# Phase: Compile results
echo ""
echo "=== RESULTS ==="

{
echo "# Benchmark v2 Results - $(date '+%Y-%m-%d')"
echo ""
echo "## Performance"
echo ""
echo "| Task | Model | Skills | Duration | Cost | Turns |"
echo "|------|-------|--------|----------|------|-------|"

for label in "${ALL_LABELS[@]}"; do
  f="$RUNS_DIR/${label}.json"
  [ ! -f "$f" ] && continue
  task=$(echo "$label" | cut -d_ -f1-2)
  model=$(echo "$label" | awk -F_ '{print $(NF-1)}')
  skills=$(echo "$label" | awk -F_ '{print $NF}')
  dur=$(jq -r '.duration_ms // 0' "$f" 2>/dev/null)
  cost=$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null)
  turns=$(jq -r '.num_turns // 0' "$f" 2>/dev/null)
  printf "| %s | %s | %s | %ss | \$%.2f | %s |\n" "$task" "$model" "$skills" "$((dur/1000))" "$cost" "$turns"
done

echo ""
echo "## Validation Tests"
echo ""
echo "| Task | Model | Skills | Score |"
echo "|------|-------|--------|-------|"

for label in "${ALL_LABELS[@]}"; do
  f="$RUNS_DIR/${label}_test.txt"
  [ ! -f "$f" ] && continue
  task=$(echo "$label" | cut -d_ -f1-2)
  model=$(echo "$label" | awk -F_ '{print $(NF-1)}')
  skills=$(echo "$label" | awk -F_ '{print $NF}')
  score=$(grep "^SCORE=" "$f" | tail -1 | cut -d= -f2)
  printf "| %s | %s | %s | %s |\n" "$task" "$model" "$skills" "$score"
done

echo ""
echo "## Quality Scores (avg of 3 judges)"
echo ""
echo "| Task | Model | Skills | Correct | Complete | Valkey | Prod | Specific | Avg |"
echo "|------|-------|--------|---------|----------|--------|------|----------|-----|"

for label in "${ALL_LABELS[@]}"; do
  scores=""
  for run in 1 2 3; do
    f="$RUNS_DIR/judge_${label}_r${run}.json"
    if [ -f "$f" ]; then
      clean=$(cat "$f" | sed 's/```json//g; s/```//g' | tr -d '\n')
      # Validate it's actual JSON
      echo "$clean" | jq . >/dev/null 2>&1 && scores="$scores $clean"
    fi
  done

  [ -z "$scores" ] && continue

  result=$(echo "$scores" | jq -s '
    def avg(f): [.[] | f // empty] | if length > 0 then (add / length * 10 | round) / 10 else 0 end;
    {c: avg(.correctness), cm: avg(.completeness), v: avg(.valkey_awareness), p: avg(.production_quality), s: avg(.specificity)}
  ' 2>/dev/null)

  [ -z "$result" ] || [ "$result" = "null" ] && continue

  task=$(echo "$label" | cut -d_ -f1-2)
  model=$(echo "$label" | awk -F_ '{print $(NF-1)}')
  skills=$(echo "$label" | awk -F_ '{print $NF}')
  c=$(echo "$result" | jq -r '.c')
  cm=$(echo "$result" | jq -r '.cm')
  v=$(echo "$result" | jq -r '.v')
  p=$(echo "$result" | jq -r '.p')
  s=$(echo "$result" | jq -r '.s')
  avg=$(echo "$c $cm $v $p $s" | awk '{printf "%.1f", ($1+$2+$3+$4+$5)/5}')
  printf "| %s | %s | %s | %s | %s | %s | %s | %s | **%s** |\n" \
    "$task" "$model" "$skills" "$c" "$cm" "$v" "$p" "$s" "$avg"
done

} > "$RESULTS_FILE"

echo ""
cat "$RESULTS_FILE"
echo ""
echo "Full results in $RUNS_DIR/"
