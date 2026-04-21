# COMPLETED

# TODO 001: Bootstrap Compiler Scaffold

## Goal
Turn the Zig starter template into a real Lace workspace with clear compiler and CLI boundaries.

## Work
- Replace the sample `src/main.zig` and `src/root.zig` behavior with a real `lace` CLI entrypoint and compiler library root.
- Create a source layout for `cli`, `syntax`, `diag`, `sem`, `pkg`, and `backend` code.
- Add a shared compiler context for allocator, file loading, diagnostics, and command execution.
- Keep `zig build`, `zig build run`, and `zig build test` working while features are still stubs.

## Acceptance Criteria
- `zig build` succeeds.
- `zig build test` succeeds.
- `zig build run -- --help` prints a placeholder Lace command list without crashing.

## Depends On
- None.
