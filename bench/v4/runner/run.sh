#!/bin/bash
# V4 Benchmark Runner
# Usage: run.sh <model_id> <model_name>
# Runs all 10 tasks in parallel, both noskill and skill conditions (20 agents)

set -uo pipefail
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

MODEL_ID="${1:?Usage: run.sh <model_id> <model_name>}"
MODEL_NAME="${2:?Usage: run.sh <model_id> <model_name>}"

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
TASKS_DIR="$REPO/bench/v4/tasks"
BASE="/tmp/bench_v4_${MODEL_NAME}"
RESULTS="$REPO/bench/v4/results/${MODEL_NAME}"

rm -rf "$BASE" "$RESULTS"
mkdir -p "$RESULTS"

TASKS=$(ls -d "$TASKS_DIR"/*/ | xargs -I{} basename {})

echo "=========================================="
echo "  V4 BENCHMARK: $MODEL_NAME"
echo "  Model: $MODEL_ID"
echo "  Started: $(date)"
echo "=========================================="

# --- Setup phase ---
echo ""
echo "=== SETUP ==="

for task in $TASKS; do
  task_dir="$TASKS_DIR/$task"

  for cond in noskill skill; do
    d="$BASE/${task}_${cond}"
    mkdir -p "$d"

    # Copy workspace files
    if [ -d "$task_dir/workspace" ]; then
      cp -r "$task_dir/workspace/"* "$d/" 2>/dev/null || true
    fi

    # Run setup script if exists
    if [ -f "$task_dir/setup.sh" ]; then
      # setup.sh expects to put files in its own workspace/
      # We need to adapt: clone into our temp dir
      case "$task" in
        5-bloom-feature)
          if [ ! -d "$d/valkey-bloom" ]; then
            git clone --depth 1 https://github.com/valkey-io/valkey-bloom.git "$d/valkey-bloom" 2>/dev/null || true
          fi
          ;;
        6-search-queries)
          # No repo clone needed - uses docker valkey-bundle
          ;;
      esac
    fi

    # Copy skills for skill condition
    if [ "$cond" = "skill" ]; then
      mkdir -p "$d/.claude/skills"
      if [ -f "$task_dir/skills.txt" ]; then
        while IFS= read -r skill_path; do
          [ -z "$skill_path" ] && continue
          skill_name=$(basename "$skill_path")
          if [ -d "$REPO/$skill_path" ]; then
            cp -r "$REPO/$skill_path" "$d/.claude/skills/$skill_name"
          fi
        done < "$task_dir/skills.txt"
      fi
    fi

    # Remove any .git directories (prevent cheating via git history)
    find "$d" -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true

    skill_count=$(find "$d/.claude/skills" -name "SKILL.md" 2>/dev/null | wc -l)
    echo "  [SETUP] ${task}_${cond}: $(find "$d" -type f | wc -l) files, $skill_count skills"
  done
done

# --- Agent phase ---
echo ""
echo "=== AGENTS (20 parallel) ==="

for task in $TASKS; do
  task_dir="$TASKS_DIR/$task"
  prompt=$(cat "$task_dir/prompt.md")

  for cond in noskill skill; do
    d="$BASE/${task}_${cond}"
    rd="$RESULTS/${task}_${cond}"
    mkdir -p "$rd"

    echo "[RUN] ${task}_${cond}"
    (
      cd "$d"
      claude -p "$prompt" \
        --max-turns 60 \
        --model "$MODEL_ID" \
        --output-format json \
        --dangerously-skip-permissions \
        > "$rd/agent_output.json" 2>"$rd/agent_stderr.log"
      echo "[AGENT-DONE] ${task}_${cond}"
    ) &
  done
done

wait
echo ""
echo "=== All 20 agents done ($(date)) ==="

# --- Test phase ---
echo ""
echo "=== TESTS ==="

for task in $TASKS; do
  task_dir="$TASKS_DIR/$task"

  for cond in noskill skill; do
    d="$BASE/${task}_${cond}"
    rd="$RESULTS/${task}_${cond}"

    if [ ! -s "$rd/agent_output.json" ]; then
      echo "[SKIP] ${task}_${cond} (no output)"
      continue
    fi

    bash "$task_dir/test.sh" "$d" > "$rd/test_output.txt" 2>&1 || true

    pass=$(grep -c "^PASS:" "$rd/test_output.txt" 2>/dev/null || true)
    total=$(grep -cE "^PASS:|^FAIL:" "$rd/test_output.txt" 2>/dev/null || true)

    cost=$(python3 -c "import json; a=json.load(open('$rd/agent_output.json')); print(round(a.get('total_cost_usd',0),2))" 2>/dev/null || echo "?")
    turns=$(python3 -c "import json; a=json.load(open('$rd/agent_output.json')); print(a.get('num_turns',0))" 2>/dev/null || echo "?")

    echo "[TEST] ${task}_${cond}: $pass/$total  cost=\$$cost  turns=$turns"
  done
done

# --- Summary ---
echo ""
echo "=========================================="
echo "  SUMMARY: $MODEL_NAME"
echo "=========================================="

python3 -c "
import json, os, glob

results_dir = '$RESULTS'
tasks = sorted(set(
    '_'.join(os.path.basename(d).split('_')[:-1])
    for d in glob.glob(results_dir + '/*/')
))

print()
print('%-25s %8s %8s %6s %7s %7s %6s %6s' % ('TASK','NOSKILL','SKILL','DELTA','NS\$','S\$','NSTrn','STrn'))
print('-' * 90)

tnp = tsp = 0
for task in tasks:
    r = {}
    for cond in ['noskill', 'skill']:
        d = os.path.join(results_dir, task + '_' + cond)
        p = t = turns = 0; cost = 0.0
        out = os.path.join(d, 'agent_output.json')
        tf = os.path.join(d, 'test_output.txt')
        if os.path.exists(out) and os.path.getsize(out) > 100:
            a = json.load(open(out))
            turns = a.get('num_turns', 0)
            cost = a.get('total_cost_usd', 0)
        if os.path.exists(tf):
            txt = open(tf).read()
            p = txt.count('PASS:')
            t = txt.count('PASS:') + txt.count('FAIL:')
        r[cond] = {'p': p, 't': t, 'cost': cost, 'turns': turns}
    ns = r['noskill']; sk = r['skill']
    delta = sk['p'] - ns['p']
    tnp += ns['p']; tsp += sk['p']
    ds = ('+' + str(delta)) if delta >= 0 else str(delta)
    print('%-25s %3d/%-4d %3d/%-4d %5s  %5.2f  %5.2f  %5d  %5d' % (
        task, ns['p'], ns['t'], sk['p'], sk['t'], ds,
        ns['cost'], sk['cost'], ns['turns'], sk['turns']))

print('-' * 90)
dd = tsp - tnp
ds = ('+' + str(dd)) if dd >= 0 else str(dd)
print('%-25s %8d %8d %5s' % ('TOTAL', tnp, tsp, ds))
"

echo ""
echo "=== $MODEL_NAME COMPLETE ($(date)) ==="
