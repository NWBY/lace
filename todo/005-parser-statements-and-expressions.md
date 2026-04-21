# TODO 005: Parser for Statements and Expressions

## Goal
Complete the syntax frontend so Lace functions and test blocks can be parsed end to end.

## Work
- Parse `let`, `const`, `return`, `if`, `match`, and `bind` forms.
- Parse function calls with required named arguments.
- Parse struct initialization, enum and error variant construction, field access, and path access.
- Parse the expression operators needed by v0.1 examples, including comparison, boolean negation, and basic arithmetic/string concatenation.
- Enforce braces and semicolons as required syntax rather than formatter-only preferences.

## Acceptance Criteria
- The parser accepts the full end-to-end example from the spec.
- Invalid positional calls such as `add(2, 3)` fail with a targeted parse error.
- Statement and expression tests cover `if`, `match`, `bind`, calls, and struct literals.

## Depends On
- `004-parser-top-level-declarations.md`
