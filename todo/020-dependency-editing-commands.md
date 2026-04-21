# TODO 020: Dependency Editing Commands

## Goal
Finish the local package-management workflow for declared dependencies and build outputs.

## Work
- Implement `lace add` for exact-version dependency insertion.
- Implement `lace remove` for dependency removal.
- Implement `lace update` to refresh the deterministic lockfile for declared exact versions.
- Implement `lace clean` to remove only compiler-owned build artifacts.
- Keep manifest and lockfile rewrites canonical and stable.

## Acceptance Criteria
- `lace add`, `lace remove`, and `lace update` update project files deterministically.
- `lace clean` removes build outputs without touching source or cache data.
- Dependency command tests cover add, remove, update, and no-op cases.

## Depends On
- `015-dependency-resolution-and-fetch.md`
- `018-build-and-run-commands.md`
