# TODO 009: Symbol Table and Name Resolution

## Goal
Resolve names across modules, imports, and local scopes.

## Work
- Build symbol tables for modules, top-level declarations, function parameters, locals, and match bindings.
- Track `pub` visibility and exported symbols.
- Resolve imports by the last module path segment as required by the spec.
- Detect duplicate declarations, unresolved identifiers, and illegal shadowing rules.
- Detect cyclic imports for v0.1 and fail early with actionable diagnostics.

## Acceptance Criteria
- Name resolution succeeds for a multi-file package using explicit imports.
- Duplicate or missing symbols produce diagnostics with correct spans.
- Cycle detection works on at least one negative package fixture.

## Depends On
- `008-module-path-and-import-validation.md`
