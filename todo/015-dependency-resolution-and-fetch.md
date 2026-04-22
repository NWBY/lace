# COMPLETED

# TODO 015: Dependency Resolution and `lace fetch`

## Goal
Implement package graph resolution and deterministic fetching under the strict v0.1 rules.

## Work
- Resolve exact-version dependencies from `lace.toml`.
- Enforce one version per dependency name across the graph.
- Read and update `lace.lock` deterministically.
- Implement package fetching into the shared cache at `~/.lace/pkg/`.
- Resolve imports across the current package, locked dependencies, and the local cache in the specified order.

## Acceptance Criteria
- `lace fetch` populates the cache and updates `lace.lock` deterministically.
- Conflicting or missing dependencies produce structured diagnostics.
- Cross-package import resolution works for a fixture with at least one dependency.

## Depends On
- `014-manifest-lockfile-and-project-scaffolding.md`
