#!/usr/bin/env python3
"""Summarize benchmark results with weighted scoring."""

import json
import os
import sys
from pathlib import Path
from collections import defaultdict

RESULTS_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("results")

# Scoring weights
W_CORRECTNESS = 3  # tests_passed / tests_total * 3
W_JUDGE = 1        # judge_score / 10 * 1
W_TIME = 1         # time score * 1
W_COST = 1         # cost score * 1
MAX_SCORE = W_CORRECTNESS + W_JUDGE + W_TIME + W_COST  # 6.0

# Time/cost budgets per task (seconds, dollars)
TIME_BUDGETS = {
    "1-valkey-bug": 600,
    "2-glide-nodejs-app": 900,
    "3-ops-hardening": 600,
    "4-rust-module": 900,
    "5-bloom-feature": 600,
    "6-redis-py-migration": 600,
    "7-search-debug": 600,
    "8-json-operations": 600,
    "9-bloom-capacity": 600,
    "10-spring-java": 900,
}
COST_BUDGET_LOW = 1.0   # full score at or below
COST_BUDGET_HIGH = 5.0  # zero score at or above


def time_score(duration, task):
    budget = TIME_BUDGETS.get(task, 600)
    if duration <= budget:
        return 1.0
    elif duration >= budget * 3:
        return 0.0
    else:
        return 1.0 - (duration - budget) / (budget * 2)


def cost_score(cost):
    if cost <= COST_BUDGET_LOW:
        return 1.0
    elif cost >= COST_BUDGET_HIGH:
        return 0.0
    else:
        return 1.0 - (cost - COST_BUDGET_LOW) / (COST_BUDGET_HIGH - COST_BUDGET_LOW)


def compute_total(meta):
    corr = (meta["tests_passed"] / max(meta["tests_total"], 1)) * W_CORRECTNESS
    judge = (meta.get("judge_score", 0) / 10) * W_JUDGE
    t = time_score(meta["duration_secs"], meta["task"]) * W_TIME
    c = cost_score(meta["cost_usd"]) * W_COST
    return {
        "correctness": round(corr, 2),
        "judge": round(judge, 2),
        "time": round(t, 2),
        "cost": round(c, 2),
        "total": round(corr + judge + t + c, 2),
    }


def main():
    results = []
    for run_dir in sorted(RESULTS_DIR.iterdir()):
        meta_file = run_dir / "metadata.json"
        if not meta_file.exists():
            continue
        with open(meta_file) as f:
            meta = json.load(f)
        scores = compute_total(meta)
        meta["scores"] = scores
        results.append(meta)

    if not results:
        print("No results found.")
        return

    # Group by task + condition
    groups = defaultdict(list)
    for r in results:
        key = (r["task"], r["model"], r["condition"])
        groups[key].append(r)

    # Print summary table
    print(f"\n{'Task':<25} {'Model':<8} {'Cond':<8} {'Tests':<8} {'Judge':<6} "
          f"{'Time':<6} {'Cost':<7} {'Total':<6} {'Dur':<6} {'$':<6}")
    print("-" * 100)

    task_order = sorted(set(r["task"] for r in results))
    for task in task_order:
        for model in ["sonnet", "opus"]:
            for condition in ["noskill", "skill"]:
                key = (task, model, condition)
                runs = groups.get(key, [])
                if not runs:
                    continue

                # Average across runs
                avg_tests = sum(r["tests_passed"] for r in runs) / len(runs)
                avg_total_tests = sum(r["tests_total"] for r in runs) / len(runs)
                avg_judge = sum(r.get("judge_score", 0) for r in runs) / len(runs)
                avg_dur = sum(r["duration_secs"] for r in runs) / len(runs)
                avg_cost = sum(r["cost_usd"] for r in runs) / len(runs)
                avg_score = sum(r["scores"]["total"] for r in runs) / len(runs)

                tests_str = f"{avg_tests:.1f}/{avg_total_tests:.0f}"
                print(f"{task:<25} {model:<8} {condition:<8} {tests_str:<8} "
                      f"{avg_judge:<6.1f} {avg_dur:<6.0f}s ${avg_cost:<6.2f} "
                      f"{avg_score:<6.2f}/{MAX_SCORE}")
        print()

    # Skill vs no-skill delta
    print("\n=== Skill Impact (delta) ===\n")
    print(f"{'Task':<25} {'Model':<8} {'Tests':<10} {'Judge':<8} {'Total':<8}")
    print("-" * 65)

    for task in task_order:
        for model in ["sonnet", "opus"]:
            ns = groups.get((task, model, "noskill"), [])
            sk = groups.get((task, model, "skill"), [])
            if not ns or not sk:
                continue
            ns_score = sum(r["scores"]["total"] for r in ns) / len(ns)
            sk_score = sum(r["scores"]["total"] for r in sk) / len(sk)
            ns_tests = sum(r["tests_passed"] for r in ns) / len(ns)
            sk_tests = sum(r["tests_passed"] for r in sk) / len(sk)
            ns_judge = sum(r.get("judge_score", 0) for r in ns) / len(ns)
            sk_judge = sum(r.get("judge_score", 0) for r in sk) / len(sk)

            delta_tests = sk_tests - ns_tests
            delta_judge = sk_judge - ns_judge
            delta_total = sk_score - ns_score

            sign_t = "+" if delta_tests >= 0 else ""
            sign_j = "+" if delta_judge >= 0 else ""
            sign_s = "+" if delta_total >= 0 else ""

            print(f"{task:<25} {model:<8} {sign_t}{delta_tests:<9.1f} "
                  f"{sign_j}{delta_judge:<7.1f} {sign_s}{delta_total:<7.2f}")


if __name__ == "__main__":
    main()
