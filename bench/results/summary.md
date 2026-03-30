# Benchmark Results - 2026-03-30

## Setup

- **Models**: Sonnet 4.6, Opus 4.6
- **Conditions**: Without skills (baseline), With skills (valkey-skills installed via npx)
- **Tasks**: 3 (GLIDE cache layer, K8s cluster deployment, Valkey epoch bug investigation)
- **Judges**: 3 independent Sonnet runs per response, scores averaged
- **Environment**: Claude Code CLI (`claude -p`), max 30 turns per task

## Performance Metrics

| Model | Skills | Task | Duration | In Tokens | Out Tokens | Turns | Cost |
|-------|--------|------|----------|-----------|------------|-------|------|
| Sonnet | without | cache-layer | 107s | 2,093 | 7,116 | 6 | $0.29 |
| Sonnet | **with** | cache-layer | 266s | 3,703 | 13,860 | 23 | $0.73 |
| Sonnet | without | k8s-cluster | 334s | 9 | 23,407 | 9 | $0.64 |
| Sonnet | **with** | k8s-cluster | 637s | 6,716 | 43,086 | 10 | $1.06 |
| Sonnet | without | epoch-bug | 1,124s | 3,327 | 61,978 | 27 | $1.85 |
| Sonnet | **with** | epoch-bug | 570s | 117 | 28,600 | 18 | $0.89 |
| Opus | without | cache-layer | 212s | 7 | 3,744 | 5 | $0.38 |
| Opus | **with** | cache-layer | 74s | 5 | 2,661 | 3 | $0.30 |
| Opus | without | k8s-cluster | 501s | 14,645 | 9,266 | 31 | $1.60 |
| Opus | **with** | k8s-cluster | 314s | 3,136 | 11,439 | 31 | $1.25 |
| Opus | without | epoch-bug | 406s | 5,449 | 13,357 | 10 | $0.73 |
| Opus | **with** | epoch-bug | 404s | 6,455 | 8,565 | 33 | $1.17 |

## Quality Scores (avg of 3 judges, 1-10 scale)

| Model | Skills | Task | Correct | Complete | Valkey | Prod | Specific | **Avg** |
|-------|--------|------|---------|----------|--------|------|----------|---------|
| Sonnet | without | cache-layer | 7.7 | 9.0 | 8.3 | 8.0 | 9.3 | **8.5** |
| Sonnet | **with** | cache-layer | 7.3 | 8.0 | 9.0 | 8.3 | 7.3 | **8.0** |
| Sonnet | without | k8s-cluster | 9.0 | 9.3 | 9.3 | 9.0 | 9.7 | **9.3** |
| Sonnet | **with** | k8s-cluster | 8.7 | 9.3 | 9.0 | 8.3 | 9.7 | **9.0** |
| Sonnet | without | epoch-bug | 8.7 | 9.7 | 9.0 | 8.7 | 9.7 | **9.2** |
| Sonnet | **with** | epoch-bug | 9.0 | 10.0 | 9.3 | 9.0 | 10.0 | **9.5** |
| Opus | without | cache-layer | 7.0 | 8.3 | 8.3 | 7.0 | 7.0 | **7.5** |
| Opus | **with** | cache-layer | 6.3 | 9.0 | 8.0 | 7.0 | 8.7 | **7.8** |
| Opus | without | k8s-cluster | 7.7 | 6.7 | 9.0 | 8.0 | 7.7 | **7.8** |
| Opus | **with** | k8s-cluster | 7.3 | 7.0 | 7.7 | 7.3 | 7.7 | **7.4** |
| Opus | without | epoch-bug | 8.7 | 9.0 | 9.0 | 8.0 | 9.7 | **8.9** |
| Opus | **with** | epoch-bug | 8.0 | 9.0 | 8.7 | 8.3 | 9.3 | **8.7** |

## Summary by Model

### Sonnet 4.6

| Metric | Without Skills | With Skills | Delta |
|--------|---------------|-------------|-------|
| Avg quality score | 9.0 | 8.8 | -0.2 |
| Avg duration | 522s | 491s | -6% |
| Avg cost | $0.92 | $0.89 | -3% |
| Epoch bug (quality) | 9.2 | **9.5** | +0.3 |
| Epoch bug (time) | 1,124s | **570s** | -49% |
| Epoch bug (cost) | $1.85 | **$0.89** | -52% |

### Opus 4.6

| Metric | Without Skills | With Skills | Delta |
|--------|---------------|-------------|-------|
| Avg quality score | 8.1 | 8.0 | -0.1 |
| Avg duration | 373s | 264s | -29% |
| Avg cost | $0.91 | $0.91 | 0% |
| Cache layer (time) | 212s | **74s** | -65% |
| K8s cluster (time) | 501s | **314s** | -37% |

## Analysis

### Where skills helped most

**Epoch bug investigation (Sonnet)**: The most knowledge-intensive task showed the clearest benefit. With skills, Sonnet scored 9.5 vs 9.2 (quality up), took 570s vs 1,124s (49% faster), and cost $0.89 vs $1.85 (52% cheaper). The skills provided direct references to `cluster_legacy.c` functions, reducing exploration time.

**Speed (Opus)**: Opus was consistently faster with skills across all tasks. The cache layer task dropped from 212s to 74s (65% faster) - the skill provided the exact GLIDE API, eliminating trial-and-error.

### Where skills showed no advantage

**General coding tasks**: For the cache-layer and k8s-cluster tasks, both models already had strong baseline knowledge. The quality scores were within 0.3-0.5 points. These tasks rely more on general software engineering knowledge than Valkey-specific details.

**Sonnet valkey-awareness without skills**: Sonnet scored 8.3-9.3 on valkey-awareness even without skills, suggesting its training data already includes substantial Valkey content. The skills added less marginal value than expected for this model on these tasks.

### Cost observation

Skills did not consistently increase cost. For the epoch bug task, skills reduced cost by 52% for Sonnet by providing direct answers instead of forcing the model to explore. For Opus, cache-layer cost dropped from $0.38 to $0.30.

### Limitations

- 3 tasks is a small sample. More tasks (especially migration-focused and GLIDE-specific API tasks) would better isolate the skills' value.
- The judges are also AI models and may have systematic biases.
- Sonnet's high baseline scores suggest these tasks may not be hard enough to differentiate. Tasks requiring specific GLIDE API calls (argument order, type signatures) would show larger deltas.
- The benchmark ran in the valkey-skills repo directory, which means the AI had access to the skills content via file reading even in the "without skills" condition. A cleaner test would run from a separate directory.
