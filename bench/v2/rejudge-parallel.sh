#!/bin/bash
# Re-judge all runs in parallel using actual code files

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="$BENCH_DIR/runs"
TMP="${TMPDIR:-/tmp}/bench-v2"
SONNET="sonnet"

build_judge_input() {
  local label="$1"
  local run_dir="$TMP/$label"
  local task=$(echo "$label" | cut -d_ -f1)

  case "$task" in
    1-bug)
      for f in "$run_dir/ANALYSIS.md" "$run_dir/analysis.md"; do
        [ -f "$f" ] && cat "$f" && return
      done
      find "$run_dir" -maxdepth 1 -name "*.md" ! -name "symptoms.md" ! -name "README.md" -exec cat {} + 2>/dev/null
      ;;
    2-lock)
      find "$run_dir/src" -name "*.java" 2>/dev/null | sort | xargs cat 2>/dev/null
      ;;
    3-ops)
      find "$run_dir" -maxdepth 2 \( -name "*.yaml" -o -name "*.yml" -o -name "*.sh" -o -name "*.conf" \) ! -name "docker-compose.yml" 2>/dev/null | sort | while read f; do echo "=== $(basename "$f") ==="; cat "$f"; echo; done
      ;;
    4-improve)
      cat "$run_dir/app.js" 2>/dev/null
      ;;
  esac
}

judge_criteria() {
  local task="$1"
  case "$task" in
    1-bug) echo "Bug investigation for Valkey cluster split-brain caused by missing epoch increment in cluster_legacy.c. Judge: correct root cause? References cluster_legacy.c, clusterRequestFailoverAuth, currentEpoch? Fix proposed?" ;;
    2-lock) echo "Distributed lock using Valkey GLIDE Java. Judge: uses GlideClient (not Jedis)? SET NX with TTL? Owner UUID? Safe compare-and-delete release? Retry with backoff? Correct GLIDE signatures?" ;;
    3-ops) echo "K8s Valkey cluster (3+3). Judge: StatefulSet? ACL users? TLS? valkey-search module? valkey-cli probes (not redis-cli)? PDB? Persistent storage? Prometheus exporter?" ;;
    4-improve) echo "Improved Valkey GLIDE Node.js code. Original had 7 anti-patterns: KEYS->SCAN, DEL->UNLINK, GET->MGET, sequential->batch, no TTL, no error handling, client sort->sorted set. How many fixed?" ;;
  esac
}

run_judge() {
  local label="$1"
  local run_num="$2"
  local judge_out="$RUNS_DIR/judge_${label}_r${run_num}.json"
  local task=$(echo "$label" | cut -d_ -f1)

  local input=$(build_judge_input "$label")
  [ -z "$input" ] || [ ${#input} -lt 50 ] && return

  local criteria=$(judge_criteria "$task")
  local tmpfile=$(mktemp)

  cat > "$tmpfile" << CRITERIA
You are a code review judge. Score this AI-generated code on 5 criteria, each 1-10. Return ONLY valid JSON, no markdown, no explanation.

{"correctness": N, "completeness": N, "valkey_awareness": N, "production_quality": N, "specificity": N}

correctness: Does the code work? APIs correct? No syntax errors?
completeness: All requirements covered?
valkey_awareness: Valkey-specific knowledge, not Redis patterns?
production_quality: Error handling, security, edge cases?
specificity: Concrete implementation vs vague suggestions?

$criteria

Code to judge:

CRITERIA
  echo "$input" | head -500 >> "$tmpfile"

  cat "$tmpfile" | claude -p - \
    --model "$SONNET" \
    --output-format json \
    --max-turns 1 \
    --dangerously-skip-permissions \
    2>/dev/null | jq -r '.result // ""' > "$judge_out" || true

  rm -f "$tmpfile"
  echo "  [DONE] Judge $run_num/$label"
}

echo "=== Re-judging all runs in parallel ==="

PIDS=()

for label_prefix in "1-bug" "2-lock" "3-ops" "4-improve"; do
  for model_short in "sonnet" "opus"; do
    for skills in "noskill" "skill"; do
      label="${label_prefix}_${model_short}_${skills}"
      [ ! -d "$TMP/$label" ] && echo "  [SKIP] $label" && continue

      for run in 1 2 3; do
        run_judge "$label" "$run" &
        PIDS+=($!)
      done
    done
  done
done

echo "Launched ${#PIDS[@]} judge calls in parallel, waiting..."
for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null; done

echo ""
echo "=== Final Scores ==="
echo ""
printf "%-30s | %5s %5s %5s %5s %5s | %5s\n" "Run" "Corr" "Comp" "Valk" "Prod" "Spec" "Avg"
echo "-------------------------------+---------------------------------------+------"

for label_prefix in "1-bug" "2-lock" "3-ops" "4-improve"; do
  for model_short in "sonnet" "opus"; do
    for skills in "noskill" "skill"; do
      label="${label_prefix}_${model_short}_${skills}"
      scores=""
      for r in 1 2 3; do
        f="$RUNS_DIR/judge_${label}_r${r}.json"
        if [ -f "$f" ] && [ -s "$f" ]; then
          clean=$(cat "$f" | sed 's/```json//g; s/```//g' | tr -d '\n')
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
        printf "%-30s | %5s %5s %5s %5s %5s | %5s\n" "$label" "$c" "$cm" "$v" "$p" "$s" "$total"
      fi
    done
  done
done
