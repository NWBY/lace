# TODO 003: Token Model and Lexer

## Goal
Implement a deterministic lexer for `.lace` files that matches the language spec exactly.

## Work
- Define the token enum for keywords, identifiers, literals, punctuation, operators, and delimiters.
- Encode the reserved keyword list from the spec as a canonical lookup table.
- Implement lexing for module paths, generic type syntax, named arguments, enum payloads, and error payloads.
- Make whitespace handling explicit and reject unsupported token forms instead of accepting extra syntax by accident.
- Emit precise diagnostics for invalid characters, malformed literals, and unterminated tokens.

## Acceptance Criteria
- Lexer tests cover keywords, identifiers, literals, spans, and error cases.
- Token streams for the spec examples are stable and deterministic.
- Unsupported syntax fails with structured diagnostics instead of silent recovery.

## Depends On
- `002-source-files-spans-and-diagnostics.md`
