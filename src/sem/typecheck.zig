const std = @import("std");

const diag = @import("../diag/mod.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax/mod.zig");
const tree = @import("../syntax/tree.zig");
const resolution = @import("resolution.zig");
const types = @import("types.zig");
const validation = @import("validation.zig");

pub fn typecheckDocuments(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    documents: []const tree.Document,
) !types.PackageSurface {
    const diagnostic_count = diagnostics.count();
    try validation.validateDocuments(allocator, diagnostics, sources, documents);
    const package = try resolution.resolveDocuments(allocator, diagnostics, sources, documents);
    const surface = try types.buildPackageSurface(allocator, sources, documents);

    if (diagnostics.count() != diagnostic_count) {
        return surface;
    }

    for (documents, package.modules) |document, module| {
        var checker = Checker.init(allocator, diagnostics, sources, documents, surface, module, document);
        try checker.checkModule();
    }

    return surface;
}

const CheckError = error{OutOfMemory};

const Checker = struct {
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    sources: *const source.Manager,
    documents: []const tree.Document,
    surface: types.PackageSurface,
    module: resolution.Module,
    document: tree.Document,
    const_types: std.StringHashMapUnmanaged(types.Type) = .empty,
    scopes: std.ArrayList(LocalScope) = .empty,
    current_return_type: ?types.Type = null,

    fn init(
        allocator: std.mem.Allocator,
        diagnostics: *diag.Store,
        sources: *const source.Manager,
        documents: []const tree.Document,
        surface: types.PackageSurface,
        module: resolution.Module,
        document: tree.Document,
    ) Checker {
        return .{
            .allocator = allocator,
            .diagnostics = diagnostics,
            .sources = sources,
            .documents = documents,
            .surface = surface,
            .module = module,
            .document = document,
        };
    }

    fn checkModule(self: *Checker) CheckError!void {
        for (self.document.items) |item| {
            if (item == .const_decl) {
                const decl = item.const_decl;
                if (self.resolveTypeRef(decl.type_ref)) |ty| {
                    try self.const_types.put(self.allocator, self.text(decl.name), ty);
                }
            }
        }

        for (self.document.items) |item| switch (item) {
            .const_decl => |decl| try self.checkTopLevelConst(decl),
            .function_decl => |decl| try self.checkFunction(decl),
            .test_decl => |decl| try self.checkTest(decl),
            else => {},
        };
    }

    fn checkTopLevelConst(self: *Checker, decl: tree.ConstDecl) CheckError!void {
        const expected = self.resolveTypeRef(decl.type_ref) orelse return;
        const actual = try self.checkExpr(decl.initializer, expected);
        if (actual) |actual_type| {
            try self.expectAssignable(decl.initializer.*.span(), expected, actual_type, "T1101", "Constant initializer type does not match declared type");
        }
    }

    fn checkFunction(self: *Checker, decl: tree.FunctionDecl) CheckError!void {
        const return_type = self.resolveTypeRef(decl.return_type) orelse return;
        const previous_return_type = self.current_return_type;
        self.current_return_type = return_type;
        defer self.current_return_type = previous_return_type;

        try self.pushScope();
        defer self.popScope();

        for (decl.params) |param| {
            const param_type = self.resolveTypeRef(param.type_ref) orelse continue;
            try self.declareLocal(self.text(param.name), param_type);
        }

        try self.checkBlock(decl.body, false);
    }

    fn checkTest(self: *Checker, decl: tree.TestDecl) CheckError!void {
        const previous_return_type = self.current_return_type;
        self.current_return_type = null;
        defer self.current_return_type = previous_return_type;

        try self.pushScope();
        defer self.popScope();
        try self.checkBlock(decl.body, false);
    }

    fn checkBlock(self: *Checker, block: tree.Block, create_scope: bool) CheckError!void {
        if (create_scope) {
            try self.pushScope();
            defer self.popScope();
        }

        for (block.statements) |statement| {
            try self.checkStatement(statement);
        }
    }

    fn checkStatement(self: *Checker, statement: tree.Statement) CheckError!void {
        switch (statement) {
            .let_stmt => |stmt| try self.checkLetStmt(stmt),
            .const_stmt => |stmt| try self.checkConstStmt(stmt),
            .bind_stmt => |stmt| try self.checkBindStmt(stmt),
            .if_stmt => |stmt| try self.checkIfStmt(stmt),
            .match_stmt => |stmt| {
                if (try self.checkMatchExpr(stmt, null)) |match_type| {
                    try self.reportUnhandledRecoverable(stmt.span, match_type);
                }
            },
            .return_stmt => |stmt| try self.checkReturnStmt(stmt),
            .expr_stmt => |stmt| {
                if (try self.checkExpr(stmt.value, null)) |expr_type| {
                    try self.reportUnhandledRecoverable(stmt.span, expr_type);
                }
            },
        }
    }

    fn checkLetStmt(self: *Checker, stmt: tree.LetStmt) CheckError!void {
        if (stmt.type_ref) |type_ref| {
            const expected = self.resolveTypeRef(type_ref) orelse return;
            const actual = try self.checkExpr(stmt.value, expected);
            if (actual) |actual_type| {
                try self.expectAssignable(stmt.value.*.span(), expected, actual_type, "T1102", "Local binding type does not match declared type");
                try self.declareLocal(self.text(stmt.name), expected);
            }
        } else {
            const actual = try self.checkExpr(stmt.value, null);
            if (actual) |actual_type| {
                if (!isConcreteType(actual_type)) {
                    try self.report("T1103", "Local inference requires an obvious concrete type", stmt.name, self.text(stmt.name));
                    return;
                }
                try self.declareLocal(self.text(stmt.name), actual_type);
            }
        }
    }

    fn checkConstStmt(self: *Checker, stmt: tree.ConstStmt) CheckError!void {
        if (stmt.type_ref) |type_ref| {
            const expected = self.resolveTypeRef(type_ref) orelse return;
            const actual = try self.checkExpr(stmt.value, expected);
            if (actual) |actual_type| {
                try self.expectAssignable(stmt.value.*.span(), expected, actual_type, "T1104", "Local constant type does not match declared type");
                try self.declareLocal(self.text(stmt.name), expected);
            }
        } else {
            const actual = try self.checkExpr(stmt.value, null);
            if (actual) |actual_type| {
                if (!isConcreteType(actual_type)) {
                    try self.report("T1103", "Local inference requires an obvious concrete type", stmt.name, self.text(stmt.name));
                    return;
                }
                try self.declareLocal(self.text(stmt.name), actual_type);
            }
        }
    }

    fn checkBindStmt(self: *Checker, stmt: tree.BindStmt) CheckError!void {
        const result_type = try self.checkExpr(stmt.value, null) orelse return;
        const success_type, const error_type = switch (result_type) {
            .generic => |value| switch (value.kind) {
                .result => blk: {
                    if (value.args.len != 2) break :blk .{ null, null };
                    break :blk .{ value.args[0], value.args[1] };
                },
                else => .{ null, null },
            },
            else => .{ null, null },
        };

        if (success_type == null or error_type == null) {
            try self.report("T1115", "`bind` requires a `Result<T, E>` value", stmt.value.*.span(), self.text(stmt.name));
            return;
        }

        if (stmt.type_ref) |type_ref| {
            const expected = self.resolveTypeRef(type_ref) orelse return;
            try self.expectAssignable(stmt.name, expected, success_type.?, "T1102", "Bind target type does not match result success type");
        }

        try self.pushScope();
        try self.declareLocal(self.text(stmt.else_name), error_type.?);
        switch (stmt.else_body) {
            .block => |block| try self.checkBlock(block, true),
            .expr => |expr| _ = try self.checkExpr(expr, null),
        }
        self.popScope();
        try self.declareLocal(self.text(stmt.name), success_type.?);
    }

    fn checkIfStmt(self: *Checker, stmt: tree.IfStmt) CheckError!void {
        const condition_type = try self.checkExpr(stmt.condition, .{ .primitive = .bool });
        if (condition_type) |actual| {
            try self.expectAssignable(stmt.condition.*.span(), .{ .primitive = .bool }, actual, "T1105", "If conditions must have type `Bool`");
        }

        try self.checkBlock(stmt.then_block, true);
        if (stmt.else_block) |else_block| {
            try self.checkBlock(else_block, true);
        }
    }

    fn checkReturnStmt(self: *Checker, stmt: tree.ReturnStmt) CheckError!void {
        const expected = self.current_return_type orelse return;
        const actual = try self.checkExpr(stmt.value, expected);
        if (actual) |actual_type| {
            try self.expectAssignable(stmt.value.*.span(), expected, actual_type, "T1106", "Return type does not match function return type");
        }
    }

    fn checkExpr(self: *Checker, expr: *tree.Expr, expected: ?types.Type) CheckError!?types.Type {
        return switch (expr.*) {
            .bool_literal => .{ .primitive = .bool },
            .int_literal => .{ .primitive = .int },
            .string_literal => .{ .primitive = .string },
            .access_path => |path| try self.checkAccessPath(path, expected),
            .unary => |value| try self.checkUnaryExpr(value),
            .binary => |value| try self.checkBinaryExpr(value),
            .call => |value| try self.checkCallExpr(value),
            .struct_init => |value| try self.checkStructInitExpr(value),
            .variant => |value| try self.checkVariantExpr(value, expected),
            .match_expr => |value| try self.checkMatchExpr(value, expected),
        };
    }

    fn checkUnaryExpr(self: *Checker, expr: tree.UnaryExpr) CheckError!?types.Type {
        const value_type = try self.checkExpr(expr.value, null) orelse return null;
        return switch (expr.operator) {
            .bang => blk: {
                try self.expectAssignable(expr.value.*.span(), .{ .primitive = .bool }, value_type, "T1107", "Logical negation requires `Bool`");
                break :blk .{ .primitive = .bool };
            },
            .minus => blk: {
                if (!value_type.eql(.{ .primitive = .int }) and !value_type.eql(.{ .primitive = .float })) {
                    try self.report("T1108", "Unary minus requires `Int` or `Float`", expr.value.*.span(), null);
                    break :blk null;
                }
                break :blk value_type;
            },
            else => null,
        };
    }

    fn checkBinaryExpr(self: *Checker, expr: tree.BinaryExpr) CheckError!?types.Type {
        const left = try self.checkExpr(expr.left, null) orelse return null;
        const right = try self.checkExpr(expr.right, null) orelse return null;

        if (!left.eql(right)) {
            try self.report("T1109", "Binary operands must have matching types", expr.span, null);
            return null;
        }

        return switch (expr.operator) {
            .plus => blk: {
                if (left.eql(.{ .primitive = .int }) or left.eql(.{ .primitive = .float }) or left.eql(.{ .primitive = .string })) {
                    break :blk left;
                }
                try self.report("T1110", "`+` supports `Int`, `Float`, and `String` operands", expr.span, null);
                break :blk null;
            },
            .minus, .star => blk: {
                if (left.eql(.{ .primitive = .int }) or left.eql(.{ .primitive = .float })) {
                    break :blk left;
                }
                try self.report("T1111", "Arithmetic operators require `Int` or `Float` operands", expr.span, null);
                break :blk null;
            },
            .eq_eq, .bang_eq => .{ .primitive = .bool },
            .lt, .lt_eq, .gt, .gt_eq => blk: {
                if (left.eql(.{ .primitive = .int }) or left.eql(.{ .primitive = .float }) or left.eql(.{ .primitive = .string })) {
                    break :blk .{ .primitive = .bool };
                }
                try self.report("T1112", "Comparison operators require ordered operands", expr.span, null);
                break :blk null;
            },
            else => null,
        };
    }

    fn checkCallExpr(self: *Checker, expr: tree.CallExpr) CheckError!?types.Type {
        const callee_path = switch (expr.callee.*) {
            .access_path => |path| path,
            else => {
                try self.report("T1113", "Call target is not callable", expr.callee.*.span(), null);
                return null;
            },
        };

        const function_signature = self.resolveFunction(callee_path) orelse {
            try self.report("T1113", "Call target is not callable", expr.callee.*.span(), self.text(callee_path.segments[0]));
            return null;
        };

        var generic_bindings: std.ArrayList(TypeBinding) = .empty;

        for (function_signature.params) |param| {
            const arg = self.findArgument(expr.args, param.name) orelse {
                try self.report("T1114", "Missing required named argument", expr.span, param.name);
                return null;
            };

            const actual = try self.checkExpr(arg.value, param.ty) orelse return null;
            if (!try self.matchType(param.ty, actual, &generic_bindings)) {
                try self.report("T1116", "Named argument has the wrong type", arg.span, param.name);
                return null;
            }
        }

        for (expr.args) |arg| {
            if (findParam(function_signature.params, self.text(arg.name)) == null) {
                try self.report("T1117", "Unknown named argument", arg.span, self.text(arg.name));
                return null;
            }
        }

        return try self.instantiateType(function_signature.return_type, &generic_bindings);
    }

    fn checkStructInitExpr(self: *Checker, expr: tree.StructInitExpr) CheckError!?types.Type {
        const struct_surface = self.resolveStruct(expr.type_path) orelse {
            try self.report("T1118", "Struct initializer must target a known struct type", expr.type_path.span, self.text(expr.type_path.segments[0]));
            return null;
        };

        for (expr.fields) |field| {
            const field_surface = findField(struct_surface.fields, self.text(field.name)) orelse {
                try self.report("T1119", "Unknown struct field", field.span, self.text(field.name));
                return null;
            };

            const actual = try self.checkExpr(field.value, field_surface.ty) orelse return null;
            try self.expectAssignable(field.value.*.span(), field_surface.ty, actual, "T1120", "Struct field value does not match field type");
        }

        for (struct_surface.fields) |field_surface| {
            if (self.findArgument(expr.fields, field_surface.name) == null) {
                try self.report("T1121", "Missing required struct field", expr.span, field_surface.name);
                return null;
            }
        }

        return .{ .named = .{ .module_path = struct_surface.module_path, .name = struct_surface.name, .kind = .struct_type } };
    }

    fn checkVariantExpr(self: *Checker, expr: tree.VariantExpr, expected: ?types.Type) CheckError!?types.Type {
        const root = self.text(expr.path.segments[0]);

        if (std.mem.eql(u8, root, "Ok")) {
            const expected_result = expected orelse {
                try self.report("T1122", "`Ok(...)` needs an expected `Result<T, E>` context", expr.span, null);
                return null;
            };
            const success_type = resultSuccessType(expected_result) orelse {
                try self.report("T1123", "`Ok(...)` expects a `Result<T, E>` target type", expr.span, null);
                return null;
            };
            const inner = switch (expr.payload) {
                .positional => |value| value,
                .named => {
                    try self.report("T1124", "`Ok(...)` accepts a single positional value", expr.span, null);
                    return null;
                },
            };
            const actual = try self.checkExpr(inner, success_type) orelse return null;
            try self.expectAssignable(inner.*.span(), success_type, actual, "T1125", "`Ok(...)` payload does not match the result success type");
            return expected_result;
        }

        if (std.mem.eql(u8, root, "Err")) {
            const expected_result = expected orelse {
                try self.report("T1126", "`Err(...)` needs an expected `Result<T, E>` context", expr.span, null);
                return null;
            };
            const error_type = resultErrorType(expected_result) orelse {
                try self.report("T1127", "`Err(...)` expects a `Result<T, E>` target type", expr.span, null);
                return null;
            };
            const inner = switch (expr.payload) {
                .positional => |value| value,
                .named => {
                    try self.report("T1128", "`Err(...)` accepts a single positional value", expr.span, null);
                    return null;
                },
            };
            const actual = try self.checkExpr(inner, error_type) orelse return null;
            try self.expectAssignable(inner.*.span(), error_type, actual, "T1129", "`Err(...)` payload does not match the result error type");
            return expected_result;
        }

        if (std.mem.eql(u8, root, "Some")) {
            const inner = switch (expr.payload) {
                .positional => |value| value,
                .named => {
                    try self.report("T1130", "`Some(...)` accepts a single positional value", expr.span, null);
                    return null;
                },
            };
            if (expected) |expected_option| {
                const some_type = optionInnerType(expected_option) orelse {
                    try self.report("T1131", "`Some(...)` expects an `Option<T>` target type", expr.span, null);
                    return null;
                };
                const actual = try self.checkExpr(inner, some_type) orelse return null;
                try self.expectAssignable(inner.*.span(), some_type, actual, "T1132", "`Some(...)` payload does not match the option inner type");
                return expected_option;
            }

            const actual = try self.checkExpr(inner, null) orelse return null;
            const args = try self.allocator.alloc(types.Type, 1);
            args[0] = actual;
            return .{ .generic = .{ .kind = .option, .args = args } };
        }

        return self.checkNamedVariantExpr(expr);
    }

    fn checkNamedVariantExpr(self: *Checker, expr: tree.VariantExpr) CheckError!?types.Type {
        const owner = self.resolveNamedTypeFromPath(expr.path) orelse {
            try self.report("T1133", "Variant constructor must reference a known enum or error type", expr.path.span, null);
            return null;
        };

        const variant_name = self.text(expr.path.segments[expr.path.segments.len - 1]);
        const variant = switch (owner.kind) {
            .enum_type => blk: {
                const surface = types.lookupEnum(self.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            .error_type => blk: {
                const surface = types.lookupError(self.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            else => null,
        } orelse {
            try self.report("T1134", "Unknown enum or error variant", expr.path.span, variant_name);
            return null;
        };

        switch (expr.payload) {
            .positional => |inner| {
                if (variant.fields.len != 1) {
                    try self.report("T1135", "Variant payload does not match variant field shape", expr.span, variant_name);
                    return null;
                }
                const actual = try self.checkExpr(inner, variant.fields[0].ty) orelse return null;
                try self.expectAssignable(inner.*.span(), variant.fields[0].ty, actual, "T1136", "Variant payload type does not match field type");
            },
            .named => |fields| {
                for (fields) |field| {
                    const expected_field = findField(variant.fields, self.text(field.name)) orelse {
                        try self.report("T1137", "Unknown variant field", field.span, self.text(field.name));
                        return null;
                    };
                    const actual = try self.checkExpr(field.value, expected_field.ty) orelse return null;
                    try self.expectAssignable(field.value.*.span(), expected_field.ty, actual, "T1138", "Variant field value does not match field type");
                }
                for (variant.fields) |expected_field| {
                    if (self.findArgument(fields, expected_field.name) == null) {
                        try self.report("T1139", "Missing required variant field", expr.span, expected_field.name);
                        return null;
                    }
                }
            },
        }

        return .{ .named = owner };
    }

    fn checkMatchExpr(self: *Checker, expr: tree.MatchExpr, expected: ?types.Type) CheckError!?types.Type {
        const scrutinee_type = try self.checkExpr(expr.value, null) orelse return null;
        var result_type: ?types.Type = null;
        var coverage = Coverage.init(self.allocator, self.surface, scrutinee_type);

        for (expr.arms) |arm| {
            try self.pushScope();
            const coverage_result = try self.checkPattern(arm.pattern, scrutinee_type);
            defer self.popScope();

            switch (coverage_result) {
                .catch_all => coverage.catch_all = true,
                .label => |label| try coverage.markSeen(label),
                .none => {},
            }

            switch (arm.body) {
                .block => |block| try self.checkBlock(block, true),
                .return_stmt => |stmt| try self.checkReturnStmt(stmt),
                .expr => |inner| {
                    const actual = try self.checkExpr(inner, expected) orelse continue;
                    if (result_type) |existing| {
                        try self.expectAssignable(inner.*.span(), existing, actual, "T1140", "Match arm expression types must agree");
                    } else {
                        result_type = actual;
                    }
                },
            }
        }

        if (!coverage.isExhaustive()) {
            try self.report("T1147", "Match expression is not exhaustive", expr.span, coverage.firstMissing());
        }

        return result_type orelse expected;
    }

    fn checkPattern(self: *Checker, pattern: tree.Pattern, scrutinee_type: types.Type) CheckError!PatternCoverage {
        return switch (pattern) {
            .binding => |value| blk: {
                try self.declareLocal(self.text(value.span), scrutinee_type);
                break :blk .catch_all;
            },
            .path => |value| try self.checkPathPattern(value, scrutinee_type),
        };
    }

    fn checkPathPattern(self: *Checker, pattern: tree.PathPattern, scrutinee_type: types.Type) CheckError!PatternCoverage {
        const root = self.text(pattern.path.segments[0]);

        if (std.mem.eql(u8, root, "None")) {
            if (pattern.payload != null) {
                try self.report("T1148", "`None` does not accept a payload pattern", pattern.span, null);
                return .none;
            }
            if (optionInnerType(scrutinee_type) == null) {
                try self.report("T1149", "`None` patterns require an `Option<T>` scrutinee", pattern.span, null);
                return .none;
            }
            return .{ .label = "None" };
        }

        if (std.mem.eql(u8, root, "Some")) {
            const inner_type = optionInnerType(scrutinee_type) orelse {
                try self.report("T1150", "`Some(...)` patterns require an `Option<T>` scrutinee", pattern.span, null);
                return .none;
            };
            if (pattern.payload == null) {
                try self.report("T1151", "`Some(...)` patterns require a payload pattern", pattern.span, null);
                return .none;
            }
            switch (pattern.payload.?) {
                .positional => |inner| {
                    _ = try self.checkPattern(inner.*, inner_type);
                },
                .named => {
                    try self.report("T1152", "`Some(...)` patterns accept a single positional payload", pattern.span, null);
                    return .none;
                },
            }
            return .{ .label = "Some" };
        }

        if (std.mem.eql(u8, root, "Ok") or std.mem.eql(u8, root, "Err")) {
            const payload_type = if (std.mem.eql(u8, root, "Ok"))
                resultSuccessType(scrutinee_type)
            else
                resultErrorType(scrutinee_type);

            const matched_type = payload_type orelse {
                try self.report("T1153", "`Ok(...)` and `Err(...)` patterns require a `Result<T, E>` scrutinee", pattern.span, null);
                return .none;
            };

            if (pattern.payload == null) {
                try self.report("T1154", "`Ok(...)` and `Err(...)` patterns require a payload pattern", pattern.span, null);
                return .none;
            }

            switch (pattern.payload.?) {
                .positional => |inner| {
                    _ = try self.checkPattern(inner.*, matched_type);
                },
                .named => {
                    try self.report("T1155", "`Ok(...)` and `Err(...)` patterns accept a single positional payload", pattern.span, null);
                    return .none;
                },
            }

            return .{ .label = root };
        }

        return try self.checkNamedVariantPattern(pattern, scrutinee_type);
    }

    fn checkNamedVariantPattern(self: *Checker, pattern: tree.PathPattern, scrutinee_type: types.Type) CheckError!PatternCoverage {
        const owner = self.resolveNamedTypeFromPath(pattern.path) orelse {
            try self.report("T1156", "Pattern must reference a known enum or error variant", pattern.span, null);
            return .none;
        };

        if (!scrutinee_type.eql(.{ .named = owner })) {
            try self.report("T1157", "Pattern does not match the scrutinee type", pattern.span, owner.name);
            return .none;
        }

        const variant_name = self.text(pattern.path.segments[pattern.path.segments.len - 1]);
        const variant = switch (owner.kind) {
            .enum_type => blk: {
                const surface = types.lookupEnum(self.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            .error_type => blk: {
                const surface = types.lookupError(self.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            else => null,
        } orelse {
            try self.report("T1158", "Unknown enum or error variant in pattern", pattern.span, variant_name);
            return .none;
        };

        if (variant.fields.len == 0) {
            if (pattern.payload != null) {
                try self.report("T1159", "This variant does not accept a payload pattern", pattern.span, variant_name);
                return .none;
            }
            return .{ .label = variant_name };
        }

        const payload = pattern.payload orelse {
            try self.report("T1160", "Pattern must destructure all variant fields explicitly", pattern.span, variant_name);
            return .none;
        };

        switch (payload) {
            .positional => |inner| {
                if (variant.fields.len != 1) {
                    try self.report("T1161", "Positional pattern payloads are only valid for single-field variants", pattern.span, variant_name);
                    return .none;
                }
                _ = try self.checkPattern(inner.*, variant.fields[0].ty);
            },
            .named => |fields| {
                for (fields) |field| {
                    const expected_field = findField(variant.fields, self.text(field.name)) orelse {
                        try self.report("T1162", "Unknown variant pattern field", field.span, self.text(field.name));
                        return .none;
                    };
                    _ = try self.checkPattern(field.value.*, expected_field.ty);
                }
                for (variant.fields) |expected_field| {
                    if (self.findPatternField(fields, expected_field.name) == null) {
                        try self.report("T1163", "Missing required variant pattern field", pattern.span, expected_field.name);
                        return .none;
                    }
                }
            },
        }

        return .{ .label = variant_name };
    }

    fn checkAccessPath(self: *Checker, path: tree.AccessPath, expected: ?types.Type) CheckError!?types.Type {
        if (path.segments.len == 0) {
            return null;
        }

        const root = self.text(path.segments[0]);
        if (std.mem.eql(u8, root, "None")) {
            if (expected) |expected_type| {
                if (optionInnerType(expected_type) != null) {
                    return expected_type;
                }
            }
            try self.report("T1141", "`None` requires an `Option<T>` context", path.span, null);
            return null;
        }

        if (std.mem.eql(u8, root, "Void") and path.segments.len == 1) {
            return .{ .primitive = .void };
        }

        if (path.segments.len == 1) {
            if (self.lookupLocal(root)) |local_type| {
                return local_type;
            }
            if (self.const_types.get(root)) |const_type| {
                return const_type;
            }
            return null;
        }

        if (self.lookupLocal(root)) |local_type| {
            return self.checkFieldAccess(path, local_type);
        }

        if (self.const_types.get(root)) |const_type| {
            return self.checkFieldAccess(path, const_type);
        }

        return self.checkVariantAccess(path);
    }

    fn checkFieldAccess(self: *Checker, path: tree.AccessPath, base_type: types.Type) CheckError!?types.Type {
        var current = base_type;
        for (path.segments[1..]) |segment| {
            const named = switch (current) {
                .named => |value| value,
                else => {
                    try self.report("T1142", "Field access requires a struct value", segment, self.text(segment));
                    return null;
                },
            };

            const struct_surface = types.lookupStruct(self.surface, named.module_path, named.name) orelse {
                try self.report("T1142", "Field access requires a struct value", segment, self.text(segment));
                return null;
            };

            const field = findField(struct_surface.fields, self.text(segment)) orelse {
                try self.report("T1143", "Unknown struct field", segment, self.text(segment));
                return null;
            };
            current = field.ty;
        }
        return current;
    }

    fn checkVariantAccess(self: *Checker, path: tree.AccessPath) CheckError!?types.Type {
        const owner = self.resolveNamedTypeFromPath(path) orelse return null;
        const variant_name = self.text(path.segments[path.segments.len - 1]);
        const variant = switch (owner.kind) {
            .enum_type => blk: {
                const surface = types.lookupEnum(self.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            .error_type => blk: {
                const surface = types.lookupError(self.surface, owner.module_path, owner.name) orelse break :blk null;
                break :blk findVariant(surface.variants, variant_name);
            },
            else => null,
        } orelse return null;

        if (variant.fields.len != 0) {
            try self.report("T1144", "Payload variants must be called with arguments", path.span, variant_name);
            return null;
        }

        return .{ .named = owner };
    }

    fn resolveFunction(self: *Checker, path: tree.AccessPath) ?types.FunctionSignature {
        const root = self.text(path.segments[0]);
        if (std.mem.eql(u8, root, "print") and path.segments.len == 1) {
            return builtinPrintSignature();
        }

        if (path.segments.len == 1) {
            if (types.lookupFunction(self.surface, self.module.path, root)) |function| {
                return function.*;
            }
            return null;
        }

        if (path.segments.len == 2) {
            const import_binding = self.findImport(root) orelse return null;
            const function_name = self.text(path.segments[1]);
            if (types.lookupFunction(self.surface, import_binding.module_path, function_name)) |function| {
                return function.*;
            }
        }

        return null;
    }

    fn resolveStruct(self: *Checker, path: tree.AccessPath) ?*const types.StructSurface {
        if (path.segments.len == 1) {
            return types.lookupStruct(self.surface, self.module.path, self.text(path.segments[0]));
        }

        if (path.segments.len == 2) {
            const import_binding = self.findImport(self.text(path.segments[0])) orelse return null;
            return types.lookupStruct(self.surface, import_binding.module_path, self.text(path.segments[1]));
        }

        return null;
    }

    fn resolveNamedTypeFromPath(self: *Checker, path: tree.AccessPath) ?types.NamedType {
        if (path.segments.len == 2) {
            const root = self.text(path.segments[0]);
            if (types.lookupEnum(self.surface, self.module.path, root) != null) {
                return .{ .module_path = self.module.path, .name = root, .kind = .enum_type };
            }
            if (types.lookupError(self.surface, self.module.path, root) != null) {
                return .{ .module_path = self.module.path, .name = root, .kind = .error_type };
            }
        }

        if (path.segments.len == 3) {
            const import_binding = self.findImport(self.text(path.segments[0])) orelse return null;
            const type_name = self.text(path.segments[1]);
            if (types.lookupEnum(self.surface, import_binding.module_path, type_name) != null) {
                return .{ .module_path = import_binding.module_path, .name = type_name, .kind = .enum_type };
            }
            if (types.lookupError(self.surface, import_binding.module_path, type_name) != null) {
                return .{ .module_path = import_binding.module_path, .name = type_name, .kind = .error_type };
            }
        }

        return null;
    }

    fn resolveTypeRef(self: *Checker, type_ref: tree.TypeRef) ?types.Type {
        return types.resolveTypeRef(self.allocator, self.sources, self.documents, self.document, type_ref) catch |err| switch (err) {
            error.OutOfMemory => return null,
            error.UnknownType => {
                self.report("T1145", "Unknown type", type_ref.span, self.text(type_ref.path.segments[type_ref.path.segments.len - 1].span)) catch {};
                return null;
            },
            error.WrongGenericArity => {
                self.report("T1146", "Wrong number of generic type arguments", type_ref.span, self.text(type_ref.path.segments[type_ref.path.segments.len - 1].span)) catch {};
                return null;
            },
        };
    }

    fn expectAssignable(self: *Checker, span: source.Span, expected: types.Type, actual: types.Type, code: []const u8, message: []const u8) CheckError!void {
        if (!expected.eql(actual)) {
            try self.report(code, message, span, null);
        }
    }

    fn matchType(self: *Checker, expected: types.Type, actual: types.Type, bindings: *std.ArrayList(TypeBinding)) CheckError!bool {
        switch (expected) {
            .type_parameter => |name| {
                for (bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, name)) {
                        return binding.ty.eql(actual);
                    }
                }
                try bindings.append(self.allocator, .{ .name = name, .ty = actual });
                return true;
            },
            .generic => |expected_generic| switch (actual) {
                .generic => |actual_generic| {
                    if (expected_generic.kind != actual_generic.kind or expected_generic.args.len != actual_generic.args.len) {
                        return false;
                    }
                    for (expected_generic.args, actual_generic.args) |expected_arg, actual_arg| {
                        if (!try self.matchType(expected_arg, actual_arg, bindings)) {
                            return false;
                        }
                    }
                    return true;
                },
                else => return false,
            },
            else => return expected.eql(actual),
        }
    }

    fn instantiateType(self: *Checker, ty: types.Type, bindings: *const std.ArrayList(TypeBinding)) CheckError!types.Type {
        return switch (ty) {
            .type_parameter => |name| blk: {
                for (bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, name)) {
                        break :blk binding.ty;
                    }
                }
                break :blk ty;
            },
            .generic => |value| blk: {
                const args = try self.allocator.alloc(types.Type, value.args.len);
                for (value.args, 0..) |arg, index| {
                    args[index] = try self.instantiateType(arg, bindings);
                }
                break :blk .{ .generic = .{ .kind = value.kind, .args = args } };
            },
            else => ty,
        };
    }

    fn lookupLocal(self: *Checker, name: []const u8) ?types.Type {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            for (self.scopes.items[index].bindings.items) |binding| {
                if (std.mem.eql(u8, binding.name, name)) {
                    return binding.ty;
                }
            }
        }
        return null;
    }

    fn declareLocal(self: *Checker, name: []const u8, ty: types.Type) CheckError!void {
        try self.scopes.items[self.scopes.items.len - 1].bindings.append(self.allocator, .{ .name = name, .ty = ty });
    }

    fn findImport(self: *Checker, alias: []const u8) ?resolution.ImportBinding {
        for (self.module.imports) |binding| {
            if (std.mem.eql(u8, binding.alias, alias)) {
                return binding;
            }
        }
        return null;
    }

    fn findArgument(self: *Checker, args: []const tree.Argument, name: []const u8) ?tree.Argument {
        for (args) |arg| {
            if (std.mem.eql(u8, name, self.text(arg.name))) {
                return arg;
            }
        }
        return null;
    }

    fn pushScope(self: *Checker) CheckError!void {
        try self.scopes.append(self.allocator, .{});
    }

    fn popScope(self: *Checker) void {
        _ = self.scopes.pop();
    }

    fn text(self: *Checker, span: source.Span) []const u8 {
        return span.slice(self.sources.getFile(self.document.file_id).source);
    }

    fn report(self: *Checker, code: []const u8, message: []const u8, span: source.Span, symbol: ?[]const u8) CheckError!void {
        try self.diagnostics.append(self.allocator, .{
            .code = code,
            .message = message,
            .span = span,
            .symbol = symbol,
        });
    }

    fn reportUnhandledRecoverable(self: *Checker, span: source.Span, ty: types.Type) CheckError!void {
        if (isRecoverableType(ty)) {
            try self.report("T1164", "Recoverable values must be handled explicitly", span, null);
        }
    }

    fn findPatternField(self: *Checker, fields: []const tree.PatternField, name: []const u8) ?tree.PatternField {
        for (fields) |field| {
            if (std.mem.eql(u8, name, self.text(field.name))) {
                return field;
            }
        }
        return null;
    }
};

const PatternCoverage = union(enum) {
    none,
    catch_all,
    label: []const u8,
};

const Coverage = struct {
    allocator: std.mem.Allocator,
    surface: types.PackageSurface,
    kind: Kind,
    owner: ?types.NamedType,
    seen: std.ArrayList([]const u8) = .empty,
    catch_all: bool = false,

    const Kind = enum {
        none,
        option,
        result,
        enum_type,
        error_type,
    };

    fn init(allocator: std.mem.Allocator, surface: types.PackageSurface, scrutinee_type: types.Type) Coverage {
        const kind, const owner = switch (scrutinee_type) {
            .generic => |value| switch (value.kind) {
                .option => .{ Kind.option, null },
                .result => .{ Kind.result, null },
                else => .{ Kind.none, null },
            },
            .named => |value| switch (value.kind) {
                .enum_type => .{ Kind.enum_type, value },
                .error_type => .{ Kind.error_type, value },
                else => .{ Kind.none, null },
            },
            else => .{ Kind.none, null },
        };

        return .{
            .allocator = allocator,
            .surface = surface,
            .kind = kind,
            .owner = owner,
        };
    }

    fn markSeen(self: *Coverage, label: []const u8) CheckError!void {
        for (self.seen.items) |existing| {
            if (std.mem.eql(u8, existing, label)) {
                return;
            }
        }
        try self.seen.append(self.allocator, label);
    }

    fn isExhaustive(self: *const Coverage) bool {
        if (self.catch_all) {
            return true;
        }

        return self.firstMissing() == null;
    }

    fn firstMissing(self: *const Coverage) ?[]const u8 {
        return switch (self.kind) {
            .none => null,
            .option => if (self.hasSeen("Some")) if (self.hasSeen("None")) null else "None" else "Some",
            .result => if (self.hasSeen("Ok")) if (self.hasSeen("Err")) null else "Err" else "Ok",
            .enum_type => blk: {
                const owner = self.owner orelse break :blk null;
                const enum_surface = types.lookupEnum(self.surface, owner.module_path, owner.name) orelse break :blk null;
                for (enum_surface.variants) |variant| {
                    if (!self.hasSeen(variant.name)) break :blk variant.name;
                }
                break :blk null;
            },
            .error_type => blk: {
                const owner = self.owner orelse break :blk null;
                const error_surface = types.lookupError(self.surface, owner.module_path, owner.name) orelse break :blk null;
                for (error_surface.variants) |variant| {
                    if (!self.hasSeen(variant.name)) break :blk variant.name;
                }
                break :blk null;
            },
        };
    }

    fn hasSeen(self: *const Coverage, label: []const u8) bool {
        for (self.seen.items) |seen| {
            if (std.mem.eql(u8, seen, label)) {
                return true;
            }
        }
        return false;
    }
};

const LocalBinding = struct {
    name: []const u8,
    ty: types.Type,
};

const LocalScope = struct {
    bindings: std.ArrayList(LocalBinding) = .empty,
};

const TypeBinding = struct {
    name: []const u8,
    ty: types.Type,
};

fn resultSuccessType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .generic => |value| if (value.kind == .result and value.args.len == 2) value.args[0] else null,
        else => null,
    };
}

fn resultErrorType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .generic => |value| if (value.kind == .result and value.args.len == 2) value.args[1] else null,
        else => null,
    };
}

fn optionInnerType(ty: types.Type) ?types.Type {
    return switch (ty) {
        .generic => |value| if (value.kind == .option and value.args.len == 1) value.args[0] else null,
        else => null,
    };
}

fn isConcreteType(ty: types.Type) bool {
    return switch (ty) {
        .type_parameter => false,
        .generic => |value| blk: {
            for (value.args) |arg| {
                if (!isConcreteType(arg)) break :blk false;
            }
            break :blk true;
        },
        else => true,
    };
}

fn isRecoverableType(ty: types.Type) bool {
    return switch (ty) {
        .generic => |value| value.kind == .option or value.kind == .result,
        else => false,
    };
}


fn findParam(params: []const types.Param, name: []const u8) ?types.Param {
    for (params) |param| {
        if (std.mem.eql(u8, param.name, name)) {
            return param;
        }
    }
    return null;
}

fn findField(fields: []const types.FieldSurface, name: []const u8) ?types.FieldSurface {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return field;
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

fn builtinPrintSignature() types.FunctionSignature {
    return .{
        .module_path = "builtin",
        .name = "print",
        .params = &.{.{ .name = "value", .ty = .{ .type_parameter = "T" } }},
        .return_type = .{ .primitive = .void },
        .visibility = .public,
    };
}

test "type checker accepts a public API example" {
    var fixture = try TestFixture.init(&.{
        .{ .path = "src/app/signup.lace", .contents =
            \\module app/signup;
            \\import std/string;
            \\
            \\pub error SignupError {
            \\    invalid_email,
            \\}
            \\
            \\pub struct SignupInput {
            \\    email: String,
            \\}
            \\
            \\pub struct User {
            \\    email: String,
            \\}
            \\
            \\pub fn signup(
            \\    input: SignupInput,
            \\) -> Result<User, SignupError> {
            \\    if !string.contains(value: input.email, needle: "@") {
            \\        return Err(SignupError.invalid_email);
            \\    }
            \\
            \\    return Ok(User{
            \\        email: input.email,
            \\    });
            \\}
        },
    });
    defer fixture.deinit();

    _ = try typecheckDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try std.testing.expectEqual(@as(usize, 0), fixture.diagnostics.count());
}

test "type checker accepts parse_port with bind and exhaustive error matching" {
    var fixture = try TestFixture.init(&.{
        .{ .path = "src/app/config.lace", .contents =
            \\module app/config;
            \\import std/int;
            \\
            \\pub error ParsePortError {
            \\    empty_input,
            \\    invalid_integer(input: String),
            \\    out_of_range(min: Int, max: Int),
            \\}
            \\
            \\pub error ConfigError {
            \\    missing_port,
            \\    invalid_port(input: String),
            \\    port_out_of_range(min: Int, max: Int),
            \\}
            \\
            \\pub fn parse_port(
            \\    value: String,
            \\) -> Result<Int, ParsePortError> {
            \\    if value == "" {
            \\        return Err(ParsePortError.empty_input);
            \\    }
            \\
            \\    if !int.is_valid(value: value) {
            \\        return Err(ParsePortError.invalid_integer(input: value));
            \\    }
            \\
            \\    let port = int.parse(value: value);
            \\
            \\    if port < 1 {
            \\        return Err(ParsePortError.out_of_range(min: 1, max: 65535));
            \\    }
            \\
            \\    if port > 65535 {
            \\        return Err(ParsePortError.out_of_range(min: 1, max: 65535));
            \\    }
            \\
            \\    return Ok(port);
            \\}
            \\
            \\pub fn load_port(
            \\    input: String,
            \\) -> Result<Int, ConfigError> {
            \\    bind port: Int = parse_port(value: input) else err => match err {
            \\        ParsePortError.empty_input => return Err(ConfigError.missing_port);
            \\        ParsePortError.invalid_integer(input: bad_input) => return Err(ConfigError.invalid_port(input: bad_input));
            \\        ParsePortError.out_of_range(min: min, max: max) => return Err(ConfigError.port_out_of_range(min: min, max: max));
            \\    };
            \\
            \\    return Ok(port);
            \\}
        },
    });
    defer fixture.deinit();

    _ = try typecheckDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try std.testing.expectEqual(@as(usize, 0), fixture.diagnostics.count());
}

test "type checker rejects wrong return types" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\fn main() -> String {
            \\    return 42;
            \\}
        },
    }, &.{"T1106"});
}

test "type checker rejects missing named arguments" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\import std/int;
            \\
            \\fn main() -> Int {
            \\    return int.parse();
            \\}
        },
    }, &.{"T1114"});
}

test "type checker rejects bad struct field types" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\pub struct User {
            \\    age: Int,
            \\}
            \\
            \\fn main() -> User {
            \\    return User{
            \\        age: "old",
            \\    };
            \\}
        },
    }, &.{"T1120"});
}

test "type checker rejects non-bool conditions" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\fn main() -> Int {
            \\    if 1 {
            \\        return 1;
            \\    }
            \\
            \\    return 2;
            \\}
        },
    }, &.{"T1105"});
}

test "type checker rejects non-exhaustive result matches" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\pub error DemoError {
            \\    bad_input,
            \\}
            \\
            \\fn main(
            \\    value: Result<Int, DemoError>,
            \\) -> Int {
            \\    return match value {
            \\        Ok(port) => port;
            \\    };
            \\}
        },
    }, &.{"T1147"});
}

test "type checker rejects invalid bind targets" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\fn main() -> Int {
            \\    bind value = 1 else err => {
            \\        return 0;
            \\    };
            \\
            \\    return value;
            \\}
        },
    }, &.{"T1115"});
}

test "type checker rejects invalid option patterns" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\fn main(
            \\    value: Option<Int>,
            \\) -> Int {
            \\    return match value {
            \\        Some => 1;
            \\        other => 0;
            \\    };
            \\}
        },
    }, &.{"T1151"});
}

test "type checker rejects unhandled recoverable expression statements" {
    try expectTypecheckCodes(&.{
        .{ .path = "src/app/demo.lace", .contents =
            \\module app/demo;
            \\
            \\pub error DemoError {
            \\    bad_input,
            \\}
            \\
            \\fn parse_port() -> Result<Int, DemoError> {
            \\    return Ok(42);
            \\}
            \\
            \\fn main() -> Void {
            \\    parse_port();
            \\    return Void;
            \\}
        },
    }, &.{"T1164"});
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
        try std.testing.expectEqual(@as(usize, 0), self.diagnostics.count());
        return documents;
    }
};

fn expectTypecheckCodes(fixtures: []const Fixture, expected_codes: []const []const u8) !void {
    var fixture = try TestFixture.init(fixtures);
    defer fixture.deinit();

    _ = try typecheckDocuments(fixture.arena.allocator(), &fixture.diagnostics, &fixture.sources, fixture.documents);
    try std.testing.expectEqual(expected_codes.len, fixture.diagnostics.count());
    for (expected_codes, fixture.diagnostics.items.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual.code);
    }
}
