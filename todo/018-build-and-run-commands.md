# TODO 018: `lace build` and `lace run`

## Goal
Turn the backend into package-level build and execution commands.

## Work
- Implement `lace build` using the manifest entry target and package graph.
- Write outputs into `./build/` as specified.
- Implement `lace run` with argument forwarding after `--`.
- Add `--release` and `--target` handling where the backend supports it, and fail clearly where it does not yet.
- Keep build outputs deterministic for the same manifest, lockfile, and source tree.

## Acceptance Criteria
- `lace build` creates the expected output for a binary package.
- `lace run -- arg1 arg2` forwards arguments correctly.
- Build failures are surfaced as structured diagnostics.

## Depends On
- `014-manifest-lockfile-and-project-scaffolding.md`
- `017-backend-mvp-execution-model.md`
