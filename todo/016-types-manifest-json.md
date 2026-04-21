# TODO 016: `lace types --json`

## Goal
Emit a machine-readable manifest of exported types, errors, and functions.

## Work
- Walk resolved public module symbols and collect exported structs, errors, enums, and functions.
- Serialize fields, variants, parameters, and return types into a stable JSON schema.
- Include package and module metadata in the output.
- Make type strings canonical so agents can diff and patch them reliably.

## Acceptance Criteria
- `lace types --json` matches the shape described in the design doc.
- Output is stable across repeated runs on unchanged input.
- Tests cover exported structs, errors with payloads, and function signatures.

## Depends On
- `012-result-option-match-and-bind-semantics.md`
- `015-dependency-resolution-and-fetch.md`
