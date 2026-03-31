# Benchmark v2 Results - 2026-03-31

## Performance

| Task | Model | Skills | Duration | Cost | Turns |
|------|-------|--------|----------|------|-------|
| 1-bug_sonnet | sonnet | noskill | 694s | $1.15 | 9 |
| 1-bug_sonnet | sonnet | skill | 183s | $0.38 | 8 |
| 1-bug_opus | opus | noskill | 674s | $1.91 | 32 |
| 1-bug_opus | opus | skill | 529s | $1.49 | 30 |
| 2-lock_sonnet | sonnet | noskill | 3s | $0.83 | 1 |
| 2-lock_sonnet | sonnet | skill | 3s | $0.50 | 1 |
| 2-lock_opus | opus | noskill | 565s | $1.70 | 31 |
| 2-lock_opus | opus | skill | 304s | $0.86 | 20 |
| 3-ops_sonnet | sonnet | noskill | 814s | $1.29 | 21 |
| 3-ops_sonnet | sonnet | skill | 613s | $0.97 | 20 |
| 3-ops_opus | opus | noskill | 535s | $1.28 | 15 |
| 3-ops_opus | opus | skill | 673s | $1.83 | 24 |
| 4-improve_sonnet | sonnet | noskill | 318s | $0.54 | 22 |
| 4-improve_sonnet | sonnet | skill | 438s | $1.04 | 31 |
| 4-improve_opus | opus | noskill | 359s | $1.19 | 31 |
| 4-improve_opus | opus | skill | 312s | $1.81 | 31 |

## Validation Tests

| Task | Model | Skills | Score |
|------|-------|--------|-------|
| 1-bug_sonnet | sonnet | noskill | 6/6 |
| 1-bug_sonnet | sonnet | skill | 6/6 |
| 1-bug_opus | opus | noskill | 6/6 |
| 1-bug_opus | opus | skill | 6/6 |
| 2-lock_sonnet | sonnet | noskill | 7/7 |
| 2-lock_sonnet | sonnet | skill | 7/7 |
| 2-lock_opus | opus | noskill | 7/7 |
| 2-lock_opus | opus | skill | 7/7 |
| 3-ops_sonnet | sonnet | noskill | 8/9 |
| 3-ops_sonnet | sonnet | skill | 8/9 |
| 3-ops_opus | opus | noskill | 8/9 |
| 3-ops_opus | opus | skill | 8/9 |
| 4-improve_sonnet | sonnet | noskill | 3/7 |
| 4-improve_sonnet | sonnet | skill | 4/7 |
| 4-improve_opus | opus | noskill | 3/7 |
| 4-improve_opus | opus | skill | 4/7 |

## Quality Scores (avg of 3 judges)

| Task | Model | Skills | Correct | Complete | Valkey | Prod | Specific | Avg |
|------|-------|--------|---------|----------|--------|------|----------|-----|
| 1-bug_sonnet | sonnet | noskill | 9 | 8.3 | 7.7 | 7.3 | 9 | **8.3** |
| 1-bug_sonnet | sonnet | skill | 8.3 | 6.7 | 8.3 | 6 | 8.7 | **7.6** |
| 1-bug_opus | opus | noskill | 7.3 | 6.7 | 8.3 | 5.7 | 8 | **7.2** |
| 1-bug_opus | opus | skill | 7 | 6 | 8 | 5 | 7.3 | **6.7** |
| 2-lock_sonnet | sonnet | noskill | 1 | 1 | 1 | 1 | 1 | **1.0** |
| 2-lock_sonnet | sonnet | skill | 1 | 1 | 1 | 1 | 1 | **1.0** |
| 2-lock_opus | opus | noskill | 0.7 | 0.7 | 0.7 | 0.7 | 0.7 | **0.7** |
| 2-lock_opus | opus | skill | 6.7 | 7.3 | 8 | 6 | 5.7 | **6.7** |
| 3-ops_sonnet | sonnet | noskill | 6.3 | 7.7 | 6.7 | 6.7 | 6.7 | **6.8** |
| 3-ops_sonnet | sonnet | skill | 6.7 | 8.3 | 6 | 7 | 6.3 | **6.9** |
| 3-ops_opus | opus | noskill | 6 | 8.3 | 6.3 | 6.7 | 4.7 | **6.4** |
| 3-ops_opus | opus | skill | 6 | 7.3 | 7 | 7 | 5.7 | **6.6** |
| 4-improve_sonnet | sonnet | noskill | 8 | 8.7 | 7.3 | 8 | 7.3 | **7.9** |
| 4-improve_sonnet | sonnet | skill | 0.7 | 0.7 | 0.7 | 0.7 | 0.7 | **0.7** |
| 4-improve_opus | opus | noskill | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | **0.3** |
| 4-improve_opus | opus | skill | 0.3 | 0.3 | 0.3 | 0.3 | 0.3 | **0.3** |
