# TODO 004: Parser for Top-Level Declarations

## Goal
Parse the top-level structure of Lace modules into a typed syntax tree.

## Work
- Parse `module` declarations and explicit `import` statements.
- Parse `pub` visibility on structs, enums, errors, functions, and constants.
- Parse struct, enum, and error declarations with canonical trailing-comma rules.
- Parse function signatures, parameter lists, explicit return types, and top-level `test` blocks.
- Reject alternate declaration styles so the parser enforces canonical syntax rather than tolerating variants.

## Acceptance Criteria
- The parser accepts the declaration forms shown in the design doc.
- Missing semicolons, braces, commas, or return types produce exact diagnostics.
- Parser tests cover both valid and invalid top-level files.

## Depends On
- `003-token-model-and-lexer.md`
