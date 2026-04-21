# COMPLETED

# TODO 013: CLI for `fmt`, `check`, `ast`, and `diag`

## Goal
Expose the compiler frontend through the single `lace` CLI with machine-friendly output modes.

## Work
- Implement command parsing and dispatch for `lace fmt`, `lace check`, `lace ast`, and `lace diag`.
- Support package-wide operation and single-file targets where the design calls for both.
- Add `--json` output modes for `check`, `ast`, and `diag`.
- Define stable exit-code behavior for success, diagnostics, and internal failures.
- Keep all command output deterministic so agents can rely on it.

## Acceptance Criteria
- `lace fmt`, `lace check`, `lace ast --json`, and `lace diag --json` work on sample packages.
- Invalid input returns non-zero status and structured diagnostics.
- CLI tests snapshot JSON output for at least one representative error and one valid module.

## Depends On
- `007-canonical-formatter.md`
- `012-result-option-match-and-bind-semantics.md`
