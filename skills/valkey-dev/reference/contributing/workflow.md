# Contribution Workflow

Use when you need to submit a patch, understand coding conventions, or navigate the PR process for the Valkey project.

**Contributor path**: this guide -> [build](../build/building.md) -> code -> [test](../testing/tcl-tests.md) -> [CI](../testing/ci-pipeline.md) -> review -> merge.

## Contents

- PR Process (line 23)
- Developer Certificate of Origin (DCO) (line 71)
- Coding Style (line 89)
- Licensing (line 146)
- Commit Message Conventions (line 160)
- Documentation (line 181)
- Running Extended Tests (line 191)
- Communication Channels (line 202)
- Review Criteria (line 210)
- Common Mistakes (line 222)
- See Also (line 230)

---

## PR Process

### Step-by-Step

1. **Discuss major changes first.** For significant features or semantic changes, open a GitHub issue describing what you want to accomplish and why. Wait for acknowledgment from project leaders before writing code.

2. **Fork and branch.**

```
git clone https://github.com/YOUR_USER/valkey.git
cd valkey
git remote add upstream https://github.com/valkey-io/valkey.git
git checkout -b my-feature upstream/unstable
```

3. **Develop.** Follow the coding style (see below). Refer to `DEVELOPMENT_GUIDE.md`. For build setup and options, see [Building Valkey](../build/building.md).

4. **Test your changes.**

```
make -j$(nproc)
./runtest --verbose --dump-logs
make test-unit
```

Add appropriate tests - [unit tests](../testing/unit-tests.md) for data structure changes, [integration tests](../testing/tcl-tests.md) for command changes. For memory-safety validation, see [Sanitizer Builds](../build/sanitizers.md).

5. **Commit with DCO sign-off.**

```
git commit -s -m "module: description of change"
```

6. **Push and open a PR.**

```
git push origin my-feature
```

Open a PR against `unstable` (or the appropriate release branch). Include "Fixes #xyz" in the description to link issues.

### Key PR Guidelines

- **Keep PRs small.** Separate refactoring from functional changes. The project does extensive backporting, and large diffs create merge conflicts.
- **Add the `needs-doc-pr` label** if your change requires documentation updates in [valkey-doc](https://github.com/valkey-io/valkey-doc).
- **Every contribution must include tests.** This is non-negotiable.
- **Avoid unnecessary configuration.** Prefer heuristics over user-facing config. Add config only when workload characteristics cannot be inferred or involve tradeoffs.

## Developer Certificate of Origin (DCO)

Every commit must be signed off:

```
Signed-off-by: Jane Smith <jane.smith@email.com>
```

Use `git commit -s` to add this automatically from your git config. The DCO certifies you have the right to submit the code under the project's license. Anonymous contributions and pseudonyms are not accepted.

Revert commits also require a DCO.

If you need to add sign-off to existing commits:

```
git rebase --signoff HEAD~N
```

## Coding Style

### Formatting

The project uses clang-format-18 with the config in `src/.clang-format`. Key rules:

| Setting | Value |
|---------|-------|
| Based on | LLVM style |
| Indent width | 4 spaces |
| Tabs | Never |
| Column limit | 0 (no hard limit, aim for ~90) |
| Brace style | Attach (K&R) |
| Short if (without else) / loops | Allowed on single line |
| Short functions | Not on single line |
| Pointer alignment | Right (`char *ptr`) |
| Sort includes | No |

Run formatting before committing:

```
cd src
clang-format-18 -i your_file.c your_file.h
```

CI will reject PRs with formatting violations.

### Naming Conventions

- **Variables**: `snake_case` or all lowercase for short names (`cached_reply`, `keylen`)
- **Functions**: `camelCase` or `namespace_camelCase` (`createStringObject`, `IOJobQueue_isFull`)
- **Macros**: `UPPER_CASE` (`MAKE_CMD`)
- **Structures**: `camelCase` (`user`)

Follow surrounding code style. The codebase has historical inconsistencies that are kept for backport compatibility.

### Comments

- C-style `/* comment */` for single and multi-line
- C++ `//` only for single-line
- Multi-line comments: align leading `*`, close `*/` on the last text line:

```c
/* This is a multi-line
 * comment example. */
```

- Document functions to explain all behavior without reading the code
- Comment non-obvious behavior and design rationale

### Other Conventions

- Use `static` for file-local functions
- Use `bool` for true/false values (not `int`)
- Historical exceptions exist for backport compatibility - don't "fix" them
- Line length: keep below 90 when reasonable, no hard enforcement

## Licensing

New source files must include this header:

```c
/*
 * Copyright (c) Valkey Contributors
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 */
```

If making material changes (roughly 100+ lines) to a file with a different license header, add this header as well.

## Commit Message Conventions

- First line: short summary (imperative mood)
- Blank line, then detailed description if needed
- Reference issues with "Fixes #xyz"
- Sign-off line at the end

Example:

```
bitops: fix BITCOUNT on empty key edge case

When BITCOUNT is called on a non-existent key with byte range
arguments, it should return 0 instead of an error. This aligns
the behavior with BITCOUNT on existing empty strings.

Fixes #1234

Signed-off-by: Jane Smith <jane.smith@email.com>
```

## Documentation

Valkey documentation lives in a separate repository: [valkey-io/valkey-doc](https://github.com/valkey-io/valkey-doc).

- **Topics**: `valkey-doc/topics/` for feature documentation
- **Commands**: `valkey-doc/commands/` for command reference
- **Command metadata**: `src/commands/*.json` in the main repo for command history

When your PR changes user-facing behavior, add the `needs-doc-pr` label and open a corresponding PR in valkey-doc.

## Running Extended Tests

For thorough validation before submitting, you can run the daily workflow on your fork:

1. Go to your fork on GitHub > **Actions** > **Daily**
2. Click **Run workflow**
3. Set `use_repo` to your fork, `use_git_ref` to your branch
4. Set `skipjobs` and `skiptests` to `none` for full coverage

This runs sanitizers, valgrind, multiple platforms, and allocator configurations. See [CI Pipeline](../testing/ci-pipeline.md) for the full list of jobs and skip tokens.

## Communication Channels

- **GitHub Issues**: Bug reports, feature requests
- **GitHub Discussions**: Questions, design discussions
- **Discord**: [discord.gg/zbcPa5umUB](https://discord.gg/zbcPa5umUB)
- **Matrix**: [#valkey:matrix.org](https://matrix.to/#/#valkey:matrix.org)
- **Security**: See `SECURITY.md` for vulnerability reporting

## Review Criteria

Reviewers look for:

- Tests covering the change
- DCO sign-off on all commits
- Conformance to coding style (clang-format passes)
- Backward compatibility considerations
- Performance implications
- Documentation needs identified
- PR size - prefer small, focused changes

## Common Mistakes

- Forgetting DCO sign-off: use `git rebase --signoff HEAD~N` to fix
- Wrong clang-format version: CI uses clang-format-18 specifically, other versions may produce different output
- Targeting wrong branch: PRs should target `unstable`, not `main`
- Missing `make distclean` between build mode changes (e.g., switching MALLOC or SANITIZER)
- Large PRs: split refactoring from functional changes to ease backporting
