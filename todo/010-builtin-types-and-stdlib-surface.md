# COMPLETED

# TODO 010: Builtin Types and Standard Library Surface

## Goal
Model Lace's core type universe and seed the minimal standard library API surface needed for checking programs.

## Work
- Represent primitive types `Bool`, `Int`, `Float`, `String`, `Bytes`, and `Void`.
- Represent generic types `Option<T>`, `Result<T, E>`, `List<T>`, `Map<K, V>`, and `Set<T>`.
- Define semantic forms for user-declared structs, enums, errors, and functions.
- Seed minimal stdlib module signatures for the v0.1 MVP, especially `std/result`, `std/option`, `std/string`, `std/int`, `std/assert`, and `std/test`.
- Keep builtin and stdlib signatures machine-readable so later commands can reuse them.

## Acceptance Criteria
- The compiler can resolve the core types used throughout the design doc examples.
- Stdlib references such as `string.contains` and `int.parse` have typed signatures.
- Type representation tests cover primitives, generics, and user-defined named types.

## Depends On
- `009-symbol-table-and-name-resolution.md`
