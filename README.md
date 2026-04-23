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
- `Result`/`Option` semantics, exhaustive `match`, and checked `bind`
- manifest and lockfile parse/serialize support
- `lace init` and `lace new` project scaffolding
- exact-version dependency resolution and shared cache fetch
- dependency-aware package checking from `lace.lock` and `~/.lace/pkg/`
- exported type manifests via `lace types --json`
- interpreter backend for the current Lace MVP subset
- `lace build [--json] [path]`
- `lace run [path] [-- args...]`
- built-in test discovery and assertion runner
- `lace fmt [path]`
- `lace check [--json] [path]`
- `lace diag [--json] [path]`
- `lace fetch [path]`
- `lace test [--json] [target]`
- `lace types --json [path]`
- `lace ast --json <file>`

In progress next:

- dependency editing commands
- publish and registry workflow

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
zig build run -- init --lib
zig build run -- new github.com/sam/sample_app
zig build run -- fetch examples/check_demo
zig build run -- fmt examples/check_demo
zig build run -- check --json examples/check_demo
zig build run -- diag --json examples/check_demo
zig build run -- types --json examples/check_demo
zig build run -- build --json examples/check_demo
zig build run -- run examples/check_demo -- one two
zig build run -- test --json examples/test_demo
zig build run -- ast --json examples/demo.lace
```

Build and test the Zig implementation with:

```sh
zig build
zig build test
```

### init

```sh
zig build run -- init
zig build run -- init --name github.com/sam/my_lib --lib
```

### new

```sh
zig build run -- new github.com/sam/my_app
zig build run -- new github.com/sam/my_lib --lib
```

### fetch

```sh
zig build run -- fetch
zig build run -- fetch path/to/package
```

### build

```sh
zig build run -- build --json examples/check_demo
```

### run

```sh
zig build run -- run examples/check_demo -- one two
```

### test

```sh
zig build run -- test examples/test_demo
zig build run -- test --json examples/test_demo
```

### fmt

The fmt command should always produce the same output for the same input providing agents with a stable canonical format.

```sh
zig build run -- fmt examples/demo.lace
zig build run -- fmt examples/check_demo
```

### check

```sh
zig build run -- check --json examples/check_demo
```

### diag

```sh
zig build run -- diag --json examples/check_demo
```

### types

```sh
zig build run -- types --json examples/check_demo
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
  sem/            semantic validation, typing, result semantics, and type manifests
  pkg/            source discovery, manifests, scaffolding, dependency fetch, and test loading
  backend/        interpreter backend and test execution
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
12. result and option semantics
13. CLI for fmt, check, ast, and diag
14. manifest, lockfile, and project scaffolding
15. dependency resolution and fetch
16. types manifest json
17. backend mvp execution model
18. build and run commands
19. built-in test runner

## Design Direction

The target language includes:

- canonical syntax
- named arguments at call sites
- explicit `Result<T, E>` handling
- typed structured errors
- stable AST and machine-readable compiler output
- a single built-in CLI toolchain

The full design spec is reflected in the todo breakdown and is being implemented incrementally.
