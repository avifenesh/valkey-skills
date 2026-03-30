#!/bin/bash
# Benchmark: valkey-skills with/without skills, sonnet vs opus
set +e  # Don't exit on individual task failures

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$BENCH_DIR")"
RESULTS_DIR="$BENCH_DIR/results"
mkdir -p "$RESULTS_DIR"

# Task prompts
read -r -d '' TASK1 << 'TASK1END' || true
Write a cache-aside layer for a Node.js CRUD API using Valkey GLIDE as the client. The API manages user profiles (create, read, update, delete). Requirements: Use Valkey GLIDE (not ioredis or node-redis). Cache-aside pattern: read from cache first, fallback to DB, populate cache on miss. Cache invalidation on write/update/delete. TTL-based expiration (configurable per entity type). Handle connection failures gracefully (app works without cache). Use GLIDE cluster mode configuration. Include TypeScript types. Output: the cache layer module code and a usage example showing integration with an Express route handler.
TASK1END

read -r -d '' TASK2 << 'TASK2END' || true
Write Kubernetes manifests to deploy a 3-primary, 3-replica Valkey cluster with the valkey-search module enabled. Requirements: StatefulSet-based deployment. Persistent volume claims for data. ConfigMap for valkey.conf with search module loaded. Service for client connections. Resource limits and readiness probes. TLS enabled between nodes. The cluster should auto-initialize on first boot. Include a test job that creates a search index and runs a query to verify the deployment. Output: all YAML manifests and a brief deployment guide.
TASK2END

read -r -d '' TASK3 << 'TASK3END' || true
You are investigating a production issue in a 6-node Valkey cluster (3 primaries, 3 replicas) running 9.0.3. After a network partition heals, two nodes both claim to be primary for the same slots. CLUSTER INFO shows cluster_state:ok but CLUSTER NODES shows overlapping slot ownership. The currentEpoch on the two conflicting nodes is the same value - it appears the epoch did not advance during the failover that happened during the partition. Walk through the Valkey source code to investigate: Where does the currentEpoch get incremented during failover? What are the conditions that must be met for the increment to happen? What could prevent the epoch from advancing (causing both nodes to believe they own the same slots)? What specific functions and source files are involved? Output: a root cause analysis tracing through the actual C source code, identifying the specific code path where the epoch should have been incremented, and what condition was not met.
TASK3END

TASKS=("$TASK1" "$TASK2" "$TASK3")
TASK_NAMES=("cache-layer" "k8s-cluster" "epoch-bug")

run_task() {
  local model="$1"
  local skills="$2"
  local task_num="$3"
  local task_prompt="${TASKS[$((task_num-1))]}"
  local label="${model}_${skills}_task${task_num}"
  local outfile="$RESULTS_DIR/${label}.json"

  echo "[RUN] model=$model skills=$skills task=$task_num (${TASK_NAMES[$((task_num-1))]})"

  claude -p "$task_prompt" \
    --model "$model" \
    --output-format json \
    --max-turns 30 \
    --dangerously-skip-permissions \
    > "$outfile" 2>/dev/null

  # Extract metrics
  local dur=$(jq -r '.duration_ms // 0' "$outfile")
  local dur_s=$((dur / 1000))
  local cost=$(jq -r '.total_cost_usd // 0' "$outfile")
  local turns=$(jq -r '.num_turns // 0' "$outfile")
  local tokens_in=$(jq -r '[.modelUsage[]] | .[0].inputTokens // 0' "$outfile" 2>/dev/null || echo 0)
  local tokens_out=$(jq -r '[.modelUsage[]] | .[0].outputTokens // 0' "$outfile" 2>/dev/null || echo 0)

  # Save result text
  jq -r '.result // ""' "$outfile" > "$RESULTS_DIR/${label}.txt"

  echo "  ${dur_s}s | in:${tokens_in} out:${tokens_out} | turns:${turns} | \$${cost}"
}

judge_task() {
  local model="$1"
  local skills="$2"
  local task_num="$3"
  local run="$4"
  local label="${model}_${skills}_task${task_num}"
  local response=$(cat "$RESULTS_DIR/${label}.txt")
  local judge_out="$RESULTS_DIR/judge_${label}_r${run}.json"

  claude -p "You are a code review judge. Score this AI-generated response on 5 criteria, each 1-10. Return ONLY valid JSON, no markdown, no explanation.

{\"correctness\": N, \"completeness\": N, \"valkey_awareness\": N, \"production_quality\": N, \"specificity\": N}

correctness: Does the code compile/work? Are APIs used correctly?
completeness: All requirements covered?
valkey_awareness: Uses Valkey-specific knowledge, not Redis patterns? Correct API names?
production_quality: Error handling, security, edge cases?
specificity: Concrete code and actual function/struct names vs generic descriptions?

Response to judge:

$response" \
    --model us.anthropic.claude-sonnet-4-6 \
    --output-format json \
    --max-turns 1 \
    --dangerously-skip-permissions \
    2>/dev/null | jq -r '.result // ""' > "$judge_out"
}

echo "============================================"
echo "  Valkey Skills Benchmark"
echo "  $(date)"
echo "============================================"

# Phase 1: Remove skills
echo ""
echo "=== PHASE 1: WITHOUT SKILLS ==="
rm -rf "$REPO_DIR/.agents" 2>/dev/null || true

for model in us.anthropic.claude-sonnet-4-6 opus; do
  echo ""
  echo "--- $model without skills ---"
  for task in 1 2 3; do
    run_task "$model" "without" "$task"
  done
done

# Phase 2: Install skills
echo ""
echo "=== PHASE 2: WITH SKILLS ==="
cd "$REPO_DIR" && npx skills add avifenesh/valkey-skills --yes 2>/dev/null && cd "$BENCH_DIR"

for model in us.anthropic.claude-sonnet-4-6 opus; do
  echo ""
  echo "--- $model with skills ---"
  for task in 1 2 3; do
    run_task "$model" "with" "$task"
  done
done

# Phase 3: Judge all
echo ""
echo "=== PHASE 3: JUDGING (3 runs each) ==="
for model in us.anthropic.claude-sonnet-4-6 opus; do
  for skills in without with; do
    for task in 1 2 3; do
      echo "Judging ${model}/${skills}/task${task}..."
      for run in 1 2 3; do
        judge_task "$model" "$skills" "$task" "$run"
      done
    done
  done
done

# Phase 4: Compile
echo ""
echo "=== RESULTS ==="

{
echo "# Benchmark Results - $(date '+%Y-%m-%d')"
echo ""
echo "## Metrics"
echo ""
echo "| Model | Skills | Task | Duration | In Tokens | Out Tokens | Turns | Cost |"
echo "|-------|--------|------|----------|-----------|------------|-------|------|"

for model in us.anthropic.claude-sonnet-4-6 opus; do
  for skills in without with; do
    for task in 1 2 3; do
      f="$RESULTS_DIR/${model}_${skills}_task${task}.json"
      if [ -f "$f" ]; then
        dur=$(jq -r '.duration_ms // 0' "$f")
        dur_s=$((dur / 1000))
        cost=$(jq -r '.total_cost_usd // 0' "$f")
        turns=$(jq -r '.num_turns // 0' "$f")
        tin=$(jq -r '[.modelUsage[]] | .[0].inputTokens // 0' "$f" 2>/dev/null || echo 0)
        tout=$(jq -r '[.modelUsage[]] | .[0].outputTokens // 0' "$f" 2>/dev/null || echo 0)
        printf "| %s | %s | %s | %ss | %s | %s | %s | \$%s |\n" \
          "$model" "$skills" "${TASK_NAMES[$((task-1))]}" "$dur_s" "$tin" "$tout" "$turns" "$cost"
      fi
    done
  done
done

echo ""
echo "## Quality Scores (avg of 3 judges)"
echo ""
echo "| Model | Skills | Task | Correct | Complete | Valkey | Prod | Specific | Avg |"
echo "|-------|--------|------|---------|----------|--------|------|----------|-----|"

for model in us.anthropic.claude-sonnet-4-6 opus; do
  for skills in without with; do
    for task in 1 2 3; do
      label="${model}_${skills}_task${task}"
      scores=""
      for run in 1 2 3; do
        f="$RESULTS_DIR/judge_${label}_r${run}.json"
        [ -f "$f" ] && scores="$scores $(cat "$f")"
      done
      if [ -n "$scores" ]; then
        avg_line=$(echo "$scores" | jq -s '
          def avg(f): [.[] | f] | if length > 0 then add / length | . * 10 | round / 10 else 0 end;
          {
            c: avg(.correctness),
            cm: avg(.completeness),
            v: avg(.valkey_awareness),
            p: avg(.production_quality),
            s: avg(.specificity)
          } | "\(.c)|\(.cm)|\(.v)|\(.p)|\(.s)"
        ' 2>/dev/null || echo "N/A|N/A|N/A|N/A|N/A")
        IFS='|' read -r c cm v p s <<< "$avg_line"
        total=$(echo "$c $cm $v $p $s" | awk '{printf "%.1f", ($1+$2+$3+$4+$5)/5}')
        printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
          "$model" "$skills" "${TASK_NAMES[$((task-1))]}" "$c" "$cm" "$v" "$p" "$s" "$total"
      fi
    done
  done
done

} > "$RESULTS_DIR/summary.md"

cat "$RESULTS_DIR/summary.md"
echo ""
echo "Full results in $RESULTS_DIR/"
