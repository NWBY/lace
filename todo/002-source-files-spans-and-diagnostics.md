# TODO 002: Source Files, Spans, and Diagnostics

## Goal
Build the shared compiler foundation for loading source files, tracking spans, and emitting structured errors.

## Work
- Implement file loading with stable file IDs and cached source contents.
- Add span, line, and column indexing so every lexer, parser, and type error can point to exact source ranges.
- Define a diagnostic model with stable error codes, levels, messages, details, and suggested fixes.
- Implement both human-readable rendering and JSON encoding for diagnostics.
- Define the stable ID strategy used later by AST nodes and semantic symbols.

## Acceptance Criteria
- A synthetic parse or type error can be rendered in both human and JSON form.
- Source spans resolve back to correct file, line, and column locations.
- Diagnostic tests snapshot both text and JSON output.

## Depends On
- `001-bootstrap-compiler-scaffold.md`
