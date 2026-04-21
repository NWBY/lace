const std = @import("std");

const diag = @import("../diag/mod.zig");
const source = @import("../source.zig");
const tree = @import("../syntax/tree.zig");
const syntax = @import("../syntax/mod.zig");

pub fn validateDocument(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    document: tree.Document,
) !void {
    try validateModulePath(allocator, diagnostics, sources, document);
    try validateImports(allocator, diagnostics, sources, document);
}

pub fn validateDocuments(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    documents: []const tree.Document,
) !void {
    for (documents) |document| {
        try validateDocument(allocator, diagnostics, sources, document);
    }

    for (documents, 0..) |document, index| {
        const module_path = modulePathText(sources, document);
        for (documents[0..index]) |previous| {
            if (std.mem.eql(u8, module_path, modulePathText(sources, previous))) {
                try diagnostics.append(allocator, .{
                    .code = "M1005",
                    .message = "Duplicate module path in source tree",
                    .span = document.module_decl.path.span,
                    .symbol = module_path,
                });
                break;
            }
        }
    }
}

fn validateModulePath(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    document: tree.Document,
) !void {
    const file = sources.getFile(document.file_id);
    const expected = expectedModulePath(file.path) orelse {
        try diagnostics.append(allocator, .{
            .code = "M1001",
            .message = "Source files must live under `src/` and use the `.lace` extension",
            .span = document.module_decl.path.span,
            .symbol = file.path,
        });
        return;
    };

    const actual = modulePathText(sources, document);
    if (!std.mem.eql(u8, actual, expected)) {
        try diagnostics.append(allocator, .{
            .code = "M1002",
            .message = "Module path must match file path under `src/`",
            .span = document.module_decl.path.span,
            .symbol = actual,
        });
    }
}

fn validateImports(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    document: tree.Document,
) !void {
    const module_path = modulePathText(sources, document);

    for (document.imports, 0..) |import_decl, index| {
        const import_path = pathText(sources, document.file_id, import_decl.path.span);

        if (std.mem.eql(u8, import_path, module_path)) {
            try diagnostics.append(allocator, .{
                .code = "M1004",
                .message = "Modules may not import themselves",
                .span = import_decl.path.span,
                .symbol = import_path,
            });
        }

        for (document.imports[0..index]) |previous| {
            if (std.mem.eql(u8, import_path, pathText(sources, document.file_id, previous.path.span))) {
                try diagnostics.append(allocator, .{
                    .code = "M1003",
                    .message = "Duplicate import path",
                    .span = import_decl.path.span,
                    .symbol = import_path,
                });
                break;
            }
        }
    }
}

fn modulePathText(sources: *const source.Manager, document: tree.Document) []const u8 {
    return pathText(sources, document.file_id, document.module_decl.path.span);
}

fn pathText(sources: *const source.Manager, file_id: source.FileId, span: source.Span) []const u8 {
    return span.slice(sources.getFile(file_id).source);
}

fn expectedModulePath(file_path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, file_path, ".lace")) {
        return null;
    }

    if (std.mem.startsWith(u8, file_path, "src/")) {
        return file_path[4 .. file_path.len - 5];
    }

    const marker = "/src/";
    const start = std.mem.lastIndexOf(u8, file_path, marker) orelse return null;
    return file_path[start + marker.len .. file_path.len - 5];
}

test "validation accepts a valid multi-file package" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const documents = try parseDocuments(arena, &sources, &diagnostics, &.{
        .{ .path = "src/app/signup.lace", .contents =
            \\module app/signup;
            \\import app/models/user;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
        .{ .path = "src/app/models/user.lace", .contents =
            \\module app/models/user;
            \\
            \\pub struct User {
            \\    name: String,
            \\}
        },
    });

    try validateDocuments(std.testing.allocator, &diagnostics, &sources, documents);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "validation rejects module path mismatches" {
    try expectValidationCodes(&.{
        .{ .path = "src/app/signup.lace", .contents =
            \\module app/http;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
    }, &.{"M1002"});
}

test "validation rejects duplicate imports and self imports" {
    try expectValidationCodes(&.{
        .{ .path = "src/app/signup.lace", .contents =
            \\module app/signup;
            \\import app/models/user;
            \\import app/models/user;
            \\import app/signup;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
    }, &.{ "M1003", "M1004" });
}

test "validation rejects duplicate module paths across files" {
    try expectValidationCodes(&.{
        .{ .path = "src/app/shared.lace", .contents =
            \\module app/shared;
            \\
            \\fn signup() -> Void {
            \\    return Ok(Void);
            \\}
        },
        .{ .path = "src/app/shared_copy.lace", .contents =
            \\module app/shared;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
    }, &.{ "M1002", "M1005" });
}

test "validation rejects files outside src" {
    try expectValidationCodes(&.{
        .{ .path = "tests/signup_test.lace", .contents =
            \\module app/signup_test;
            \\
            \\test "ok" {
            \\    return Ok(Void);
            \\}
        },
    }, &.{"M1001"});
}

const Fixture = struct {
    path: []const u8,
    contents: []const u8,
};

fn parseDocuments(
    arena: std.mem.Allocator,
    sources: *source.Manager,
    diagnostics: *diag.Store,
    fixtures: []const Fixture,
) ![]const tree.Document {
    const documents = try arena.alloc(tree.Document, fixtures.len);
    for (fixtures, 0..) |fixture, index| {
        const file_id = try sources.addSource(std.testing.allocator, fixture.path, fixture.contents);
        documents[index] = try syntax.parseFile(arena, diagnostics, sources.getFile(file_id));
    }
    return documents;
}

fn expectValidationCodes(fixtures: []const Fixture, expected_codes: []const []const u8) !void {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const documents = try parseDocuments(arena, &sources, &diagnostics, fixtures);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());

    try validateDocuments(std.testing.allocator, &diagnostics, &sources, documents);
    try std.testing.expectEqual(expected_codes.len, diagnostics.count());
    for (expected_codes, diagnostics.items.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual.code);
    }
}
