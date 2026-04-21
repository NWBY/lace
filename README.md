# Lace - Language for Agents, Canonical and Explicit

Lace is a statically typed programming language for agents to write, edit, and repair.

This repository contains the Zig bootstrap implementation for Lace v0.1.

## Status

Implemented so far:

- project scaffold and `lace` CLI entrypoint
- source file management with stable file IDs and spans
- structured diagnostics with text and JSON rendering
- deterministic lexer for the current Lace token set
- parser for top-level declarations and signatures
- parser for statements, expressions, match patterns, and block bodies
- stable AST JSON output with deterministic node IDs
- canonical formatter with deterministic rewrites
- module path and import validation
- symbol tables, name resolution, and import-cycle detection
- builtin primitive/generic type model and stdlib signatures
- core type checking for declarations, calls, returns, and struct initialization
- `lace fmt <file>`
- `lace ast --json <file>`

In progress next:

- result and option semantics
- `lace check`

## Goals

Lace is designed to be:

- canonical
- explicit
- strongly typed
- easy for agents to generate and repair
- easy for humans to review
- machine-friendly by default

## Current Commands

Implemented so far:

```sh
zig build run -- --help
zig build run -- fmt examples/demo.lace
zig build run -- ast --json examples/demo.lace
```

Build and test the Zig implementation with:

```sh
zig build
zig build test
```

### fmt

The fmt command should always produce the same output for the same input providing agents with a stable canonical format.

```sh
zig build run -- fmt examples/demo.lace
```

### ast

```sh
zig build run -- ast --json examples/demo.lace
```

## Repository Layout

```txt
src/
  main.zig        CLI entrypoint
  root.zig        public Lace library surface
  context.zig     shared compiler context
  source.zig      source file loading and span tracking
  diag/           diagnostics model and renderers
  syntax/         lexer, parser, and AST JSON output
  sem/            semantic validation, resolution, type surfaces, and core checking
  pkg/            package system placeholder
  backend/        execution backend placeholder
examples/         sample Lace source files
todo/             ordered implementation roadmap
```

## Roadmap

The implementation plan is tracked in `todo/` with one markdown file per step.
Completed items are marked with a `# COMPLETED` header.

The current sequence starts with:

1. compiler scaffold
2. source spans and diagnostics
3. lexer
4. parser for top-level declarations
5. parser for statements and expressions
6. stable AST and JSON output
7. canonical formatter
8. module path and import validation
9. symbol table and name resolution
10. builtin types and stdlib surface
11. core type checking

## Design Direction

The target language includes:

- canonical syntax
- named arguments at call sites
- explicit `Result<T, E>` handling
- typed structured errors
- stable AST and machine-readable compiler output
- a single built-in CLI toolchain

The full design spec is reflected in the todo breakdown and is being implemented incrementally.
