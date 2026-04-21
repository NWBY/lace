const std = @import("std");

const source = @import("../source.zig");
const token = @import("token.zig");
const tree = @import("tree.zig");

const FormatError = std.Io.Writer.Error;

pub fn formatDocument(
    writer: *std.Io.Writer,
    sources: *const source.Manager,
    document: tree.Document,
) FormatError!void {
    var formatter = Formatter{
        .writer = writer,
        .file = sources.getFile(document.file_id),
    };
    try formatter.writeDocument(document);
}

pub fn formatDocumentAlloc(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    document: tree.Document,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    try formatDocument(&output.writer, sources, document);
    return try output.toOwnedSlice();
}

const Formatter = struct {
    writer: *std.Io.Writer,
    file: *const source.File,
    indent_level: usize = 0,

    fn writeDocument(self: *Formatter, document: tree.Document) FormatError!void {
        try self.writer.writeAll("module ");
        try self.writePath(document.module_decl.path);
        try self.writer.writeAll(";");

        if (document.imports.len > 0) {
            try self.writer.writeAll("\n\n");
            for (document.imports, 0..) |import_decl, index| {
                if (index > 0) {
                    try self.writer.writeByte('\n');
                }
                try self.writer.writeAll("import ");
                try self.writePath(import_decl.path);
                try self.writer.writeAll(";");
            }
        }

        if (document.items.len > 0) {
            try self.writer.writeAll("\n\n");
            for (document.items, 0..) |item, index| {
                if (index > 0) {
                    try self.writer.writeAll("\n\n");
                }
                try self.writeItem(item);
            }
        }

        try self.writer.writeByte('\n');
    }

    fn writeItem(self: *Formatter, item: tree.Item) FormatError!void {
        switch (item) {
            .struct_decl => |value| try self.writeStructDecl(value),
            .enum_decl => |value| try self.writeEnumDecl(value),
            .error_decl => |value| try self.writeErrorDecl(value),
            .function_decl => |value| try self.writeFunctionDecl(value),
            .const_decl => |value| try self.writeTopLevelConstDecl(value),
            .test_decl => |value| try self.writeTestDecl(value),
        }
    }

    fn writeStructDecl(self: *Formatter, decl: tree.StructDecl) FormatError!void {
        try self.writeVisibility(decl.visibility);
        try self.writer.writeAll("struct ");
        try self.writer.writeAll(self.text(decl.name));
        try self.writer.writeAll(" {");
        try self.writeDeclFieldBody(decl.fields);
    }

    fn writeEnumDecl(self: *Formatter, decl: tree.EnumDecl) FormatError!void {
        try self.writeVisibility(decl.visibility);
        try self.writer.writeAll("enum ");
        try self.writer.writeAll(self.text(decl.name));
        try self.writer.writeAll(" {");
        try self.writeVariantBody(decl.variants);
    }

    fn writeErrorDecl(self: *Formatter, decl: tree.ErrorDecl) FormatError!void {
        try self.writeVisibility(decl.visibility);
        try self.writer.writeAll("error ");
        try self.writer.writeAll(self.text(decl.name));
        try self.writer.writeAll(" {");
        try self.writeVariantBody(decl.variants);
    }

    fn writeFunctionDecl(self: *Formatter, decl: tree.FunctionDecl) FormatError!void {
        try self.writeVisibility(decl.visibility);
        try self.writer.writeAll("fn ");
        try self.writer.writeAll(self.text(decl.name));
        try self.writeFunctionSignature(decl.params, decl.return_type);
        try self.writer.writeByte(' ');
        try self.writeBlock(decl.body);
    }

    fn writeTopLevelConstDecl(self: *Formatter, decl: tree.ConstDecl) FormatError!void {
        try self.writeVisibility(decl.visibility);
        try self.writer.writeAll("const ");
        try self.writer.writeAll(self.text(decl.name));
        try self.writer.writeAll(": ");
        try self.writeTypeRef(decl.type_ref);
        try self.writer.writeAll(" = ");
        try self.writeExpr(decl.initializer, 0, .none);
        try self.writer.writeAll(";");
    }

    fn writeTestDecl(self: *Formatter, decl: tree.TestDecl) FormatError!void {
        try self.writer.writeAll("test ");
        try self.writer.writeAll(self.text(decl.name));
        try self.writer.writeByte(' ');
        try self.writeBlock(decl.body);
    }

    fn writeDeclFieldBody(self: *Formatter, fields: []const tree.Field) FormatError!void {
        self.indent_level += 1;
        try self.writer.writeByte('\n');
        for (fields) |field| {
            try self.writeIndent();
            try self.writer.writeAll(self.text(field.name));
            try self.writer.writeAll(": ");
            try self.writeTypeRef(field.type_ref);
            try self.writer.writeAll(",\n");
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}");
    }

    fn writeVariantBody(self: *Formatter, variants: []const tree.Variant) FormatError!void {
        self.indent_level += 1;
        try self.writer.writeByte('\n');
        for (variants) |variant| {
            try self.writeIndent();
            try self.writer.writeAll(self.text(variant.name));
            if (variant.fields.len > 0) {
                try self.writer.writeByte('(');
                for (variant.fields, 0..) |field, index| {
                    if (index > 0) {
                        try self.writer.writeAll(", ");
                    }
                    try self.writer.writeAll(self.text(field.name));
                    try self.writer.writeAll(": ");
                    try self.writeTypeRef(field.type_ref);
                }
                try self.writer.writeByte(')');
            }
            try self.writer.writeAll(",\n");
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.writer.writeAll("}");
    }

    fn writeFunctionSignature(self: *Formatter, params: []const tree.Field, return_type: tree.TypeRef) FormatError!void {
        if (params.len == 0) {
            try self.writer.writeAll("()");
        } else {
            try self.writer.writeAll("(\n");
            self.indent_level += 1;
            for (params) |param| {
                try self.writeIndent();
                try self.writer.writeAll(self.text(param.name));
                try self.writer.writeAll(": ");
                try self.writeTypeRef(param.type_ref);
                try self.writer.writeAll(",\n");
            }
            self.indent_level -= 1;
            try self.writeIndent();
            try self.writer.writeByte(')');
        }

        try self.writer.writeAll(" -> ");
        try self.writeTypeRef(return_type);
    }

    fn writeTypeRef(self: *Formatter, type_ref: tree.TypeRef) FormatError!void {
        try self.writePath(type_ref.path);
        if (type_ref.arguments.len > 0) {
            try self.writer.writeByte('<');
            for (type_ref.arguments, 0..) |argument, index| {
                if (index > 0) {
                    try self.writer.writeAll(", ");
                }
                try self.writeTypeRef(argument);
            }
            try self.writer.writeByte('>');
        }
    }

    fn writePath(self: *Formatter, path: tree.Path) FormatError!void {
        for (path.segments, 0..) |segment, index| {
            if (index > 0) {
                try self.writer.writeByte('/');
            }
            try self.writer.writeAll(self.text(segment.span));
        }
    }

    fn writeAccessPath(self: *Formatter, path: tree.AccessPath) FormatError!void {
        for (path.segments, 0..) |segment, index| {
            if (index > 0) {
                try self.writer.writeByte('.');
            }
            try self.writer.writeAll(self.text(segment));
        }
    }

    fn writeBlock(self: *Formatter, block: tree.Block) FormatError!void {
        try self.writer.writeAll("{");
        self.indent_level += 1;
        try self.writer.writeByte('\n');
        for (block.statements, 0..) |statement, index| {
            if (index > 0) {
                try self.writer.writeByte('\n');
            }
            try self.writeIndent();
            try self.writeStatement(statement);
        }
        self.indent_level -= 1;
        try self.writer.writeByte('\n');
        try self.writeIndent();
        try self.writer.writeAll("}");
    }

    fn writeStatement(self: *Formatter, statement: tree.Statement) FormatError!void {
        switch (statement) {
            .let_stmt => |value| try self.writeLetStmt(value),
            .const_stmt => |value| try self.writeConstStmt(value),
            .bind_stmt => |value| try self.writeBindStmt(value),
            .if_stmt => |value| try self.writeIfStmt(value),
            .match_stmt => |value| try self.writeMatchExpr(value, 0, .none),
            .return_stmt => |value| try self.writeReturnStmt(value),
            .expr_stmt => |value| try self.writeExprStmt(value),
        }
    }

    fn writeLetStmt(self: *Formatter, stmt: tree.LetStmt) FormatError!void {
        try self.writer.writeAll("let ");
        try self.writer.writeAll(self.text(stmt.name));
        if (stmt.type_ref) |type_ref| {
            try self.writer.writeAll(": ");
            try self.writeTypeRef(type_ref);
        }
        try self.writer.writeAll(" = ");
        try self.writeExpr(stmt.value, 0, .none);
        try self.writer.writeAll(";");
    }

    fn writeConstStmt(self: *Formatter, stmt: tree.ConstStmt) FormatError!void {
        try self.writer.writeAll("const ");
        try self.writer.writeAll(self.text(stmt.name));
        if (stmt.type_ref) |type_ref| {
            try self.writer.writeAll(": ");
            try self.writeTypeRef(type_ref);
        }
        try self.writer.writeAll(" = ");
        try self.writeExpr(stmt.value, 0, .none);
        try self.writer.writeAll(";");
    }

    fn writeBindStmt(self: *Formatter, stmt: tree.BindStmt) FormatError!void {
        try self.writer.writeAll("bind ");
        try self.writer.writeAll(self.text(stmt.name));
        if (stmt.type_ref) |type_ref| {
            try self.writer.writeAll(": ");
            try self.writeTypeRef(type_ref);
        }
        try self.writer.writeAll(" = ");
        try self.writeExpr(stmt.value, 0, .none);
        try self.writer.writeAll(" else ");
        try self.writer.writeAll(self.text(stmt.else_name));
        try self.writer.writeAll(" => ");
        switch (stmt.else_body) {
            .block => |value| try self.writeBlock(value),
            .expr => |value| try self.writeExpr(value, 0, .none),
        }
        try self.writer.writeAll(";");
    }

    fn writeIfStmt(self: *Formatter, stmt: tree.IfStmt) FormatError!void {
        try self.writer.writeAll("if ");
        try self.writeExpr(stmt.condition, 0, .none);
        try self.writer.writeByte(' ');
        try self.writeBlock(stmt.then_block);
        if (stmt.else_block) |else_block| {
            try self.writer.writeAll(" else ");
            try self.writeBlock(else_block);
        }
    }

    fn writeReturnStmt(self: *Formatter, stmt: tree.ReturnStmt) FormatError!void {
        try self.writer.writeAll("return ");
        try self.writeExpr(stmt.value, 0, .none);
        try self.writer.writeAll(";");
    }

    fn writeExprStmt(self: *Formatter, stmt: tree.ExprStmt) FormatError!void {
        try self.writeExpr(stmt.value, 0, .none);
        try self.writer.writeAll(";");
    }

    fn writeMatchExpr(self: *Formatter, expr: tree.MatchExpr, parent_prec: u8, side: Side) FormatError!void {
        const need_parens = self.needsParens(match_prec, parent_prec, side);
        if (need_parens) {
            try self.writer.writeByte('(');
        }

        try self.writer.writeAll("match ");
        try self.writeExpr(expr.value, match_prec, .none);
        try self.writer.writeAll(" {");
        self.indent_level += 1;
        try self.writer.writeByte('\n');
        for (expr.arms, 0..) |arm, index| {
            if (index > 0) {
                try self.writer.writeByte('\n');
            }
            try self.writeIndent();
            try self.writePattern(arm.pattern);
            try self.writer.writeAll(" => ");
            try self.writeArmBody(arm.body);
        }
        self.indent_level -= 1;
        try self.writer.writeByte('\n');
        try self.writeIndent();
        try self.writer.writeByte('}');

        if (need_parens) {
            try self.writer.writeByte(')');
        }
    }

    fn writeArmBody(self: *Formatter, body: tree.ArmBody) FormatError!void {
        switch (body) {
            .block => |value| try self.writeBlock(value),
            .return_stmt => |value| try self.writeReturnStmt(value),
            .expr => |value| {
                try self.writeExpr(value, 0, .none);
                try self.writer.writeAll(";");
            },
        }
    }

    fn writePattern(self: *Formatter, pattern: tree.Pattern) FormatError!void {
        switch (pattern) {
            .binding => |value| try self.writer.writeAll(self.text(value.span)),
            .path => |value| {
                try self.writeAccessPath(value.path);
                if (value.payload) |payload| {
                    switch (payload) {
                        .positional => |inner| {
                            try self.writer.writeByte('(');
                            try self.writePattern(inner.*);
                            try self.writer.writeByte(')');
                        },
                        .named => |fields| {
                            try self.writer.writeByte('(');
                            for (fields, 0..) |field, index| {
                                if (index > 0) {
                                    try self.writer.writeAll(", ");
                                }
                                try self.writer.writeAll(self.text(field.name));
                                try self.writer.writeAll(": ");
                                try self.writePattern(field.value.*);
                            }
                            try self.writer.writeByte(')');
                        },
                    }
                }
            },
        }
    }

    fn writeExpr(self: *Formatter, expr: *tree.Expr, parent_prec: u8, side: Side) FormatError!void {
        switch (expr.*) {
            .access_path => |value| {
                const need_parens = self.needsParens(postfix_prec, parent_prec, side);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeAccessPath(value);
                if (need_parens) try self.writer.writeByte(')');
            },
            .bool_literal => |value| try self.writeSpanAtom(value, postfix_prec, parent_prec, side),
            .int_literal => |value| try self.writeSpanAtom(value, postfix_prec, parent_prec, side),
            .string_literal => |value| try self.writeSpanAtom(value, postfix_prec, parent_prec, side),
            .unary => |value| {
                const need_parens = self.needsParens(unary_prec, parent_prec, side);
                if (need_parens) try self.writer.writeByte('(');
                try self.writer.writeAll(operatorText(value.operator));
                try self.writeExpr(value.value, unary_prec, .none);
                if (need_parens) try self.writer.writeByte(')');
            },
            .binary => |value| {
                const prec = binaryPrecedence(value.operator);
                const need_parens = self.needsParens(prec, parent_prec, side);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeExpr(value.left, prec, .left);
                try self.writer.writeByte(' ');
                try self.writer.writeAll(operatorText(value.operator));
                try self.writer.writeByte(' ');
                try self.writeExpr(value.right, prec, .right);
                if (need_parens) try self.writer.writeByte(')');
            },
            .call => |value| {
                const need_parens = self.needsParens(postfix_prec, parent_prec, side);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeExpr(value.callee, postfix_prec, .none);
                try self.writer.writeByte('(');
                for (value.args, 0..) |arg, index| {
                    if (index > 0) {
                        try self.writer.writeAll(", ");
                    }
                    try self.writer.writeAll(self.text(arg.name));
                    try self.writer.writeAll(": ");
                    try self.writeExpr(arg.value, 0, .none);
                }
                try self.writer.writeByte(')');
                if (need_parens) try self.writer.writeByte(')');
            },
            .struct_init => |value| {
                const need_parens = self.needsParens(postfix_prec, parent_prec, side);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeAccessPath(value.type_path);
                try self.writer.writeAll("{");
                self.indent_level += 1;
                try self.writer.writeByte('\n');
                for (value.fields) |field| {
                    try self.writeIndent();
                    try self.writer.writeAll(self.text(field.name));
                    try self.writer.writeAll(": ");
                    try self.writeExpr(field.value, 0, .none);
                    try self.writer.writeAll(",\n");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writer.writeByte('}');
                if (need_parens) try self.writer.writeByte(')');
            },
            .variant => |value| {
                const need_parens = self.needsParens(postfix_prec, parent_prec, side);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeAccessPath(value.path);
                try self.writer.writeByte('(');
                switch (value.payload) {
                    .positional => |inner| try self.writeExpr(inner, 0, .none),
                    .named => |fields| {
                        for (fields, 0..) |field, index| {
                            if (index > 0) {
                                try self.writer.writeAll(", ");
                            }
                            try self.writer.writeAll(self.text(field.name));
                            try self.writer.writeAll(": ");
                            try self.writeExpr(field.value, 0, .none);
                        }
                    },
                }
                try self.writer.writeByte(')');
                if (need_parens) try self.writer.writeByte(')');
            },
            .match_expr => |value| try self.writeMatchExpr(value, parent_prec, side),
        }
    }

    fn writeSpanAtom(self: *Formatter, span: source.Span, expr_prec: u8, parent_prec: u8, side: Side) FormatError!void {
        const need_parens = self.needsParens(expr_prec, parent_prec, side);
        if (need_parens) try self.writer.writeByte('(');
        try self.writer.writeAll(self.text(span));
        if (need_parens) try self.writer.writeByte(')');
    }

    fn writeVisibility(self: *Formatter, visibility: tree.Visibility) FormatError!void {
        switch (visibility) {
            .private => {},
            .public => try self.writer.writeAll("pub "),
        }
    }

    fn writeIndent(self: *Formatter) FormatError!void {
        for (0..self.indent_level * 4) |_| {
            try self.writer.writeByte(' ');
        }
    }

    fn text(self: *Formatter, span: source.Span) []const u8 {
        return span.slice(self.file.source);
    }

    fn needsParens(self: *Formatter, expr_prec: u8, parent_prec: u8, side: Side) bool {
        _ = self;
        if (expr_prec < parent_prec) {
            return true;
        }

        return side == .right and expr_prec == parent_prec and parent_prec != 0;
    }
};

const Side = enum {
    none,
    left,
    right,
};

const match_prec: u8 = 1;
const comparison_prec: u8 = 2;
const additive_prec: u8 = 3;
const multiplicative_prec: u8 = 4;
const unary_prec: u8 = 5;
const postfix_prec: u8 = 6;

fn binaryPrecedence(tag: token.Tag) u8 {
    return switch (tag) {
        .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => comparison_prec,
        .plus, .minus => additive_prec,
        .star => multiplicative_prec,
        else => postfix_prec,
    };
}

fn operatorText(tag: token.Tag) []const u8 {
    return switch (tag) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .bang => "!",
        .eq_eq => "==",
        .bang_eq => "!=",
        .lt => "<",
        .lt_eq => "<=",
        .gt => ">",
        .gt_eq => ">=",
        else => "<unknown>",
    };
}

test "formatter canonicalizes declarations and bodies" {
    const input =
        \\module demo;
        \\import std/string;
        \\pub fn greet(name:String)->Result<String,AppError>{if name==""{return Err(AppError.invalid_name);}else{return Ok("hello "+name);}}
    ;
    const expected = (
        \\module demo;
        \\
        \\import std/string;
        \\
        \\pub fn greet(
        \\    name: String,
        \\) -> Result<String, AppError> {
        \\    if name == "" {
        \\        return Err(AppError.invalid_name);
        \\    } else {
        \\        return Ok("hello " + name);
        \\    }
        \\}
    ) ++ "\n";
    try expectFormat(input, expected);
}

test "formatter canonicalizes match bind and struct init" {
    const input =
        \\module demo;
        \\fn main()->Result<Void,AppError>{let user:User=User{name:"Sam",};bind checked=parse_port(value:"3000") else err => match err {AppError.invalid_name=>return Err(err);};return Ok(Void);}
    ;
    const expected = (
        \\module demo;
        \\
        \\fn main() -> Result<Void, AppError> {
        \\    let user: User = User{
        \\        name: "Sam",
        \\    };
        \\    bind checked = parse_port(value: "3000") else err => match err {
        \\        AppError.invalid_name => return Err(err);
        \\    };
        \\    return Ok(Void);
        \\}
    ) ++ "\n";
    try expectFormat(input, expected);
}

test "formatter is idempotent and reparses" {
    const input =
        \\module demo;
        \\fn main()->Int{return (1+2)*3;}
    ;

    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var diagnostics: @import("../diag/mod.zig").Store = .{};
    const file_id = try sources.addSource(std.testing.allocator, "src/demo.lace", input);

    var arena_one = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_one.deinit();
    const document_one = try @import("parser.zig").parseFile(arena_one.allocator(), &diagnostics, sources.getFile(file_id));
    const first = try formatDocumentAlloc(std.testing.allocator, &sources, document_one);
    defer std.testing.allocator.free(first);

    const second_id = try sources.addSource(std.testing.allocator, "src/demo_formatted.lace", first);
    var arena_two = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_two.deinit();
    const document_two = try @import("parser.zig").parseFile(arena_two.allocator(), &diagnostics, sources.getFile(second_id));
    const second = try formatDocumentAlloc(std.testing.allocator, &sources, document_two);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

fn expectFormat(input: []const u8, expected: []const u8) !void {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(std.testing.allocator, "src/test.lace", input);

    var diagnostics: @import("../diag/mod.zig").Store = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const document = try @import("parser.zig").parseFile(arena.allocator(), &diagnostics, sources.getFile(file_id));
    const formatted = try formatDocumentAlloc(std.testing.allocator, &sources, document);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());
    try std.testing.expectEqualStrings(expected, formatted);
}
