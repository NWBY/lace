# COMPLETED

# TODO 019: Test Discovery, Assertions, and Runner

## Goal
Implement Lace's built-in test workflow.

## Work
- Parse and load `_test.lace` files alongside normal modules.
- Implement `test` block discovery.
- Provide the minimal `std/assert` and `std/test` APIs needed by the v0.1 examples.
- Implement `lace test` with package-wide and module-targeted execution.
- Add human and JSON test output modes with deterministic ordering.

## Acceptance Criteria
- `lace test` discovers and runs tests automatically.
- Assertion failures produce readable output and machine-readable JSON.
- Focused and package-wide test runs behave deterministically.

## Depends On
- `016-types-manifest-json.md`
- `018-build-and-run-commands.md`
