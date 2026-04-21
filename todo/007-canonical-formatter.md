# COMPLETED

# TODO 007: Canonical Formatter

## Goal
Implement the single authoritative formatter required by Lace.

## Work
- Print canonical Lace syntax with 4-space indentation, required semicolons, required braces, and trailing commas for multiline declarations.
- Format functions, structs, enums, errors, `if`, `match`, `bind`, calls, and struct literals consistently.
- Keep formatting decisions syntax-driven so the formatter does not invent alternate styles.
- Make formatter output idempotent and safe for machine-applied rewrites.

## Acceptance Criteria
- `lace fmt` produces canonical output for all spec examples.
- Formatting a file twice produces identical output.
- Parse-format-parse round trips preserve AST meaning for supported syntax.

## Depends On
- `006-stable-ast-and-json-output.md`
