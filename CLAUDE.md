# valkey-skills

> Domain-specific AI skills for the Valkey ecosystem - 5 skills covering users, contributors, operators, Glide client, and ecosystem tools

## Skills

| Directory | Skill | Audience | Status |
|-----------|-------|----------|--------|
| `valkey/` | valkey | Application developers using Valkey | Research complete |
| `valkey-dev/` | valkey-dev | Valkey server contributors | Source-verified, 58 reference files |
| `valkey-glide/` | valkey-glide | Glide client users | Research complete |
| `valkey-ops/` | valkey-ops | Self-hosted Valkey operators | Research complete |
| `valkey-ecosystem/` | valkey-ecosystem | Ecosystem tools and services | Research complete |

## Architecture

Each skill follows the same pattern:
- `SKILL.md` - concise router (<500 lines) with trigger phrases and reference tables
- `reference/` - deep RAG library of focused docs (100-300 lines each)
- `resources/` - source metadata from research phase

The AI loads SKILL.md into context, scans the tables, and reads only the specific reference file needed. No context bloat.

## Quality

valkey-dev is the reference implementation:
- 58 reference files, ~13,191 lines
- Every claim verified against actual Valkey C source code
- 1,440 claims validated by 15 independent review agents
- 29 errors found and fixed (2% initial error rate -> 0%)

## Critical Rules

1. **Plain text output** - No emojis, no ASCII art.
2. **Source-verified** - Reference docs must be verified against actual source code, not just web research.
3. **No unnecessary files** - Don't create summary files, plan files, audit files, or temp docs.
4. **Use single dash for em-dashes** - In prose, use ` - ` (single dash with spaces), never ` -- `.
