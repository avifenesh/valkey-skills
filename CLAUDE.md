# valkey-skills

> Domain-specific AI skills for the Valkey ecosystem - 24 skills: app dev, server internals, ops, GLIDE client (7 languages + router), migration, module contributors, glide-mq. See README.md for the user-facing catalog and install instructions.

## Skills inventory

Each skill is a self-contained plugin under `skills/<name>/`:
- `.claude-plugin/plugin.json` - metadata
- `skills/<name>/SKILL.md` - router (<250 lines) with trigger phrases and reference tables
- `skills/<name>/reference/` - focused docs, each under 300 lines

Counts and per-skill descriptions live in README.md. The architecture pattern: the AI loads SKILL.md into context, scans the tables, and reads only the specific reference file needed. No context bloat.

Per-language GLIDE skills (Python, Java, Node.js, Go) have 9 md files each. C#, PHP, Ruby skills have 4 md files each. Migration skills have 3 md files each (SKILL.md + api-mapping + advanced-patterns). Glide-mq skills are vendored from [avifenesh/glide-mq](https://github.com/avifenesh/glide-mq) by `scripts/sync-glide-mq-upstream.sh` with pin in `UPSTREAM-GLIDE-MQ.md`.

## Dev

Skills-only plugin - no build step. `npm test` exits with a message.

## Editing skills

- Place new reference docs in `skills/{skill}/skills/{skill}/reference/` as flat files with a descriptive prefix matching the SKILL.md table grouping (e.g. `patterns-caching-strategies.md`).
- Start each reference doc with a "Use when" trigger line.
- Keep reference files under 300 lines; split by topic if they grow.
- Update the SKILL.md router table when adding or renaming a file.

## Version baseline

Valkey 9.0.3 (valkey, valkey-dev, valkey-ops). Valkey GLIDE 2.3.1 (monorepo languages). valkey-search 1.2.0. valkey-bloom GA. Spring Data Valkey 1.0. C# / PHP / Ruby GLIDE at v1.0.0 (separate repos).

Last full review: 2026-04-18 (20-skill validation pass shipped through PR #19).

## Ground rules

1. Write plain text - no emojis, no ASCII art.
2. Verify reference docs against actual source code rather than web research.
3. Place new docs only under `skills/<name>/reference/` or `docs/`; transient analysis stays in chat output (avoid summary, plan, audit, or temp files in the repo).
4. For em-dashes in prose, use a single dash with spaces ` - ` rather than ` -- `.

## Skill-writing rules

Full rules (audience framing, cut lists, grep hazards, 2-pass validation, GLIDE correctness) live in [docs/SKILL_WRITING_RULES.md](docs/SKILL_WRITING_RULES.md). Read that doc before editing any SKILL.md or reference file.

## Validation invariants

Rules accumulated during the 20-skill validation series. Violating any of these produced real bugs caught during review - apply when editing any GLIDE-related skill.

- **`publish` argument order reverses in 3 of 7 GLIDE languages.** Python / Node / Java reverse to `publish(message, channel)`. Go / C# / PHP / Ruby keep the standard `publish(channel, message)`. Silent-bug source during migration - verify for the language you are in.
- **Error models diverge per language binding.** Python and Node nest under `GlideError` / `ValkeyError`. Go and Java are flat. C# nests inside a static `Errors` container. PHP has a single `ValkeyGlideException`. Ruby nests under `Valkey::BaseError < StandardError`. Describe each language's hierarchy from its own source; treat them as independent.
- **UDS is in-process IPC for Python-async and Node.js ONLY.** Every other binding (Python-sync, Java via JNI, Go, C#, PHP, Ruby) uses direct FFI through the C ABI. Describe Java, Go, and the others as direct-FFI clients.
- **Avoid cross-skill relative markdown links** (breaks check-links CI). Use prose references like "see the valkey-glide-python skill".
- **Two-pass validation is mandatory when editing any skill against real source.** Pass 1 is general source verification; pass 2 is a narrow correctness grep. Pass 2 consistently catches 2-8 bugs pass 1 missed.
- **Source repos** (clone locally when validating): monorepo `valkey-io/valkey-glide` at `v2.3.1` (Python, Node, Java, Go, Rust, FFI); C# `valkey-io/valkey-glide-csharp` at `v1.0.0`; PHP `valkey-io/valkey-glide-php` at `v1.0.0`; Ruby `valkey-io/valkey-glide-ruby` (gem `valkey-rb` v1.0.0).
