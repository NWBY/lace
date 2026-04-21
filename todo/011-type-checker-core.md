# COMPLETED

# TODO 011: Type Checker Core

## Goal
Implement the main type-checking rules for declarations, statements, and expressions.

## Work
- Enforce explicit types on public functions and other public API boundaries.
- Allow local inference only when the initializer type is unambiguous.
- Enforce no implicit conversions between primitive types.
- Require `Bool` in conditions.
- Type-check function calls, named arguments, return statements, struct initialization, field access, and constant declarations.

## Acceptance Criteria
- The public API examples from the spec type-check successfully.
- Negative tests cover wrong return types, missing named arguments, bad field types, and non-`Bool` conditions.
- Type errors use structured diagnostics with spans and stable codes.

## Depends On
- `010-builtin-types-and-stdlib-surface.md`
