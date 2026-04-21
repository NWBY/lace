# TODO 021: Publish, Registry, and Reproducibility

## Goal
Close out the v0.1 package lifecycle with publishing, cache discipline, and reproducible builds.

## Work
- Implement the minimal registry client needed for package metadata lookup and publishing.
- Implement `lace publish` and `lace publish --dry-run`.
- Generate deterministic source archives and checksums.
- Reuse the shared package cache consistently across fetch, build, test, and publish flows.
- Verify that build outputs are reproducible from `lace.toml`, `lace.lock`, the source tree, and cached dependencies.

## Acceptance Criteria
- Publish dry-runs produce deterministic archives and checksums.
- Registry interactions are covered by fixture or mock tests.
- Reproducibility checks pass for at least one package with dependencies.

## Depends On
- `018-build-and-run-commands.md`
- `020-dependency-editing-commands.md`
