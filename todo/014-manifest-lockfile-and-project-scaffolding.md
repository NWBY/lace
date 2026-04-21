# TODO 014: Manifest, Lockfile, and Project Scaffolding

## Goal
Add package metadata handling and project creation commands.

## Work
- Parse and validate `lace.toml` according to the v0.1 manifest shape.
- Define the deterministic in-memory and on-disk model for `lace.lock`.
- Implement `lace init` and `lace new` for binary and library packages.
- Generate canonical starter files such as `src/main.lace`, `src/lib.lace`, and `.gitignore`.
- Make scaffolded projects immediately compatible with `lace fmt` and `lace check`.

## Acceptance Criteria
- `lace init` and `lace new` create valid package layouts for app and lib projects.
- Generated manifest files round-trip through the parser and serializer.
- Lockfile serialization is deterministic.

## Depends On
- `013-cli-fmt-check-ast-and-diag.md`
