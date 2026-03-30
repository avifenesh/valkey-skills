#!/bin/bash
# Benchmark v2 Runner
# Launches 16 parallel agents (4 tasks x 2 models x 2 skill conditions)
# Then validates, judges, and compiles results

set +e
BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_REPO="https://github.com/avifenesh/valkey-skills.git"
RUNS_DIR="$BENCH_DIR/runs"
TESTS_DIR="$BENCH_DIR/tests"
RESULTS_FILE="$RUNS_DIR/results.md"
SONNET="us.anthropic.claude-sonnet-4-6"
OPUS="opus"
TMP="/tmp/bench-v2"

mkdir -p "$RUNS_DIR"

# Task prompts
PROMPT_1="This cluster has a bug that causes split-brain after network partition recovery. The reproduce.sh script demonstrates it - run it to see the symptoms. Investigate the root cause in the Valkey server source code and explain what went wrong. Provide a fix or workaround. Write your analysis to ANALYSIS.md."

PROMPT_2="Implement the distributed lock in this Java project using Valkey GLIDE. Read README.md for requirements. The lock must support TTL-based expiration, owner identification, retry with backoff, and safe release (compare-and-delete). Use GLIDE APIs correctly - not Jedis or Lettuce. Start Valkey with docker compose up -d first."

PROMPT_3="Create all Kubernetes manifests and configuration files per requirements.md. Use kind for the local cluster. Include a deploy.sh script that creates the kind cluster and deploys everything, and a test.sh that validates the deployment works."

PROMPT_4="Review app.js and improve it. Focus on Valkey-specific best practices, performance patterns, and production readiness. Fix all anti-patterns you find. Start Valkey with docker compose up -d first. The improved code must work - test it."

PROMPTS=("$PROMPT_1" "$PROMPT_2" "$PROMPT_3" "$PROMPT_4")
TASK_DIRS=("1-bug-investigation" "2-glide-lock" "3-ops-cluster" "4-code-improvement")
TASK_SKILLS=("valkey-dev" "valkey-glide:valkey-glide/java" "valkey-ops:valkey-ecosystem" "valkey")

# Skills to install per task (colon-separated paths relative to skills/)
install_skills() {
  local run_dir="$1"
  local skill_spec="$2"

  mkdir -p "$run_dir/.claude/skills"
  IFS=':' read -ra SKILL_PATHS <<< "$skill_spec"
  for sp in "${SKILL_PATHS[@]}"; do
    local src_dir="$BENCH_DIR/../../skills/$sp"
    if [ -d "$src_dir" ]; then
      local dest="$run_dir/.claude/skills/$(basename "$sp")"
      cp -r "$src_dir" "$dest"
      echo "  Installed skill: $sp"
    else
      echo "  [WARN] Skill not found: $src_dir"
    fi
  done
}

# Phase 1: Create 16 isolated directories
echo "============================================"
echo "  Benchmark v2 - $(date)"
echo "============================================"
echo ""
echo "=== PHASE 1: Creating 16 isolated runs ==="

rm -rf "$TMP" 2>/dev/null
mkdir -p "$TMP"

PIDS=()
RUN_LABELS=()

for task_idx in 0 1 2 3; do
  task_dir="${TASK_DIRS[$task_idx]}"
  task_skill="${TASK_SKILLS[$task_idx]}"
  prompt="${PROMPTS[$task_idx]}"

  for model in "$SONNET" "$OPUS"; do
    model_short=$(echo "$model" | sed 's/us.anthropic.claude-//')

    for skills in "noskill" "skill"; do
      label="${task_dir}_${model_short}_${skills}"
      run_dir="$TMP/$label"

      echo "Creating $label..."
      cp -r "$BENCH_DIR/tasks/$task_dir" "$run_dir"

      # Remove any git
      rm -rf "$run_dir/.git" 2>/dev/null

      # Install targeted skills if needed
      if [ "$skills" = "skill" ]; then
        install_skills "$run_dir" "$task_skill"
      fi

      RUN_LABELS+=("$label")
    done
  done
done

echo ""
echo "Created ${#RUN_LABELS[@]} run directories"

# Phase 2: Launch all 16 agents in parallel
echo ""
echo "=== PHASE 2: Launching 16 agents ==="

for task_idx in 0 1 2 3; do
  task_dir="${TASK_DIRS[$task_idx]}"
  prompt="${PROMPTS[$task_idx]}"

  for model in "$SONNET" "$OPUS"; do
    model_short=$(echo "$model" | sed 's/us.anthropic.claude-//')

    for skills in "noskill" "skill"; do
      label="${task_dir}_${model_short}_${skills}"
      run_dir="$TMP/$label"
      out_json="$RUNS_DIR/${label}.json"

      echo "  Launching $label..."

      (
        cd "$run_dir"
        claude -p "$prompt" \
          --model "$model" \
          --output-format json \
          --max-turns 30 \
          --dangerously-skip-permissions \
          > "$out_json" 2>/dev/null

        # Save text result
        jq -r '.result // ""' "$out_json" > "$RUNS_DIR/${label}.txt" 2>/dev/null

        # Extract metrics
        dur=$(jq -r '.duration_ms // 0' "$out_json" 2>/dev/null)
        cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
        turns=$(jq -r '.num_turns // 0' "$out_json" 2>/dev/null)
        echo "  [DONE] $label - ${dur}ms, \$$cost, $turns turns"
      ) &

      PIDS+=($!)
    done
  done
done

echo ""
echo "Waiting for ${#PIDS[@]} agents to complete..."

for pid in "${PIDS[@]}"; do
  wait "$pid"
done

echo "All agents completed."

# Phase 3: Run validation tests
echo ""
echo "=== PHASE 3: Validation tests ==="

for task_idx in 0 1 2 3; do
  task_dir="${TASK_DIRS[$task_idx]}"
  test_script="$TESTS_DIR/test-$(echo "$task_dir" | sed 's/[0-9]*-//'| head -c 20).sh"

  # Map task dir to test script
  case "$task_idx" in
    0) test_script="$TESTS_DIR/test-bug.sh" ;;
    1) test_script="$TESTS_DIR/test-lock.sh" ;;
    2) test_script="$TESTS_DIR/test-ops.sh" ;;
    3) test_script="$TESTS_DIR/test-improvement.sh" ;;
  esac

  for model in "$SONNET" "$OPUS"; do
    model_short=$(echo "$model" | sed 's/us.anthropic.claude-//')
    for skills in "noskill" "skill"; do
      label="${task_dir}_${model_short}_${skills}"
      run_dir="$TMP/$label"

      echo ""
      echo "--- Testing $label ---"
      bash "$test_script" "$run_dir" 2>&1 | tee "$RUNS_DIR/${label}_test.txt"
    done
  done
done

# Phase 4: Judge each run (3 judges per run)
echo ""
echo "=== PHASE 4: Judging (3 per run) ==="

for label in "${RUN_LABELS[@]}"; do
  response=$(cat "$RUNS_DIR/${label}.txt" | head -300)

  for run in 1 2 3; do
    judge_out="$RUNS_DIR/judge_${label}_r${run}.json"
    [ -f "$judge_out" ] && continue

    cat > /tmp/judge_prompt.txt << 'CRITERIA'
You are a code review judge. Score this AI-generated response on 5 criteria, each 1-10. Return ONLY valid JSON, no markdown, no explanation.

{"correctness": N, "completeness": N, "valkey_awareness": N, "production_quality": N, "specificity": N}

correctness: Does the code compile/work? Are APIs used correctly?
completeness: All requirements covered?
valkey_awareness: Uses Valkey-specific knowledge, not Redis patterns? Correct API names?
production_quality: Error handling, security, edge cases?
specificity: Concrete code and actual function/struct names vs generic descriptions?

Response to judge:

CRITERIA
    echo "$response" >> /tmp/judge_prompt.txt

    cat /tmp/judge_prompt.txt | claude -p - \
      --model "$SONNET" \
      --output-format json \
      --max-turns 1 \
      --dangerously-skip-permissions \
      2>/dev/null | jq -r '.result // ""' > "$judge_out"

    echo "  Judge $run for $label done"
  done
done

# Phase 5: Compile results
echo ""
echo "=== PHASE 5: Compile results ==="

{
echo "# Benchmark v2 Results - $(date '+%Y-%m-%d')"
echo ""
echo "## Performance"
echo ""
echo "| Task | Model | Skills | Duration | Cost | Turns |"
echo "|------|-------|--------|----------|------|-------|"

for label in "${RUN_LABELS[@]}"; do
  f="$RUNS_DIR/${label}.json"
  if [ -f "$f" ]; then
    task=$(echo "$label" | cut -d_ -f1-2)
    model=$(echo "$label" | sed 's/.*_\(sonnet-4-6\|opus\)_.*/\1/')
    skills=$(echo "$label" | sed 's/.*_//')
    dur=$(jq -r '.duration_ms // 0' "$f" 2>/dev/null)
    dur_s=$((dur / 1000))
    cost=$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null)
    turns=$(jq -r '.num_turns // 0' "$f" 2>/dev/null)
    printf "| %s | %s | %s | %ss | \$%s | %s |\n" "$task" "$model" "$skills" "$dur_s" "$cost" "$turns"
  fi
done

echo ""
echo "## Validation Tests"
echo ""
echo "| Task | Model | Skills | Tests Passed |"
echo "|------|-------|--------|-------------|"

for label in "${RUN_LABELS[@]}"; do
  test_file="$RUNS_DIR/${label}_test.txt"
  if [ -f "$test_file" ]; then
    task=$(echo "$label" | cut -d_ -f1-2)
    model=$(echo "$label" | sed 's/.*_\(sonnet-4-6\|opus\)_.*/\1/')
    skills=$(echo "$label" | sed 's/.*_//')
    score=$(grep "^SCORE=" "$test_file" | tail -1 | cut -d= -f2)
    printf "| %s | %s | %s | %s |\n" "$task" "$model" "$skills" "$score"
  fi
done

echo ""
echo "## Quality Scores (avg of 3 judges)"
echo ""
echo "| Task | Model | Skills | Correct | Complete | Valkey | Prod | Specific | Avg |"
echo "|------|-------|--------|---------|----------|--------|------|----------|-----|"

for label in "${RUN_LABELS[@]}"; do
  scores=""
  for run in 1 2 3; do
    f="$RUNS_DIR/judge_${label}_r${run}.json"
    if [ -f "$f" ]; then
      clean=$(cat "$f" | sed 's/```json//g; s/```//g' | tr -d '\n')
      scores="$scores $clean"
    fi
  done

  if [ -n "$scores" ]; then
    result=$(echo "$scores" | jq -s '
      def avg(f): [.[] | f // empty] | if length > 0 then (add / length * 10 | round) / 10 else 0 end;
      {c: avg(.correctness), cm: avg(.completeness), v: avg(.valkey_awareness), p: avg(.production_quality), s: avg(.specificity)}
    ' 2>/dev/null)

    if [ -n "$result" ] && [ "$result" != "null" ]; then
      task=$(echo "$label" | cut -d_ -f1-2)
      model=$(echo "$label" | sed 's/.*_\(sonnet-4-6\|opus\)_.*/\1/')
      skills=$(echo "$label" | sed 's/.*_//')
      c=$(echo "$result" | jq -r '.c')
      cm=$(echo "$result" | jq -r '.cm')
      v=$(echo "$result" | jq -r '.v')
      p=$(echo "$result" | jq -r '.p')
      s=$(echo "$result" | jq -r '.s')
      avg=$(echo "$c $cm $v $p $s" | awk '{printf "%.1f", ($1+$2+$3+$4+$5)/5}')
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | **%s** |\n" \
        "$task" "$model" "$skills" "$c" "$cm" "$v" "$p" "$s" "$avg"
    fi
  fi
done

} > "$RESULTS_FILE"

echo ""
cat "$RESULTS_FILE"
echo ""
echo "Full results in $RUNS_DIR/"
