# COMPLETED

# TODO 012: Result, Option, Match, and Bind Semantics

## Goal
Enforce Lace's explicit error-handling model and exhaustive branching behavior.

## Work
- Implement exhaustive match checking for enums, errors, `Option<T>`, and `Result<T, E>`.
- Validate pattern payload binding and constructor usage for enum and error variants.
- Enforce that `bind` applies only to `Result`, requires an explicit `else` branch, and lowers cleanly into checked control flow.
- Enforce explicit handling rules for `Option` and `Result` so recoverable values are not silently ignored.
- Add dedicated diagnostics for missing match arms, invalid bind usage, and unhandled recoverable values.

## Acceptance Criteria
- The `parse_port` and `bind ... else` examples from the spec type-check successfully.
- Missing match arms and missing bind `else` branches fail with targeted diagnostics.
- Tests cover both success paths and repair-friendly failure cases.

## Depends On
- `011-type-checker-core.md`
