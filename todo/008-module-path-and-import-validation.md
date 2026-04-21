# TODO 008: Module Path and Import Validation

## Goal
Enforce the module layout rules that make Lace easy for agents and tools to navigate.

## Work
- Validate that each file starts with exactly one `module` declaration.
- Check that module paths match file paths under `src/`.
- Validate explicit imports and reject wildcard or side-effect-only import forms.
- Detect duplicate imports, self-imports, and other invalid module graph edges early.
- Produce clear diagnostics when a module path, file path, or import statement is inconsistent.

## Acceptance Criteria
- Files with wrong module declarations fail with structured diagnostics.
- Import validation catches duplicate and invalid imports before type checking starts.
- Multi-file package tests cover happy-path and broken layouts.

## Depends On
- `006-stable-ast-and-json-output.md`
