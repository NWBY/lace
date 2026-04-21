# COMPLETED

# TODO 006: Stable AST and JSON Output

## Goal
Define the stable AST shape used by later compiler passes and by `lace ast --json`.

## Work
- Finalize AST node types for modules, imports, declarations, statements, expressions, patterns, and types.
- Attach source spans and stable node IDs to every AST node.
- Add room for later semantic IDs so tooling can correlate AST output with resolution and type checking.
- Implement a deterministic JSON encoder for AST output.
- Snapshot the JSON schema against the node kinds listed in the design doc.

## Acceptance Criteria
- `lace ast --json` can emit a stable tree for a valid source file.
- Re-running AST output on unchanged input produces byte-for-byte identical JSON.
- AST tests cover node kinds, spans, and IDs.

## Depends On
- `005-parser-statements-and-expressions.md`
