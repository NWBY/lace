# Lace

Lace is a statically typed programming language for agents to write, edit, and repair.

This repository contains the Zig bootstrap implementation for Lace v0.1.

## Status

Implemented so far:

- project scaffold and `lace` CLI entrypoint
- source file management with stable file IDs and spans
- structured diagnostics with text and JSON rendering
- deterministic lexer for the current Lace token set
- parser for top-level declarations and signatures

In progress next:

- statement and expression parser
- formatter and `lace check`

## Goals

Lace is designed to be:

- canonical
- explicit
- strongly typed
- easy for agents to generate and repair
- easy for humans to review
- machine-friendly by default

## Current Commands

The CLI scaffold is in place, but only help output is implemented today.

```sh
zig build run -- --help
```

Build and test the Zig implementation with:

```sh
zig build
zig build test
```

## Repository Layout

```txt
src/
  main.zig        CLI entrypoint
  root.zig        public Lace library surface
  context.zig     shared compiler context
  source.zig      source file loading and span tracking
  diag/           diagnostics model and renderers
  syntax/         lexer and parser work
  sem/            semantic analysis placeholder
  pkg/            package system placeholder
  backend/        execution backend placeholder
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

## Design Direction

The target language includes:

- canonical syntax
- named arguments at call sites
- explicit `Result<T, E>` handling
- typed structured errors
- stable AST and machine-readable compiler output
- a single built-in CLI toolchain

The full design spec is reflected in the todo breakdown and is being implemented incrementally.
