#!/bin/bash
# Re-judge all runs using actual code files instead of .result text
# Fixes the empty-result problem where agents wrote code but returned no summary

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="$BENCH_DIR/runs"
TMP="${TMPDIR:-/tmp}/bench-v2"
SONNET="sonnet"

TASK_LABELS=("1-bug" "2-lock" "3-ops" "4-improve")

# Build judge input per task type from actual files in the run directory
build_judge_input() {
  local label="$1"
  local run_dir="$TMP/$label"
  local task=$(echo "$label" | cut -d_ -f1)
  local input=""

  case "$task" in
    1-bug)
      # Bug: judge the ANALYSIS.md + any .md the agent wrote
      for f in "$run_dir/ANALYSIS.md" "$run_dir/analysis.md"; do
        [ -f "$f" ] && input="$input$(cat "$f")"$'\n'
      done
      # Also include any .md files not in the original task
      for f in "$run_dir"/*.md; do
        bn=$(basename "$f")
        [ "$bn" = "symptoms.md" ] && continue
        [ "$bn" = "README.md" ] && continue
        [ "$bn" = "ANALYSIS.md" ] && continue
        [ "$bn" = "analysis.md" ] && continue
        [ -f "$f" ] && input="$input$(cat "$f")"$'\n'
      done
      ;;
    2-lock)
      # Lock: judge all Java source files
      input=$(find "$run_dir/src" -name "*.java" 2>/dev/null | sort | xargs cat 2>/dev/null)
      ;;
    3-ops)
      # Ops: judge YAML manifests + shell scripts + config files
      input=$(find "$run_dir" -maxdepth 2 \( -name "*.yaml" -o -name "*.yml" -o -name "*.sh" -o -name "*.conf" \) ! -name "docker-compose.yml" 2>/dev/null | sort | while read f; do echo "=== $(basename "$f") ==="; cat "$f"; echo; done)
      ;;
    4-improve)
      # Improve: judge the app.js (the improved code)
      input=$(cat "$run_dir/app.js" 2>/dev/null)
      ;;
  esac

  echo "$input"
}

# Task-specific judge criteria
judge_criteria() {
  local task="$1"
  case "$task" in
    1-bug)
      echo "This is a bug investigation report for a Valkey cluster split-brain issue caused by a missing epoch increment in cluster_legacy.c during failover.
Judge: Does the analysis correctly identify the root cause? Does it reference the correct file (cluster_legacy.c), function (clusterRequestFailoverAuth), and mechanism (currentEpoch increment)? Is the proposed fix correct?"
      ;;
    2-lock)
      echo "This is a distributed lock implementation using Valkey GLIDE Java client.
Judge: Does it use GlideClient/GlideClusterClient (not Jedis/Lettuce)? Uses SET NX with TTL (not deprecated SETNX)? Has owner identification (UUID)? Safe release via compare-and-delete (IFEQ or Lua, not plain DEL)? Retry with backoff? Are GLIDE API signatures correct?"
      ;;
    3-ops)
      echo "This is a Kubernetes deployment for a production Valkey cluster (3 primary + 3 replica).
Judge: Has StatefulSet? ACL users (admin, app, monitor)? TLS config? valkey-search module loaded? Uses valkey-cli (not redis-cli) in probes? PodDisruptionBudget? Persistent storage? Prometheus exporter? Anti-affinity rules?"
      ;;
    4-improve)
      echo "This is improved Valkey GLIDE Node.js code. The original had 7 anti-patterns: KEYS instead of SCAN, DEL instead of UNLINK, individual GETs instead of MGET, sequential SETs instead of batch, no TTL on cache, no connection error handling, client-side sort instead of sorted sets.
Judge: How many anti-patterns were fixed? Is the code correct? Are Valkey-specific best practices applied?"
      ;;
  esac
}

echo "=== Re-judging all runs with actual code ==="

for label_prefix in "${TASK_LABELS[@]}"; do
  task=$(echo "$label_prefix" | cut -d- -f1)

  for model_short in "sonnet" "opus"; do
    for skills in "noskill" "skill"; do
      label="${label_prefix}_${model_short}_${skills}"
      run_dir="$TMP/$label"

      [ ! -d "$run_dir" ] && echo "  [SKIP] $label (no directory)" && continue

      # Build judge input from actual files
      judge_input=$(build_judge_input "$label")

      if [ -z "$judge_input" ] || [ ${#judge_input} -lt 50 ]; then
        echo "  [SKIP] $label (no meaningful output files)"
        continue
      fi

      criteria=$(judge_criteria "$label_prefix")

      for run in 1 2 3; do
        judge_out="$RUNS_DIR/judge_${label}_r${run}.json"

        # Always re-judge (overwrite)
        tmpfile=$(mktemp)
        cat > "$tmpfile" << CRITERIA
You are a code review judge. Score this AI-generated code on 5 criteria, each 1-10. Return ONLY valid JSON, no markdown, no explanation.

{"correctness": N, "completeness": N, "valkey_awareness": N, "production_quality": N, "specificity": N}

correctness: Does the code work? Are APIs used correctly? No syntax errors?
completeness: All requirements covered?
valkey_awareness: Uses Valkey-specific knowledge, not Redis patterns? Correct binary/CLI names?
production_quality: Error handling, security, edge cases, resource cleanup?
specificity: Concrete implementation vs vague suggestions? Real function names vs generic?

$criteria

Code to judge:

CRITERIA
        echo "$judge_input" | head -500 >> "$tmpfile"

        cat "$tmpfile" | claude -p - \
          --model "$SONNET" \
          --output-format json \
          --max-turns 1 \
          --dangerously-skip-permissions \
          2>/dev/null | jq -r '.result // ""' > "$judge_out" || true

        rm -f "$tmpfile"
        echo "  Judge $run/$label"
      done
    done
  done
done

echo ""
echo "=== Computing final scores ==="

for label_prefix in "${TASK_LABELS[@]}"; do
  echo ""
  echo "--- $label_prefix ---"
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
        printf "  %-30s | C=%s Cm=%s V=%s P=%s S=%s | avg=%s\n" "$label" "$c" "$cm" "$v" "$p" "$s" "$total"
      fi
    done
  done
done
