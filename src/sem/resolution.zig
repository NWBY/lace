const std = @import("std");

const diag = @import("../diag/mod.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax/mod.zig");
const tree = @import("../syntax/tree.zig");
const validation = @import("validation.zig");

pub const SymbolKind = enum {
    import_alias,
    struct_decl,
    enum_decl,
    error_decl,
    function_decl,
    const_decl,
    parameter,
    local,
    bind_else,
    match_binding,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    span: source.Span,
    visibility: tree.Visibility = .private,
};

pub const ImportBinding = struct {
    alias: []const u8,
    module_path: []const u8,
    span: source.Span,
    target_module_index: ?usize,
};

pub const Module = struct {
    document_index: usize,
    path: []const u8,
    symbols: []const Symbol,
    exports: []const Symbol,
    imports: []const ImportBinding,
};

pub const Package = struct {
    modules: []const Module,
};

const VisitState = enum {
    unvisited,
    visiting,
    done,
};

const ResolveError = error{OutOfMemory};

pub fn resolveDocuments(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    documents: []const tree.Document,
) !Package {
    const package_modules = try allocator.alloc(Module, documents.len);
    var top_level_maps = try allocator.alloc(NameMap, documents.len);
    var import_maps = try allocator.alloc(NameMap, documents.len);
    var module_path_map: std.StringHashMapUnmanaged(usize) = .empty;

    for (documents, 0..) |document, index| {
        const module_path = modulePathText(sources, document);
        const entry = try module_path_map.getOrPut(allocator, module_path);
        if (!entry.found_existing) {
            entry.value_ptr.* = index;
        }
    }

    for (documents, 0..) |document, index| {
        top_level_maps[index] = .empty;
        import_maps[index] = .empty;

        package_modules[index] = try buildModule(
            allocator,
            diagnostics,
            sources,
            &module_path_map,
            document,
            index,
            &top_level_maps[index],
            &import_maps[index],
        );
    }

    try detectImportCycles(allocator, diagnostics, package_modules);

    for (documents, 0..) |document, index| {
        try resolveDocumentBodies(
            allocator,
            diagnostics,
            sources,
            &package_modules[index],
            document,
            &top_level_maps[index],
            &import_maps[index],
        );
    }

    return .{ .modules = package_modules };
}

fn buildModule(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    module_path_map: *const std.StringHashMapUnmanaged(usize),
    document: tree.Document,
    document_index: usize,
    top_level_map: *NameMap,
    import_map: *NameMap,
) !Module {
    var symbols: std.ArrayList(Symbol) = .empty;
    var exports: std.ArrayList(Symbol) = .empty;
    var imports: std.ArrayList(ImportBinding) = .empty;

    for (document.items) |item| {
        const named_symbol = namedItemSymbol(sources, document, item) orelse continue;
        const existing = top_level_map.get(named_symbol.name);
        if (existing != null) {
            try diagnostics.append(allocator, .{
                .code = "N1001",
                .message = "Duplicate top-level declaration",
                .span = named_symbol.span,
                .symbol = named_symbol.name,
            });
            continue;
        }

        try top_level_map.put(allocator, named_symbol.name, named_symbol);
        try symbols.append(allocator, named_symbol);
        if (named_symbol.visibility == .public) {
            try exports.append(allocator, named_symbol);
        }
    }

    for (document.imports) |import_decl| {
        const import_path = pathText(sources, document.file_id, import_decl.path.span);
        const alias = importAlias(sources, document, import_decl);
        const target_module_index = module_path_map.get(import_path);

        if (top_level_map.get(alias) != null or import_map.get(alias) != null) {
            try diagnostics.append(allocator, .{
                .code = "N1002",
                .message = "Import alias conflicts with an existing module symbol",
                .span = import_decl.path.span,
                .symbol = alias,
            });
            continue;
        }

        if (target_module_index == null) {
            try diagnostics.append(allocator, .{
                .code = "N1003",
                .message = "Imported module was not found",
                .span = import_decl.path.span,
                .symbol = import_path,
            });
        }

        const binding = ImportBinding{
            .alias = alias,
            .module_path = import_path,
            .span = import_decl.path.span,
            .target_module_index = target_module_index,
        };
        try import_map.put(allocator, alias, .{
            .name = alias,
            .kind = .import_alias,
            .span = import_decl.path.span,
        });
        try imports.append(allocator, binding);
    }

    return .{
        .document_index = document_index,
        .path = modulePathText(sources, document),
        .symbols = try symbols.toOwnedSlice(allocator),
        .exports = try exports.toOwnedSlice(allocator),
        .imports = try imports.toOwnedSlice(allocator),
    };
}

fn detectImportCycles(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    modules: []const Module,
) !void {
    const states = try allocator.alloc(VisitState, modules.len);
    @memset(states, .unvisited);

    for (modules, 0..) |_, index| {
        try visitModule(allocator, diagnostics, modules, states, index);
    }
}

fn visitModule(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    modules: []const Module,
    states: []VisitState,
    module_index: usize,
) !void {
    switch (states[module_index]) {
        .done => return,
        .visiting => return,
        .unvisited => {},
    }

    states[module_index] = .visiting;
    for (modules[module_index].imports) |import_binding| {
        const target = import_binding.target_module_index orelse continue;
        switch (states[target]) {
            .visiting => try diagnostics.append(allocator, .{
                .code = "N1006",
                .message = "Import cycle detected",
                .span = import_binding.span,
                .symbol = import_binding.module_path,
            }),
            .unvisited => try visitModule(allocator, diagnostics, modules, states, target),
            .done => {},
        }
    }
    states[module_index] = .done;
}

fn resolveDocumentBodies(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    module: *const Module,
    document: tree.Document,
    top_level_map: *const NameMap,
    import_map: *const NameMap,
) !void {
    var resolver = Resolver{
        .allocator = allocator,
        .diagnostics = diagnostics,
        .sources = sources,
        .module = module,
        .document = document,
        .top_level_map = top_level_map,
        .import_map = import_map,
    };

    for (document.items) |item| {
        switch (item) {
            .const_decl => |decl| try resolver.resolveExpr(decl.initializer),
            .function_decl => |decl| try resolver.resolveFunction(decl),
            .test_decl => |decl| try resolver.resolveTest(decl),
            else => {},
        }
    }
}

const Resolver = struct {
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    module: *const Module,
    document: tree.Document,
    top_level_map: *const NameMap,
    import_map: *const NameMap,
    scopes: std.ArrayList(ScopeFrame) = .empty,

    fn resolveFunction(self: *Resolver, decl: tree.FunctionDecl) ResolveError!void {
        try self.pushScope();
        defer self.popScope();

        for (decl.params) |param| {
            try self.declareLocal(self.text(param.name), .parameter, param.name);
        }

        try self.resolveBlock(decl.body);
    }

    fn resolveTest(self: *Resolver, decl: tree.TestDecl) ResolveError!void {
        try self.pushScope();
        defer self.popScope();
        try self.resolveBlock(decl.body);
    }

    fn resolveBlock(self: *Resolver, block: tree.Block) ResolveError!void {
        try self.pushScope();
        defer self.popScope();

        for (block.statements) |statement| {
            try self.resolveStatement(statement);
        }
    }

    fn resolveStatement(self: *Resolver, statement: tree.Statement) ResolveError!void {
        switch (statement) {
            .let_stmt => |stmt| {
                try self.resolveExpr(stmt.value);
                try self.declareLocal(self.text(stmt.name), .local, stmt.name);
            },
            .const_stmt => |stmt| {
                try self.resolveExpr(stmt.value);
                try self.declareLocal(self.text(stmt.name), .local, stmt.name);
            },
            .bind_stmt => |stmt| {
                try self.resolveExpr(stmt.value);
                try self.pushScope();
                try self.declareLocal(self.text(stmt.else_name), .bind_else, stmt.else_name);
                switch (stmt.else_body) {
                    .block => |block| try self.resolveBlock(block),
                    .expr => |expr| try self.resolveExpr(expr),
                }
                self.popScope();
                try self.declareLocal(self.text(stmt.name), .local, stmt.name);
            },
            .if_stmt => |stmt| {
                try self.resolveExpr(stmt.condition);
                try self.resolveBlock(stmt.then_block);
                if (stmt.else_block) |else_block| {
                    try self.resolveBlock(else_block);
                }
            },
            .match_stmt => |expr| try self.resolveMatchExpr(expr),
            .return_stmt => |stmt| try self.resolveExpr(stmt.value),
            .expr_stmt => |stmt| try self.resolveExpr(stmt.value),
        }
    }

    fn resolveExpr(self: *Resolver, expr: *tree.Expr) ResolveError!void {
        switch (expr.*) {
            .access_path => |path| try self.resolveAccessPath(path),
            .bool_literal, .int_literal, .string_literal => {},
            .unary => |value| try self.resolveExpr(value.value),
            .binary => |value| {
                try self.resolveExpr(value.left);
                try self.resolveExpr(value.right);
            },
            .call => |value| {
                try self.resolveExpr(value.callee);
                for (value.args) |arg| {
                    try self.resolveExpr(arg.value);
                }
            },
            .struct_init => |value| {
                try self.resolveAccessPath(value.type_path);
                for (value.fields) |field| {
                    try self.resolveExpr(field.value);
                }
            },
            .variant => |value| {
                try self.resolveAccessPath(value.path);
                switch (value.payload) {
                    .positional => |inner| try self.resolveExpr(inner),
                    .named => |fields| {
                        for (fields) |field| {
                            try self.resolveExpr(field.value);
                        }
                    },
                }
            },
            .match_expr => |value| try self.resolveMatchExpr(value),
        }
    }

    fn resolveMatchExpr(self: *Resolver, expr: tree.MatchExpr) ResolveError!void {
        try self.resolveExpr(expr.value);
        for (expr.arms) |arm| {
            try self.pushScope();
            try self.declarePatternBindings(arm.pattern);
            switch (arm.body) {
                .block => |block| try self.resolveBlock(block),
                .return_stmt => |stmt| try self.resolveExpr(stmt.value),
                .expr => |inner| try self.resolveExpr(inner),
            }
            self.popScope();
        }
    }

    fn declarePatternBindings(self: *Resolver, pattern: tree.Pattern) ResolveError!void {
        switch (pattern) {
            .binding => |value| try self.declareLocal(self.text(value.span), .match_binding, value.span),
            .path => |value| {
                try self.resolveAccessPath(value.path);
                if (value.payload) |payload| switch (payload) {
                    .positional => |inner| try self.declarePatternBindings(inner.*),
                    .named => |fields| {
                        for (fields) |field| {
                            try self.declarePatternBindings(field.value.*);
                        }
                    },
                };
            },
        }
    }

    fn resolveAccessPath(self: *Resolver, path: tree.AccessPath) ResolveError!void {
        if (path.segments.len == 0) {
            return;
        }

        const name = self.text(path.segments[0]);
        if (self.lookupVisible(name) != null) {
            return;
        }

        if (isBuiltinName(name)) {
            return;
        }

        try self.diagnostics.append(self.allocator, .{
            .code = "N1004",
            .message = "Unresolved identifier",
            .span = path.segments[0],
            .symbol = name,
        });
    }

    fn declareLocal(self: *Resolver, name: []const u8, kind: SymbolKind, span: source.Span) ResolveError!void {
        if (self.lookupVisible(name) != null) {
            try self.diagnostics.append(self.allocator, .{
                .code = "N1005",
                .message = "Name shadows an existing symbol",
                .span = span,
                .symbol = name,
            });
            return;
        }

        try self.scopes.items[self.scopes.items.len - 1].symbols.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .span = span,
        });
    }

    fn lookupVisible(self: *Resolver, name: []const u8) ?Symbol {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            for (self.scopes.items[index].symbols.items) |symbol| {
                if (std.mem.eql(u8, symbol.name, name)) {
                    return symbol;
                }
            }
        }

        if (self.top_level_map.get(name)) |symbol| {
            return symbol;
        }

        if (self.import_map.get(name)) |symbol| {
            return symbol;
        }

        return null;
    }

    fn pushScope(self: *Resolver) ResolveError!void {
        try self.scopes.append(self.allocator, .{});
    }

    fn popScope(self: *Resolver) void {
        _ = self.scopes.pop();
    }

    fn text(self: *Resolver, span: source.Span) []const u8 {
        return span.slice(self.sources.getFile(self.document.file_id).source);
    }
};

const ScopeFrame = struct {
    symbols: std.ArrayList(Symbol) = .empty,
};

const NameMap = std.StringHashMapUnmanaged(Symbol);

fn namedItemSymbol(sources: *const source.Manager, document: tree.Document, item: tree.Item) ?Symbol {
    return switch (item) {
        .struct_decl => |value| .{
            .name = textAt(sources, document.file_id, value.name),
            .kind = .struct_decl,
            .span = value.name,
            .visibility = value.visibility,
        },
        .enum_decl => |value| .{
            .name = textAt(sources, document.file_id, value.name),
            .kind = .enum_decl,
            .span = value.name,
            .visibility = value.visibility,
        },
        .error_decl => |value| .{
            .name = textAt(sources, document.file_id, value.name),
            .kind = .error_decl,
            .span = value.name,
            .visibility = value.visibility,
        },
        .function_decl => |value| .{
            .name = textAt(sources, document.file_id, value.name),
            .kind = .function_decl,
            .span = value.name,
            .visibility = value.visibility,
        },
        .const_decl => |value| .{
            .name = textAt(sources, document.file_id, value.name),
            .kind = .const_decl,
            .span = value.name,
            .visibility = value.visibility,
        },
        .test_decl => null,
    };
}

fn importAlias(sources: *const source.Manager, document: tree.Document, import_decl: tree.ImportDecl) []const u8 {
    const last_segment = import_decl.path.segments[import_decl.path.segments.len - 1].span;
    return textAt(sources, document.file_id, last_segment);
}

fn modulePathText(sources: *const source.Manager, document: tree.Document) []const u8 {
    return pathText(sources, document.file_id, document.module_decl.path.span);
}

fn pathText(sources: *const source.Manager, file_id: source.FileId, span: source.Span) []const u8 {
    return span.slice(sources.getFile(file_id).source);
}

fn textAt(sources: *const source.Manager, file_id: source.FileId, span: source.Span) []const u8 {
    return span.slice(sources.getFile(file_id).source);
}

fn isBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Ok") or
        std.mem.eql(u8, name, "Err") or
        std.mem.eql(u8, name, "Some") or
        std.mem.eql(u8, name, "None") or
        std.mem.eql(u8, name, "Void") or
        std.mem.eql(u8, name, "print");
}

test "resolution succeeds for a multi-file package with imports" {
    var fixture = try TestFixture.init(&.{
        .{ .path = "src/app/models/user.lace", .contents =
            \\module app/models/user;
            \\
            \\pub struct User {
            \\    name: String,
            \\}
            \\
            \\pub fn build(
            \\    input: String,
            \\) -> User {
            \\    return User{
            \\        name: input,
            \\    };
            \\}
        },
        .{ .path = "src/app/signup.lace", .contents =
            \\module app/signup;
            \\import app/models/user;
            \\
            \\pub error SignupError {
            \\    invalid,
            \\}
            \\
            \\pub fn signup(
            \\    input: String,
            \\) -> Result<User, SignupError> {
            \\    if input == "" {
            \\        return Err(SignupError.invalid);
            \\    } else {
            \\        return Ok(user.build(input: input));
            \\    }
            \\}
        },
    });
    defer fixture.deinit();

    const package = try resolveDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try std.testing.expectEqual(@as(usize, 0), fixture.diagnostics.count());
    try std.testing.expectEqual(@as(usize, 2), package.modules.len);
    try std.testing.expectEqual(@as(usize, 2), package.modules[0].exports.len);
    try std.testing.expectEqualStrings("user", package.modules[1].imports[0].alias);
}

test "resolution reports duplicate top-level declarations" {
    var fixture = try TestFixture.init(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
            \\
            \\const main: Void = Ok(Void);
        },
    });
    defer fixture.deinit();

    _ = try resolveDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try expectDiagnosticCodes(&fixture.diagnostics, &.{"N1001"});
    try expectDiagnosticSlice(&fixture.sources, fixture.diagnostics.items.items[0].span.?, "main");
}

test "resolution reports unresolved identifiers and illegal shadowing" {
    var fixture = try TestFixture.init(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\fn main(
            \\    value: Int,
            \\) -> Result<Int, DemoError> {
            \\    let port = missing;
            \\    let value = port;
            \\    return Ok(value);
            \\}
        },
    });
    defer fixture.deinit();

    _ = try resolveDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try expectDiagnosticCodes(&fixture.diagnostics, &.{ "N1004", "N1005" });
    try expectDiagnosticSlice(&fixture.sources, fixture.diagnostics.items.items[0].span.?, "missing");
    try expectDiagnosticSlice(&fixture.sources, fixture.diagnostics.items.items[1].span.?, "value");
}

test "resolution reports import alias conflicts and missing modules" {
    var fixture = try TestFixture.init(&.{
        .{ .path = "src/app/user.lace", .contents =
            \\module app/user;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\import app/user;
            \\import app/helpers/user;
            \\import app/missing;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
    });
    defer fixture.deinit();

    _ = try resolveDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try expectDiagnosticCodes(&fixture.diagnostics, &.{ "N1002", "N1003" });
}

test "resolution reports import cycles" {
    var fixture = try TestFixture.init(&.{
        .{ .path = "src/app/a.lace", .contents =
            \\module app/a;
            \\import app/b;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
        .{ .path = "src/app/b.lace", .contents =
            \\module app/b;
            \\import app/a;
            \\
            \\fn main() -> Void {
            \\    return Ok(Void);
            \\}
        },
    });
    defer fixture.deinit();

    _ = try resolveDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try expectDiagnosticCodes(&fixture.diagnostics, &.{"N1006"});
    try expectDiagnosticSlice(&fixture.sources, fixture.diagnostics.items.items[0].span.?, "app/a");
}

const Fixture = struct {
    path: []const u8,
    contents: []const u8,
};

const TestFixture = struct {
    arena: std.heap.ArenaAllocator,
    sources: source.Manager,
    diagnostics: diag.Store,
    documents: []const tree.Document,

    fn init(fixtures: []const Fixture) !TestFixture {
        var result = TestFixture{
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .sources = .{},
            .diagnostics = .{},
            .documents = undefined,
        };

        result.documents = try result.parseDocuments(fixtures);
        try validation.validateDocuments(std.testing.allocator, &result.diagnostics, &result.sources, result.documents);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.count());
        return result;
    }

    fn deinit(self: *TestFixture) void {
        self.sources.deinit(std.testing.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    fn parseDocuments(self: *TestFixture, fixtures: []const Fixture) ![]const tree.Document {
        const documents = try self.arena.allocator().alloc(tree.Document, fixtures.len);
        for (fixtures, 0..) |fixture, index| {
            const file_id = try self.sources.addSource(std.testing.allocator, fixture.path, fixture.contents);
            documents[index] = try syntax.parseFile(self.arena.allocator(), &self.diagnostics, self.sources.getFile(file_id));
        }
        return documents;
    }
};

fn expectDiagnosticCodes(diagnostics: *const diag.Store, expected_codes: []const []const u8) !void {
    try std.testing.expectEqual(expected_codes.len, diagnostics.count());
    for (expected_codes, diagnostics.items.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual.code);
    }
}

fn expectDiagnosticSlice(sources: *const source.Manager, span: source.Span, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, span.slice(sources.getFile(span.file_id).source));
}
