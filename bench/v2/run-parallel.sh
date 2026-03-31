#!/bin/bash
# Benchmark: 3 rounds x 16 parallel agents
# Round-numbered output: {label}_r{1,2,3}.json

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$BENCH_DIR/../../skills"
RUNS_DIR="$BENCH_DIR/runs"
TESTS_DIR="$BENCH_DIR/tests"
TMP="${TMPDIR:-/tmp}/bench-v2-parallel"
SONNET="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
OPUS="us.anthropic.claude-opus-4-6-v1[1m]"

mkdir -p "$RUNS_DIR"

TASK_DIRS=("1-bug-investigation" "2-glide-queue" "3-ops-cluster" "4-code-improvement")
TASK_LABELS=("1-bug" "2-queue" "3-ops" "4-improve")
TASK_TESTS=("test-bug.sh" "test-queue.sh" "test-ops.sh" "test-improvement.sh")
TASK_SKILLS=("valkey-dev" "valkey-glide/nodejs" "valkey-ops:valkey-modules" "valkey")
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

run_one() {
  local task_idx="$1" model="$2" skills="$3" round="$4"
  local task_dir="${TASK_DIRS[$task_idx]}"
  local task_label="${TASK_LABELS[$task_idx]}"
  local prompt="${TASK_PROMPTS[$task_idx]}"
  local skill_spec="${TASK_SKILLS[$task_idx]}"
  local max_turns="${TASK_TURNS[$task_idx]}"
  local model_short=$([ "$model" = "$SONNET" ] && echo "sonnet" || echo "opus")
  local label="${task_label}_${model_short}_${skills}"
  local run_dir="$TMP/r${round}/${label}"
  local out_json="$RUNS_DIR/${label}_r${round}.json"

  # Skip if already done
  if [ -f "$out_json" ] && [ -s "$out_json" ]; then
    local prev_cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
    if [ "$prev_cost" != "0" ]; then
      echo "[R$round SKIP] $label"
      return
    fi
  fi

  # Setup fresh dir
  rm -r "$run_dir" 2>/dev/null
  mkdir -p "$TMP/r${round}"
  cp -r "$BENCH_DIR/tasks/$task_dir" "$run_dir"

  if [ "$skills" = "skill" ]; then
    install_skills "$run_dir" "$skill_spec"
  fi

  # Clear Claude cache
  find "$HOME/.claude/projects" -maxdepth 1 -name "*bench-v2*" -type d -exec rm -r {} + 2>/dev/null || true

  # Run agent
  echo "[R$round START] $label"
  cd "$run_dir"
  claude -p "$prompt" \
    --model "$model" \
    --output-format json \
    --max-turns "$max_turns" \
    --no-session-persistence \
    --dangerously-skip-permissions \
    > "$out_json" 2>/dev/null || true
  cd "$BENCH_DIR"

  # Check for model errors
  local is_err=$(jq -r '.is_error // false' "$out_json" 2>/dev/null)
  local cost=$(jq -r '.total_cost_usd // 0' "$out_json" 2>/dev/null)
  local dur=$(jq -r '.duration_ms // 0' "$out_json" 2>/dev/null)
  local turns=$(jq -r '.num_turns // 0' "$out_json" 2>/dev/null)

  if [ "$cost" = "0" ] && [ "$turns" = "1" ]; then
    echo "[R$round ERROR] $label - model failed, 0 cost"
    return
  fi

  jq -r '.result // ""' "$out_json" > "$RUNS_DIR/${label}_r${round}.txt" 2>/dev/null
  echo "[R$round DONE] $label - $((dur/1000))s, \$$cost, $turns turns"

  # Cleanup Docker
  (cd "$run_dir" && docker compose down -v 2>/dev/null) || true

  # Run test
  bash "$TESTS_DIR/${TASK_TESTS[$task_idx]}" "$run_dir" 2>&1 | tee "$RUNS_DIR/${label}_r${round}_test.txt"

  # Run 3 judges
  local task=$(echo "$label" | cut -d_ -f1)
  local input=""
  case "$task" in
    1-bug) for f in "$run_dir/ANALYSIS.md" "$run_dir/analysis.md"; do [ -f "$f" ] && input=$(cat "$f") && break; done ;;
    2-queue) input=$(find "$run_dir" -name "app.js" | grep -v node_modules | xargs cat 2>/dev/null) ;;
    3-ops) input=$(find "$run_dir" -maxdepth 2 \( -name "*.yaml" -o -name "*.yml" -o -name "*.sh" \) ! -name "docker-compose.yml" 2>/dev/null | head -15 | xargs cat 2>/dev/null) ;;
    4-improve) for f in "$run_dir/ANSWERS.md" "$run_dir/answers.md"; do [ -f "$f" ] && input=$(cat "$f") && break; done ;;
  esac

  if [ -n "$input" ] && [ ${#input} -gt 30 ]; then
    for j in 1 2 3; do
      local jout="$RUNS_DIR/judge_${label}_r${round}_j${j}.json"
      local tmpfile=$(mktemp)
      cat > "$tmpfile" << 'CRITERIA'
You are a code review judge. Score this AI-generated output on 5 criteria, each 1-10. Return ONLY valid JSON.
{"correctness": N, "completeness": N, "valkey_awareness": N, "production_quality": N, "specificity": N}
CRITERIA
      echo "$input" | head -500 >> "$tmpfile"
      cat "$tmpfile" | claude -p - --model "$OPUS" --output-format json --max-turns 1 --no-session-persistence --dangerously-skip-permissions 2>/dev/null | jq -r '.result // ""' > "$jout" || true
      rm -f "$tmpfile"
    done
  fi

  echo "[R$round COMPLETE] $label"
}

echo "============================================"
echo "  Benchmark - 3 Rounds x 16 Parallel"
echo "  $(date)"
echo "============================================"

# Pre-build buggy Valkey image
echo "=== PRE-BUILD ==="
docker build -t buggy-valkey:latest \
  -f "$BENCH_DIR/tasks/1-bug-investigation/Dockerfile.buggy-valkey" \
  "$BENCH_DIR/tasks/1-bug-investigation/" 2>&1 | tail -3

for round in 1 2 3; do
  echo ""
  echo "========================================="
  echo "  ROUND $round / 3 - $(date)"
  echo "========================================="

  PIDS=()
  for task_idx in 0 1 2 3; do
    for model in "$SONNET" "$OPUS"; do
      for skills in "noskill" "skill"; do
        run_one "$task_idx" "$model" "$skills" "$round" &
        PIDS+=($!)
      done
    done
  done

  echo "  Launched ${#PIDS[@]} agents for round $round"
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null; done

  # Count results
  done_count=$(ls "$RUNS_DIR"/*_r${round}.json 2>/dev/null | while read f; do
    cost=$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null)
    [ "$cost" != "0" ] && echo "1"
  done | wc -l)
  echo "[ROUND $round] $done_count/16 completed"
done

echo ""
echo "========================================="
echo "  FINAL RESULTS - MEDIAN OF 3"
echo "========================================="

printf "%-30s | %5s %5s %5s | %6s | %8s | median\n" "Run" "R1" "R2" "R3" "Time" "Cost"
echo "-------------------------------+-------------------+--------+----------+-------"

for task_idx in 0 1 2 3; do
  for model_short in "sonnet" "opus"; do
    for skills in "noskill" "skill"; do
      label="${TASK_LABELS[$task_idx]}_${model_short}_${skills}"
      scores=() times=() costs=()

      for r in 1 2 3; do
        f="$RUNS_DIR/${label}_r${r}.json"
        tf="$RUNS_DIR/${label}_r${r}_test.txt"
        if [ -f "$f" ] && [ -s "$f" ]; then
          cost=$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null)
          [ "$cost" = "0" ] && scores+=("-") && times+=("-") && costs+=("-") && continue
          dur=$(jq -r '.duration_ms // 0' "$f" 2>/dev/null)
          score=$(grep "^SCORE=" "$tf" 2>/dev/null | tail -1 | cut -d= -f2 | cut -d/ -f1)
          scores+=("${score:-0}")
          times+=("$((dur/1000))")
          costs+=("$cost")
        else
          scores+=("-") && times+=("-") && costs+=("-")
        fi
      done

      med_score=$(printf '%s\n' "${scores[@]}" | grep -v "^-$" | sort -n | sed -n '2p')
      med_time=$(printf '%s\n' "${times[@]}" | grep -v "^-$" | sort -n | sed -n '2p')
      med_cost=$(printf '%s\n' "${costs[@]}" | grep -v "^-$" | sort -n | sed -n '2p')

      printf "%-30s | %5s %5s %5s | %5ss | \$%-7s | med=%s\n" \
        "$label" "${scores[0]}" "${scores[1]}" "${scores[2]}" \
        "${med_time:-?}" "${med_cost:-?}" "${med_score:-?}"
    done
  done
done
