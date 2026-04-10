# Contribution Workflow

Use when you need to submit a patch, understand coding conventions, or navigate the PR process for the Valkey project.

Standard fork-and-PR workflow. PRs target `unstable` branch. Valkey-specific points:

- DCO sign-off required on every commit (`git commit -s`)
- Clang-format-18 enforced in CI (config in `src/.clang-format`, LLVM-based, 4-space indent)
- New source files need BSD-3-Clause header with `Copyright (c) Valkey Contributors`
- Tests are mandatory for every contribution
- Add `needs-doc-pr` label for user-facing changes (docs live in separate `valkey-io/valkey-doc` repo)
- Keep PRs small - the project does extensive backporting
