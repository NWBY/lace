const std = @import("std");
const Io = std.Io;

const diag = @import("../diag/mod.zig");
const sem = @import("../sem/mod.zig");
const types = @import("../sem/types.zig");
const source = @import("../source.zig");
const tree = @import("../syntax/tree.zig");

pub const ExecutionError = std.mem.Allocator.Error || Io.Writer.Error || types.ResolveTypeError || error{
    AssertionFailed,
    DiagnosticsPresent,
    NoSuchFunction,
    NoSuchModule,
    MissingReturn,
    UnsupportedBuiltinFunction,
    UnsupportedOperation,
    InvalidPattern,
    InvalidIntParse,
    BindElseDidNotExit,
};

pub const TestStatus = enum {
    passed,
    failed,
};

pub const TestCase = struct {
    module_index: usize,
    module_path: []const u8,
    file_path: []const u8,
    name: []const u8,
    decl: tree.TestDecl,
};

pub const TestResult = struct {
    module_path: []const u8,
    file_path: []const u8,
    name: []const u8,
    status: TestStatus,
    message: ?[]const u8 = null,
};

pub const Value = union(enum) {
    void,
    bool: bool,
    int: i64,
    string: []const u8,
    list: []const Value,
    struct_instance: StructInstance,
    variant: VariantInstance,
};

pub const StructField = struct {
    name: []const u8,
    value: Value,
};

pub const StructInstance = struct {
    module_path: []const u8,
    name: []const u8,
    fields: []const StructField,
};

pub const VariantInstance = struct {
    owner_module_path: []const u8,
    owner_name: []const u8,
    name: []const u8,
    fields: []const StructField,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    surface: sem.PackageSurface,
    modules: []const ModuleInfo,

    fn moduleIndex(self: *const Program, path: []const u8) ?usize {
        for (self.modules, 0..) |module, index| {
            if (std.mem.eql(u8, module.path, path)) {
                return index;
            }
        }
        return null;
    }
};

const ModuleInfo = struct {
    path: []const u8,
    document: tree.Document,
    imports: []const ImportInfo,
};

const ImportInfo = struct {
    alias: []const u8,
    module_path: []const u8,
};

const EvalResult = union(enum) {
    value: Value,
    returned: Value,
};

const Binding = struct {
    name: []const u8,
    value: Value,
};

const Scope = struct {
    bindings: std.ArrayList(Binding) = .empty,
};

const ConstCacheEntry = struct {
    module_index: usize,
    name: []const u8,
    value: Value,
};

pub fn prepareProgram(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    documents: []const tree.Document,
) ExecutionError!Program {
    const surface = try sem.typecheckDocuments(allocator, diagnostics, sources, documents);
    if (diagnostics.count() != 0) {
        return error.DiagnosticsPresent;
    }

    const modules = try allocator.alloc(ModuleInfo, documents.len);
    for (documents, 0..) |document, index| {
        const imports = try allocator.alloc(ImportInfo, document.imports.len);
        for (document.imports, 0..) |import_decl, import_index| {
            const alias_span = import_decl.path.segments[import_decl.path.segments.len - 1].span;
            imports[import_index] = .{
                .alias = textAt(sources, document.file_id, alias_span),
                .module_path = textAt(sources, document.file_id, import_decl.path.span),
            };
        }
        modules[index] = .{
            .path = textAt(sources, document.file_id, document.module_decl.path.span),
            .document = document,
            .imports = imports,
        };
    }

    return .{
        .allocator = allocator,
        .sources = sources,
        .surface = surface,
        .modules = modules,
    };
}

pub fn runMain(program: *const Program, writer: *Io.Writer) ExecutionError!Value {
    const module_index = program.moduleIndex("main") orelse return error.NoSuchModule;
    return runFunction(program, writer, module_index, "main", &.{});
}

pub fn runEntry(
    program: *const Program,
    writer: *Io.Writer,
    module_path: []const u8,
    function_name: []const u8,
    forwarded_args: []const []const u8,
) ExecutionError!Value {
    const module_index = program.moduleIndex(module_path) orelse return error.NoSuchModule;
    const function_surface = types.lookupFunction(program.surface, module_path, function_name) orelse return error.NoSuchFunction;

    if (function_surface.params.len == 0) {
        return runFunction(program, writer, module_index, function_name, &.{});
    }

    if (function_surface.params.len == 1 and
        std.mem.eql(u8, function_surface.params[0].name, "args") and
        isStringListType(function_surface.params[0].ty))
    {
        const list_values = try program.allocator.alloc(Value, forwarded_args.len);
        for (forwarded_args, 0..) |arg, index| {
            list_values[index] = .{ .string = try program.allocator.dupe(u8, arg) };
        }
        return runFunction(program, writer, module_index, function_name, &.{.{
            .name = "args",
            .value = .{ .list = list_values },
        }});
    }

    return error.UnsupportedOperation;
}

pub fn discoverTests(
    allocator: std.mem.Allocator,
    program: *const Program,
    target: ?[]const u8,
) ExecutionError![]const TestCase {
    var tests = std.ArrayList(TestCase).empty;
    for (program.modules, 0..) |module, module_index| {
        const file_path = program.sources.getFile(module.document.file_id).path;
        if (!std.mem.endsWith(u8, file_path, "_test.lace")) continue;
        if (!testMatchesTarget(module, file_path, target)) continue;

        for (module.document.items) |item| {
            if (item != .test_decl) continue;
            const raw_name = textAt(program.sources, module.document.file_id, item.test_decl.name);
            try tests.append(allocator, .{
                .module_index = module_index,
                .module_path = module.path,
                .file_path = file_path,
                .name = try decodeStringLiteral(allocator, raw_name),
                .decl = item.test_decl,
            });
        }
    }

    std.mem.sort(TestCase, tests.items, {}, struct {
        fn lessThan(_: void, left: TestCase, right: TestCase) bool {
            return switch (std.mem.order(u8, left.file_path, right.file_path)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, left.name, right.name) == .lt,
            };
        }
    }.lessThan);

    return try tests.toOwnedSlice(allocator);
}

pub fn runTestCase(
    program: *const Program,
    writer: *Io.Writer,
    test_case: TestCase,
) ExecutionError!TestResult {
    var executor = Executor{
        .program = program,
        .writer = writer,
    };

    executor.runTest(test_case.module_index, test_case.decl) catch |err| switch (err) {
        error.AssertionFailed => return .{
            .module_path = test_case.module_path,
            .file_path = test_case.file_path,
            .name = test_case.name,
            .status = .failed,
            .message = executor.last_assertion_message orelse "assertion failed",
        },
        error.UnsupportedBuiltinFunction,
        error.UnsupportedOperation,
        error.InvalidPattern,
        error.InvalidIntParse,
        error.BindElseDidNotExit,
        error.NoSuchFunction,
        error.NoSuchModule,
        error.MissingReturn,
        => |runtime_err| return .{
            .module_path = test_case.module_path,
            .file_path = test_case.file_path,
            .name = test_case.name,
            .status = .failed,
            .message = @errorName(runtime_err),
        },
        else => |fatal| return fatal,
    };

    return .{
        .module_path = test_case.module_path,
        .file_path = test_case.file_path,
        .name = test_case.name,
        .status = .passed,
    };
}

pub fn runFunction(
    program: *const Program,
    writer: *Io.Writer,
    module_index: usize,
    function_name: []const u8,
    args: []const Binding,
) ExecutionError!Value {
    var executor = Executor{
        .program = program,
        .writer = writer,
    };
    return executor.runFunction(module_index, function_name, args);
}

const Executor = struct {
    program: *const Program,
    writer: *Io.Writer,
    const_cache: std.ArrayList(ConstCacheEntry) = .empty,
    last_assertion_message: ?[]const u8 = null,

    fn runFunction(self: *Executor, module_index: usize, function_name: []const u8, args: []const Binding) ExecutionError!Value {
        const function_decl = self.findFunctionDecl(module_index, function_name) orelse return error.NoSuchFunction;
        var context = CallContext{
            .exec = self,
            .module_index = module_index,
        };
        try context.pushScope();
        defer context.popScope();

        for (function_decl.params) |param| {
            const arg = findBinding(args, textAt(self.program.sources, self.currentDocument(module_index).file_id, param.name)) orelse return error.NoSuchFunction;
            try context.declare(arg.name, arg.value);
        }

        if (try context.evalBlock(function_decl.body, false)) |returned| {
            return returned;
        }
        return error.MissingReturn;
    }

    fn runTest(self: *Executor, module_index: usize, test_decl: tree.TestDecl) ExecutionError!void {
        var context = CallContext{
            .exec = self,
            .module_index = module_index,
        };
        try context.pushScope();
        defer context.popScope();
        _ = try context.evalBlock(test_decl.body, false);
    }

    fn currentDocument(self: *Executor, module_index: usize) tree.Document {
        return self.program.modules[module_index].document;
    }

    fn findFunctionDecl(self: *Executor, module_index: usize, name: []const u8) ?tree.FunctionDecl {
        const document = self.currentDocument(module_index);
        for (document.items) |item| {
            if (item != .function_decl) continue;
            const decl = item.function_decl;
            if (std.mem.eql(u8, name, textAt(self.program.sources, document.file_id, decl.name))) {
                return decl;
            }
        }
        return null;
    }

    fn evalTopLevelConst(self: *Executor, module_index: usize, name: []const u8) ExecutionError!?Value {
        for (self.const_cache.items) |entry| {
            if (entry.module_index == module_index and std.mem.eql(u8, entry.name, name)) {
                return entry.value;
            }
        }

        const document = self.currentDocument(module_index);
        for (document.items) |item| {
            if (item != .const_decl) continue;
            const decl = item.const_decl;
            if (!std.mem.eql(u8, name, textAt(self.program.sources, document.file_id, decl.name))) continue;

            var context = CallContext{
                .exec = self,
                .module_index = module_index,
            };
            const result = try context.evalExpr(decl.initializer);
            const value = switch (result) {
                .value => |inner| inner,
                .returned => |inner| inner,
            };
            try self.const_cache.append(self.program.allocator, .{
                .module_index = module_index,
                .name = name,
                .value = value,
            });
            return value;
        }

        return null;
    }

    fn callBuiltin(self: *Executor, module_path: []const u8, name: []const u8, args: []const Binding) ExecutionError!Value {
        if (std.mem.eql(u8, module_path, "builtin") and std.mem.eql(u8, name, "print")) {
            const value = findBinding(args, "value") orelse return error.UnsupportedBuiltinFunction;
            try writeValue(self.writer, value.value);
            return .void;
        }

        if (std.mem.eql(u8, module_path, "std/string") and std.mem.eql(u8, name, "contains")) {
            const value = expectStringValue((findBinding(args, "value") orelse return error.UnsupportedBuiltinFunction).value);
            const needle = expectStringValue((findBinding(args, "needle") orelse return error.UnsupportedBuiltinFunction).value);
            return .{ .bool = std.mem.indexOf(u8, value, needle) != null };
        }

        if (std.mem.eql(u8, module_path, "std/int") and std.mem.eql(u8, name, "is_valid")) {
            const value = expectStringValue((findBinding(args, "value") orelse return error.UnsupportedBuiltinFunction).value);
            _ = std.fmt.parseInt(i64, value, 10) catch return .{ .bool = false };
            return .{ .bool = true };
        }

        if (std.mem.eql(u8, module_path, "std/int") and std.mem.eql(u8, name, "parse")) {
            const value = expectStringValue((findBinding(args, "value") orelse return error.UnsupportedBuiltinFunction).value);
            const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidIntParse;
            return .{ .int = parsed };
        }

        if (std.mem.eql(u8, module_path, "std/int") and std.mem.eql(u8, name, "to_string")) {
            const value = expectIntValue((findBinding(args, "value") orelse return error.UnsupportedBuiltinFunction).value);
            return .{ .string = try std.fmt.allocPrint(self.program.allocator, "{d}", .{value}) };
        }

        if (std.mem.eql(u8, module_path, "std/assert") and std.mem.eql(u8, name, "equal")) {
            const left = (findBinding(args, "left") orelse return error.UnsupportedBuiltinFunction).value;
            const right = (findBinding(args, "right") orelse return error.UnsupportedBuiltinFunction).value;
            if (!valueEql(left, right)) {
                self.last_assertion_message = "assert.equal failed";
                return error.AssertionFailed;
            }
            return .void;
        }

        if (std.mem.eql(u8, module_path, "std/assert") and std.mem.eql(u8, name, "true")) {
            const value = (findBinding(args, "value") orelse return error.UnsupportedBuiltinFunction).value;
            if (!expectBool(value)) {
                self.last_assertion_message = "assert.true failed";
                return error.AssertionFailed;
            }
            return .void;
        }

        if (std.mem.eql(u8, module_path, "std/assert") and std.mem.eql(u8, name, "false")) {
            const value = (findBinding(args, "value") orelse return error.UnsupportedBuiltinFunction).value;
            if (expectBool(value)) {
                self.last_assertion_message = "assert.false failed";
                return error.AssertionFailed;
            }
            return .void;
        }

        if (std.mem.eql(u8, module_path, "std/assert") and std.mem.eql(u8, name, "fail")) {
            const message = expectStringValue((findBinding(args, "message") orelse return error.UnsupportedBuiltinFunction).value);
            self.last_assertion_message = message;
            return error.AssertionFailed;
        }

        return error.UnsupportedBuiltinFunction;
    }
};

const CallContext = struct {
    exec: *Executor,
    module_index: usize,
    scopes: std.ArrayList(Scope) = .empty,

    fn evalBlock(self: *CallContext, block: tree.Block, create_scope: bool) ExecutionError!?Value {
        if (create_scope) {
            try self.pushScope();
            defer self.popScope();
        }

        for (block.statements) |statement| {
            if (try self.evalStatement(statement)) |returned| {
                return returned;
            }
        }
        return null;
    }

    fn evalStatement(self: *CallContext, statement: tree.Statement) ExecutionError!?Value {
        return switch (statement) {
            .let_stmt => |stmt| blk: {
                const result = try self.evalExpr(stmt.value);
                switch (result) {
                    .returned => |value| break :blk value,
                    .value => |value| try self.declare(self.text(stmt.name), value),
                }
                break :blk null;
            },
            .const_stmt => |stmt| blk: {
                const result = try self.evalExpr(stmt.value);
                switch (result) {
                    .returned => |value| break :blk value,
                    .value => |value| try self.declare(self.text(stmt.name), value),
                }
                break :blk null;
            },
            .bind_stmt => |stmt| try self.evalBindStmt(stmt),
            .if_stmt => |stmt| try self.evalIfStmt(stmt),
            .match_stmt => |expr| blk: {
                const result = try self.evalMatchExpr(expr);
                switch (result) {
                    .returned => |value| break :blk value,
                    .value => break :blk null,
                }
            },
            .return_stmt => |stmt| blk: {
                const result = try self.evalExpr(stmt.value);
                switch (result) {
                    .returned => |value| break :blk value,
                    .value => |value| break :blk value,
                }
            },
            .expr_stmt => |stmt| blk: {
                const result = try self.evalExpr(stmt.value);
                switch (result) {
                    .returned => |value| break :blk value,
                    .value => break :blk null,
                }
            },
        };
    }

    fn evalBindStmt(self: *CallContext, stmt: tree.BindStmt) ExecutionError!?Value {
        const result = try self.evalExpr(stmt.value);
        const value = switch (result) {
            .returned => |returned| return returned,
            .value => |inner| inner,
        };
        const variant = expectVariant(value);
        if (isBuiltinVariant(variant, "Result", "Ok")) {
            try self.declare(self.text(stmt.name), variant.fields[0].value);
            return null;
        }
        if (!isBuiltinVariant(variant, "Result", "Err")) {
            return error.BindElseDidNotExit;
        }

        try self.pushScope();
        defer self.popScope();
        try self.declare(self.text(stmt.else_name), variant.fields[0].value);
        switch (stmt.else_body) {
            .block => |block| return try self.evalBlock(block, true),
            .expr => |expr| {
                const else_result = try self.evalExpr(expr);
                return switch (else_result) {
                    .returned => |returned| returned,
                    .value => error.BindElseDidNotExit,
                };
            },
        }
    }

    fn evalIfStmt(self: *CallContext, stmt: tree.IfStmt) ExecutionError!?Value {
        const condition = try self.evalExpr(stmt.condition);
        const bool_value = switch (condition) {
            .returned => |returned| return returned,
            .value => |inner| expectBool(inner),
        };

        if (bool_value) {
            return try self.evalBlock(stmt.then_block, true);
        }
        if (stmt.else_block) |else_block| {
            return try self.evalBlock(else_block, true);
        }
        return null;
    }

    fn evalExpr(self: *CallContext, expr: *tree.Expr) ExecutionError!EvalResult {
        return switch (expr.*) {
            .bool_literal => |span| .{ .value = .{ .bool = std.mem.eql(u8, self.text(span), "true") } },
            .int_literal => |span| .{ .value = .{ .int = std.fmt.parseInt(i64, self.text(span), 10) catch unreachable } },
            .string_literal => |span| .{ .value = .{ .string = try decodeStringLiteral(self.exec.program.allocator, self.text(span)) } },
            .access_path => |path| .{ .value = try self.evalAccessPath(path) },
            .unary => |value| try self.evalUnaryExpr(value),
            .binary => |value| try self.evalBinaryExpr(value),
            .call => |value| try self.evalCallExpr(value),
            .struct_init => |value| .{ .value = try self.evalStructInitExpr(value) },
            .variant => |value| .{ .value = try self.evalVariantExpr(value) },
            .match_expr => |value| try self.evalMatchExpr(value),
        };
    }

    fn evalUnaryExpr(self: *CallContext, expr: tree.UnaryExpr) ExecutionError!EvalResult {
        const inner = try self.evalExpr(expr.value);
        const value = switch (inner) {
            .returned => |returned| return .{ .returned = returned },
            .value => |actual| actual,
        };
        return switch (expr.operator) {
            .bang => .{ .value = .{ .bool = !expectBool(value) } },
            .minus => .{ .value = .{ .int = -expectIntValue(value) } },
            else => error.UnsupportedOperation,
        };
    }

    fn evalBinaryExpr(self: *CallContext, expr: tree.BinaryExpr) ExecutionError!EvalResult {
        const left_result = try self.evalExpr(expr.left);
        const left = switch (left_result) {
            .returned => |returned| return .{ .returned = returned },
            .value => |value| value,
        };
        const right_result = try self.evalExpr(expr.right);
        const right = switch (right_result) {
            .returned => |returned| return .{ .returned = returned },
            .value => |value| value,
        };

        return .{ .value = switch (expr.operator) {
            .plus => blk: {
                if (left == .string and right == .string) {
                    break :blk .{ .string = try std.fmt.allocPrint(self.exec.program.allocator, "{s}{s}", .{ left.string, right.string }) };
                }
                break :blk .{ .int = expectIntValue(left) + expectIntValue(right) };
            },
            .minus => .{ .int = expectIntValue(left) - expectIntValue(right) },
            .star => .{ .int = expectIntValue(left) * expectIntValue(right) },
            .eq_eq => .{ .bool = valueEql(left, right) },
            .bang_eq => .{ .bool = !valueEql(left, right) },
            .lt => .{ .bool = compareValues(left, right) == .lt },
            .lt_eq => .{ .bool = compareValues(left, right) != .gt },
            .gt => .{ .bool = compareValues(left, right) == .gt },
            .gt_eq => .{ .bool = compareValues(left, right) != .lt },
            else => return error.UnsupportedOperation,
        } };
    }

    fn evalCallExpr(self: *CallContext, expr: tree.CallExpr) ExecutionError!EvalResult {
        const callee_path = switch (expr.callee.*) {
            .access_path => |path| path,
            else => return error.UnsupportedOperation,
        };

        var values = std.ArrayList(Binding).empty;
        for (expr.args) |arg| {
            const result = try self.evalExpr(arg.value);
            switch (result) {
                .returned => |returned| return .{ .returned = returned },
                .value => |value| try values.append(self.exec.program.allocator, .{
                    .name = self.text(arg.name),
                    .value = value,
                }),
            }
        }

        if (self.resolveBuiltinCall(callee_path)) |builtin| {
            return .{ .value = try self.exec.callBuiltin(builtin.module_path, builtin.name, values.items) };
        }

        const user_call = self.resolveUserFunction(callee_path) orelse return error.NoSuchFunction;
        return .{ .value = try self.exec.runFunction(user_call.module_index, user_call.name, values.items) };
    }

    fn evalStructInitExpr(self: *CallContext, expr: tree.StructInitExpr) ExecutionError!Value {
        const struct_ref = self.resolveStruct(expr.type_path) orelse return error.UnsupportedOperation;
        const fields = try self.exec.program.allocator.alloc(StructField, expr.fields.len);
        for (expr.fields, 0..) |field, index| {
            const result = try self.evalExpr(field.value);
            switch (result) {
                .returned => |returned| return returned,
                .value => |value| fields[index] = .{ .name = self.text(field.name), .value = value },
            }
        }
        return .{ .struct_instance = .{
            .module_path = struct_ref.module_path,
            .name = struct_ref.name,
            .fields = fields,
        } };
    }

    fn evalVariantExpr(self: *CallContext, expr: tree.VariantExpr) ExecutionError!Value {
        const root = self.text(expr.path.segments[0]);
        if (std.mem.eql(u8, root, "Ok") or std.mem.eql(u8, root, "Err") or std.mem.eql(u8, root, "Some")) {
            const builtin_owner = if (std.mem.eql(u8, root, "Some")) "Option" else "Result";
            const fields = switch (expr.payload) {
                .positional => |inner| blk: {
                    const result = try self.evalExpr(inner);
                    const value = switch (result) {
                        .returned => |returned| return returned,
                        .value => |actual| actual,
                    };
                    const items = try self.exec.program.allocator.alloc(StructField, 1);
                    items[0] = .{ .name = if (std.mem.eql(u8, root, "Err")) "error" else "value", .value = value };
                    break :blk items;
                },
                .named => return error.UnsupportedOperation,
            };
            return .{ .variant = .{
                .owner_module_path = "builtin",
                .owner_name = builtin_owner,
                .name = root,
                .fields = fields,
            } };
        }

        const owner = self.resolveNamedType(expr.path) orelse return error.UnsupportedOperation;
        const variant_name = self.text(expr.path.segments[expr.path.segments.len - 1]);
        const variant_surface = self.resolveVariantSurface(owner, variant_name) orelse return error.UnsupportedOperation;
        const fields = switch (expr.payload) {
            .positional => |inner| blk: {
                const result = try self.evalExpr(inner);
                const value = switch (result) {
                    .returned => |returned| return returned,
                    .value => |actual| actual,
                };
                const items = try self.exec.program.allocator.alloc(StructField, 1);
                items[0] = .{ .name = variant_surface.fields[0].name, .value = value };
                break :blk items;
            },
            .named => |args| blk: {
                const items = try self.exec.program.allocator.alloc(StructField, args.len);
                for (args, 0..) |arg, index| {
                    const result = try self.evalExpr(arg.value);
                    const value = switch (result) {
                        .returned => |returned| return returned,
                        .value => |actual| actual,
                    };
                    items[index] = .{ .name = self.text(arg.name), .value = value };
                }
                break :blk items;
            },
        };

        return .{ .variant = .{
            .owner_module_path = owner.module_path,
            .owner_name = owner.name,
            .name = variant_name,
            .fields = fields,
        } };
    }

    fn evalMatchExpr(self: *CallContext, expr: tree.MatchExpr) ExecutionError!EvalResult {
        const scrutinee_result = try self.evalExpr(expr.value);
        const scrutinee = switch (scrutinee_result) {
            .returned => |returned| return .{ .returned = returned },
            .value => |value| value,
        };

        for (expr.arms) |arm| {
            var bindings = std.ArrayList(Binding).empty;
            if (try self.matchPattern(scrutinee, arm.pattern, &bindings)) {
                try self.pushScope();
                defer self.popScope();
                for (bindings.items) |binding| {
                    try self.declare(binding.name, binding.value);
                }
                return switch (arm.body) {
                    .block => |block| if (try self.evalBlock(block, true)) |returned| .{ .returned = returned } else .{ .value = .void },
                    .return_stmt => |stmt| blk: {
                        const result = try self.evalExpr(stmt.value);
                        break :blk switch (result) {
                            .returned => |returned| .{ .returned = returned },
                            .value => |value| .{ .returned = value },
                        };
                    },
                    .expr => |inner| try self.evalExpr(inner),
                };
            }
        }

        return error.InvalidPattern;
    }

    fn evalAccessPath(self: *CallContext, path: tree.AccessPath) ExecutionError!Value {
        const root = self.text(path.segments[0]);
        if (path.segments.len == 1) {
            if (std.mem.eql(u8, root, "Void")) return .void;
            if (std.mem.eql(u8, root, "None")) return .{ .variant = .{
                .owner_module_path = "builtin",
                .owner_name = "Option",
                .name = "None",
                .fields = &.{},
            } };
            if (self.lookup(root)) |value| return value;
            if (try self.exec.evalTopLevelConst(self.module_index, root)) |const_value| return const_value;
            return error.UnsupportedOperation;
        }

        if (self.lookup(root)) |value| {
            return try self.evalFieldAccess(value, path.segments[1..]);
        }
        if (try self.exec.evalTopLevelConst(self.module_index, root)) |const_value| {
            return try self.evalFieldAccess(const_value, path.segments[1..]);
        }

        if (try self.zeroPayloadVariantValue(path)) |variant_value| {
            return variant_value;
        }

        return error.UnsupportedOperation;
    }

    fn evalFieldAccess(self: *CallContext, start: Value, segments: []const source.Span) ExecutionError!Value {
        var current = start;
        for (segments) |segment| {
            const field_name = self.text(segment);
            const struct_value = switch (current) {
                .struct_instance => |value| value,
                else => return error.UnsupportedOperation,
            };
            current = findStructField(struct_value.fields, field_name) orelse return error.UnsupportedOperation;
        }
        return current;
    }

    fn matchPattern(self: *CallContext, scrutinee: Value, pattern: tree.Pattern, bindings: *std.ArrayList(Binding)) ExecutionError!bool {
        return switch (pattern) {
            .binding => |value| blk: {
                try bindings.append(self.exec.program.allocator, .{ .name = self.text(value.span), .value = scrutinee });
                break :blk true;
            },
            .path => |value| try self.matchPathPattern(scrutinee, value, bindings),
        };
    }

    fn matchPathPattern(self: *CallContext, scrutinee: Value, pattern: tree.PathPattern, bindings: *std.ArrayList(Binding)) ExecutionError!bool {
        const variant = switch (scrutinee) {
            .variant => |value| value,
            else => return false,
        };
        const root = self.text(pattern.path.segments[0]);

        if (std.mem.eql(u8, root, "None")) {
            return isBuiltinVariant(variant, "Option", "None");
        }
        if (std.mem.eql(u8, root, "Some")) {
            if (!isBuiltinVariant(variant, "Option", "Some")) return false;
            const payload = pattern.payload orelse return false;
            return switch (payload) {
                .positional => |inner| self.matchPattern(variant.fields[0].value, inner.*, bindings),
                .named => false,
            };
        }
        if (std.mem.eql(u8, root, "Ok")) {
            if (!isBuiltinVariant(variant, "Result", "Ok")) return false;
            const payload = pattern.payload orelse return false;
            return switch (payload) {
                .positional => |inner| self.matchPattern(variant.fields[0].value, inner.*, bindings),
                .named => false,
            };
        }
        if (std.mem.eql(u8, root, "Err")) {
            if (!isBuiltinVariant(variant, "Result", "Err")) return false;
            const payload = pattern.payload orelse return false;
            return switch (payload) {
                .positional => |inner| self.matchPattern(variant.fields[0].value, inner.*, bindings),
                .named => false,
            };
        }

        const owner = self.resolveNamedType(pattern.path) orelse return false;
        const variant_name = self.text(pattern.path.segments[pattern.path.segments.len - 1]);
        if (!std.mem.eql(u8, variant.owner_module_path, owner.module_path) or !std.mem.eql(u8, variant.owner_name, owner.name) or !std.mem.eql(u8, variant.name, variant_name)) {
            return false;
        }

        if (pattern.payload == null) {
            return variant.fields.len == 0;
        }

        return switch (pattern.payload.?) {
            .positional => |inner| if (variant.fields.len == 1) self.matchPattern(variant.fields[0].value, inner.*, bindings) else false,
            .named => |fields| blk: {
                for (fields) |field_pattern| {
                    const field_value = findStructField(variant.fields, self.text(field_pattern.name)) orelse break :blk false;
                    if (!try self.matchPattern(field_value, field_pattern.value.*, bindings)) {
                        break :blk false;
                    }
                }
                break :blk true;
            },
        };
    }

    fn resolveBuiltinCall(self: *CallContext, path: tree.AccessPath) ?struct { module_path: []const u8, name: []const u8 } {
        const root = self.text(path.segments[0]);
        if (path.segments.len == 1 and std.mem.eql(u8, root, "print")) {
            return .{ .module_path = "builtin", .name = "print" };
        }
        if (path.segments.len == 2) {
            if (self.findImport(root)) |import_info| {
                if (std.mem.startsWith(u8, import_info.module_path, "std/")) {
                    return .{ .module_path = import_info.module_path, .name = self.text(path.segments[1]) };
                }
            }
        }
        return null;
    }

    fn resolveUserFunction(self: *CallContext, path: tree.AccessPath) ?struct { module_index: usize, name: []const u8 } {
        const root = self.text(path.segments[0]);
        if (path.segments.len == 1 and self.exec.findFunctionDecl(self.module_index, root) != null) {
            return .{ .module_index = self.module_index, .name = root };
        }
        if (path.segments.len == 2) {
            if (self.findImport(root)) |import_info| {
                const target_index = self.exec.program.moduleIndex(import_info.module_path) orelse return null;
                const function_name = self.text(path.segments[1]);
                if (self.exec.findFunctionDecl(target_index, function_name) != null) {
                    return .{ .module_index = target_index, .name = function_name };
                }
            }
        }
        return null;
    }

    fn resolveStruct(self: *CallContext, path: tree.AccessPath) ?types.StructSurface {
        if (path.segments.len == 1) {
            const name = self.text(path.segments[0]);
            if (types.lookupStruct(self.exec.program.surface, self.currentModule().path, name)) |surface| {
                return surface.*;
            }
        }
        if (path.segments.len == 2) {
            const root = self.text(path.segments[0]);
            if (self.findImport(root)) |import_info| {
                if (types.lookupStruct(self.exec.program.surface, import_info.module_path, self.text(path.segments[1]))) |surface| {
                    return surface.*;
                }
            }
        }
        return null;
    }

    fn resolveNamedType(self: *CallContext, path: tree.AccessPath) ?types.NamedType {
        if (path.segments.len == 2) {
            const owner_name = self.text(path.segments[0]);
            if (types.lookupEnum(self.exec.program.surface, self.currentModule().path, owner_name) != null) {
                return .{ .module_path = self.currentModule().path, .name = owner_name, .kind = .enum_type };
            }
            if (types.lookupError(self.exec.program.surface, self.currentModule().path, owner_name) != null) {
                return .{ .module_path = self.currentModule().path, .name = owner_name, .kind = .error_type };
            }
        }
        if (path.segments.len == 3) {
            const root = self.text(path.segments[0]);
            if (self.findImport(root)) |import_info| {
                const owner_name = self.text(path.segments[1]);
                if (types.lookupEnum(self.exec.program.surface, import_info.module_path, owner_name) != null) {
                    return .{ .module_path = import_info.module_path, .name = owner_name, .kind = .enum_type };
                }
                if (types.lookupError(self.exec.program.surface, import_info.module_path, owner_name) != null) {
                    return .{ .module_path = import_info.module_path, .name = owner_name, .kind = .error_type };
                }
            }
        }
        return null;
    }

    fn resolveVariantSurface(self: *CallContext, owner: types.NamedType, variant_name: []const u8) ?types.VariantSurface {
        return switch (owner.kind) {
            .enum_type => blk: {
                const surface = types.lookupEnum(self.exec.program.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            .error_type => blk: {
                const surface = types.lookupError(self.exec.program.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            else => null,
        };
    }

    fn zeroPayloadVariantValue(self: *CallContext, path: tree.AccessPath) ExecutionError!?Value {
        const owner = self.resolveNamedType(path) orelse return null;
        const variant_name = self.text(path.segments[path.segments.len - 1]);
        const variant = self.resolveVariantSurface(owner, variant_name) orelse return null;
        if (variant.fields.len != 0) {
            return null;
        }
        return .{ .variant = .{
            .owner_module_path = owner.module_path,
            .owner_name = owner.name,
            .name = variant_name,
            .fields = &.{},
        } };
    }

    fn currentModule(self: *CallContext) *const ModuleInfo {
        return &self.exec.program.modules[self.module_index];
    }

    fn findImport(self: *CallContext, alias: []const u8) ?ImportInfo {
        for (self.currentModule().imports) |import_info| {
            if (std.mem.eql(u8, import_info.alias, alias)) {
                return import_info;
            }
        }
        return null;
    }

    fn declare(self: *CallContext, name: []const u8, value: Value) ExecutionError!void {
        try self.scopes.items[self.scopes.items.len - 1].bindings.append(self.exec.program.allocator, .{
            .name = name,
            .value = value,
        });
    }

    fn lookup(self: *CallContext, name: []const u8) ?Value {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            for (self.scopes.items[index].bindings.items) |binding| {
                if (std.mem.eql(u8, binding.name, name)) {
                    return binding.value;
                }
            }
        }
        return null;
    }

    fn pushScope(self: *CallContext) ExecutionError!void {
        try self.scopes.append(self.exec.program.allocator, .{});
    }

    fn popScope(self: *CallContext) void {
        _ = self.scopes.pop();
    }

    fn text(self: *CallContext, span: source.Span) []const u8 {
        return textAt(self.exec.program.sources, self.currentModule().document.file_id, span);
    }
};

fn textAt(sources: *const source.Manager, file_id: source.FileId, span: source.Span) []const u8 {
    return span.slice(sources.getFile(file_id).source);
}

fn findBinding(bindings: []const Binding, name: []const u8) ?Binding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) {
            return binding;
        }
    }
    return null;
}

fn findStructField(fields: []const StructField, name: []const u8) ?Value {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field.value;
        }
    }
    return null;
}

fn findVariant(variants: []const types.VariantSurface, name: []const u8) ?types.VariantSurface {
    for (variants) |variant| {
        if (std.mem.eql(u8, variant.name, name)) {
            return variant;
        }
    }
    return null;
}

fn expectBool(value: Value) bool {
    return switch (value) {
        .bool => |actual| actual,
        else => @panic("runtime type mismatch: expected bool"),
    };
}

fn expectIntValue(value: Value) i64 {
    return switch (value) {
        .int => |actual| actual,
        else => @panic("runtime type mismatch: expected int"),
    };
}

fn expectStringValue(value: Value) []const u8 {
    return switch (value) {
        .string => |actual| actual,
        else => @panic("runtime type mismatch: expected string"),
    };
}

fn expectVariant(value: Value) VariantInstance {
    return switch (value) {
        .variant => |actual| actual,
        else => @panic("runtime type mismatch: expected variant"),
    };
}

fn isBuiltinVariant(variant: VariantInstance, owner_name: []const u8, variant_name: []const u8) bool {
    return std.mem.eql(u8, variant.owner_module_path, "builtin") and
        std.mem.eql(u8, variant.owner_name, owner_name) and
        std.mem.eql(u8, variant.name, variant_name);
}

fn valueEql(left: Value, right: Value) bool {
    return switch (left) {
        .void => right == .void,
        .bool => |value| switch (right) { .bool => |other| value == other, else => false },
        .int => |value| switch (right) { .int => |other| value == other, else => false },
        .string => |value| switch (right) { .string => |other| std.mem.eql(u8, value, other), else => false },
        .list => |value| switch (right) {
            .list => |other| listEql(value, other),
            else => false,
        },
        .struct_instance => |value| switch (right) {
            .struct_instance => |other| structEql(value, other),
            else => false,
        },
        .variant => |value| switch (right) {
            .variant => |other| variantEql(value, other),
            else => false,
        },
    };
}

fn structEql(left: StructInstance, right: StructInstance) bool {
    if (!std.mem.eql(u8, left.module_path, right.module_path) or !std.mem.eql(u8, left.name, right.name) or left.fields.len != right.fields.len) {
        return false;
    }
    for (left.fields, right.fields) |left_field, right_field| {
        if (!std.mem.eql(u8, left_field.name, right_field.name) or !valueEql(left_field.value, right_field.value)) {
            return false;
        }
    }
    return true;
}

fn variantEql(left: VariantInstance, right: VariantInstance) bool {
    if (!std.mem.eql(u8, left.owner_module_path, right.owner_module_path) or !std.mem.eql(u8, left.owner_name, right.owner_name) or !std.mem.eql(u8, left.name, right.name) or left.fields.len != right.fields.len) {
        return false;
    }
    for (left.fields, right.fields) |left_field, right_field| {
        if (!std.mem.eql(u8, left_field.name, right_field.name) or !valueEql(left_field.value, right_field.value)) {
            return false;
        }
    }
    return true;
}

fn compareValues(left: Value, right: Value) std.math.Order {
    return switch (left) {
        .int => |value| switch (right) {
            .int => |other| std.math.order(value, other),
            else => @panic("runtime type mismatch: compare int"),
        },
        .string => |value| switch (right) {
            .string => |other| std.mem.order(u8, value, other),
            else => @panic("runtime type mismatch: compare string"),
        },
        else => @panic("unsupported compare"),
    };
}

fn writeValue(writer: *Io.Writer, value: Value) ExecutionError!void {
    switch (value) {
        .void => try writer.writeAll("Void"),
        .bool => |actual| try writer.writeAll(if (actual) "true" else "false"),
        .int => |actual| try writer.print("{d}", .{actual}),
        .string => |actual| try writer.writeAll(actual),
        .list => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index > 0) {
                    try writer.writeAll(", ");
                }
                try writeValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .struct_instance, .variant => return error.UnsupportedOperation,
    }
}

fn listEql(left: []const Value, right: []const Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_item, right_item| {
        if (!valueEql(left_item, right_item)) return false;
    }
    return true;
}

fn isStringListType(ty: types.Type) bool {
    return switch (ty) {
        .generic => |value| value.kind == .list and value.args.len == 1 and value.args[0].eql(.{ .primitive = .string }),
        else => false,
    };
}

fn decodeStringLiteral(allocator: std.mem.Allocator, raw: []const u8) ExecutionError![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var index: usize = 1;
    while (index < raw.len - 1) : (index += 1) {
        const byte = raw[index];
        if (byte == '\\') {
            index += 1;
            const escaped = raw[index];
            switch (escaped) {
                '\\', '"' => try out.writer.writeByte(escaped),
                'n' => try out.writer.writeByte('\n'),
                'r' => try out.writer.writeByte('\r'),
                't' => try out.writer.writeByte('\t'),
                else => return error.UnsupportedOperation,
            }
        } else {
            try out.writer.writeByte(byte);
        }
    }

    return try out.toOwnedSlice();
}

fn testMatchesTarget(module: ModuleInfo, file_path: []const u8, target: ?[]const u8) bool {
    const value = target orelse return true;
    if (std.mem.endsWith(u8, value, ".lace")) {
        return std.mem.eql(u8, file_path, value);
    }
    if (std.mem.eql(u8, module.path, value) or std.mem.startsWith(u8, module.path, value)) {
        return true;
    }
    for (module.imports) |import_info| {
        if (std.mem.eql(u8, import_info.module_path, value)) {
            return true;
        }
    }
    return false;
}

test "interpreter runs a bind-based spec program end to end" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var diagnostics: diag.Store = .{};

    const program_source =
        "module main;\n\n" ++
        "pub error AppError {\n" ++
        "    invalid_name,\n" ++
        "}\n\n" ++
        "fn greet(\n" ++
        "    name: String,\n" ++
        ") -> Result<String, AppError> {\n" ++
        "    if name == \"\" {\n" ++
        "        return Err(AppError.invalid_name);\n" ++
        "    }\n\n" ++
        "    return Ok(\"hello \" + name);\n" ++
        "}\n\n" ++
        "pub fn main() -> Result<Void, AppError> {\n" ++
        "    bind message: String = greet(\n" ++
        "        name: \"Sam\",\n" ++
        "    ) else err => {\n" ++
        "        return Err(err);\n" ++
        "    };\n\n" ++
        "    print(value: message);\n\n" ++
        "    return Ok(Void);\n" ++
        "}\n";

    const file_id = try sources.addSource(std.testing.allocator, "src/main.lace", program_source);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try @import("../syntax/mod.zig").parseFile(arena, &diagnostics, sources.getFile(file_id));
    var program = try prepareProgram(arena, &diagnostics, &sources, &.{document});

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const result = try runMain(&program, &output.writer);

    try std.testing.expect(valueEql(result, .{ .variant = .{
        .owner_module_path = "builtin",
        .owner_name = "Result",
        .name = "Ok",
        .fields = &.{.{ .name = "value", .value = .void }},
    } }));
    try std.testing.expectEqualStrings("hello Sam", output.written());
}

test "interpreter runs an imported module and stdlib call" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var diagnostics: diag.Store = .{};

    const user_id = try sources.addSource(std.testing.allocator, "src/app/user.lace",
        "module app/user;\n\n" ++
        "pub struct User {\n" ++
        "    name: String,\n" ++
        "}\n\n" ++
        "pub fn make(\n" ++
        "    name: String,\n" ++
        ") -> User {\n" ++
        "    return User{\n" ++
        "        name: name,\n" ++
        "    };\n" ++
        "}\n");
    const main_id = try sources.addSource(std.testing.allocator, "src/main.lace",
        "module main;\n\n" ++
        "import app/user;\n" ++
        "import std/string;\n\n" ++
        "pub error AppError {\n" ++
        "    invalid_name,\n" ++
        "}\n\n" ++
        "fn main() -> Result<Void, AppError> {\n" ++
        "    let current: user.User = user.make(name: \"Sam\");\n" ++
        "    if !string.contains(value: current.name, needle: \"S\") {\n" ++
        "        return Err(AppError.invalid_name);\n" ++
        "    }\n\n" ++
        "    print(value: current.name);\n" ++
        "    return Ok(Void);\n" ++
        "}\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_doc = try @import("../syntax/mod.zig").parseFile(arena, &diagnostics, sources.getFile(user_id));
    const main_doc = try @import("../syntax/mod.zig").parseFile(arena, &diagnostics, sources.getFile(main_id));
    var program = try prepareProgram(arena, &diagnostics, &sources, &.{ user_doc, main_doc });

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    _ = try runMain(&program, &output.writer);
    try std.testing.expectEqualStrings("Sam", output.written());
}

test "interpreter fails clearly on unsupported stdlib functions" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var diagnostics: diag.Store = .{};

    const file_id = try sources.addSource(std.testing.allocator, "src/main.lace",
        "module main;\n\n" ++
        "import std/fs;\n\n" ++
        "fn main() -> Result<Void, fs.FsError> {\n" ++
        "    let contents = fs.read_file(path: \"/tmp/demo\");\n" ++
        "    return Ok(Void);\n" ++
        "}\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try @import("../syntax/mod.zig").parseFile(arena, &diagnostics, sources.getFile(file_id));
    var program = try prepareProgram(arena, &diagnostics, &sources, &.{document});
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(error.UnsupportedBuiltinFunction, runMain(&program, &output.writer));
}

test "discoverTests finds sorted test cases in _test files" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var diagnostics: diag.Store = .{};

    const file_a = try sources.addSource(std.testing.allocator, "src/feature_test.lace",
        "module feature_test;\n\ntest \"b\" {\n    return Void;\n}\n\ntest \"a\" {\n    return Void;\n}\n");
    const file_b = try sources.addSource(std.testing.allocator, "tests/integration_test.lace",
        "module integration_test;\n\nimport feature_test;\n\ntest \"integration\" {\n    return Void;\n}\n");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc_a = try @import("../syntax/mod.zig").parseFile(arena, &diagnostics, sources.getFile(file_a));
    const doc_b = try @import("../syntax/mod.zig").parseFile(arena, &diagnostics, sources.getFile(file_b));
    var program = try prepareProgram(arena, &diagnostics, &sources, &.{ doc_a, doc_b });

    const tests = try discoverTests(arena, &program, null);
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    try std.testing.expectEqualStrings("a", tests[0].name);
    try std.testing.expectEqualStrings("b", tests[1].name);
    try std.testing.expectEqualStrings("integration", tests[2].name);
}

test "runTestCase reports assertion failures" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var diagnostics: diag.Store = .{};

    const file_id = try sources.addSource(std.testing.allocator, "tests/assert_test.lace",
        "module assert_test;\n\nimport std/assert;\n\ntest \"fails\" {\n    assert.equal(left: 1, right: 2);\n}\n");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try @import("../syntax/mod.zig").parseFile(arena, &diagnostics, sources.getFile(file_id));
    var program = try prepareProgram(arena, &diagnostics, &sources, &.{document});
    const tests = try discoverTests(arena, &program, null);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const result = try runTestCase(&program, &output.writer, tests[0]);
    try std.testing.expectEqual(TestStatus.failed, result.status);
    try std.testing.expectEqualStrings("assert.equal failed", result.message.?);
}
