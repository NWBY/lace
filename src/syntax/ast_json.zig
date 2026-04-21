const std = @import("std");

const ids = @import("../id.zig");
const source = @import("../source.zig");
const token = @import("token.zig");
const tree = @import("tree.zig");

const JsonError = std.Io.Writer.Error;

pub fn renderJson(
    writer: *std.Io.Writer,
    sources: *const source.Manager,
    document: tree.Document,
) JsonError!void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{},
    };

    var renderer = Renderer{
        .sources = sources,
        .json = &stringify,
    };
    try renderer.writeDocument(document);
}

const Renderer = struct {
    sources: *const source.Manager,
    json: *std.json.Stringify,
    generator: ids.Generator = .{},

    fn writeDocument(self: *Renderer, document: tree.Document) JsonError!void {
        const file = self.sources.getFile(document.file_id);
        try self.beginNode("Module", source.Span.init(document.file_id, 0, file.source.len));
        try self.json.objectField("path");
        try self.writePath(document.module_decl.path);
        try self.json.objectField("imports");
        try self.json.beginArray();
        for (document.imports) |import_decl| {
            try self.writeImport(import_decl);
        }
        try self.json.endArray();
        try self.json.objectField("items");
        try self.json.beginArray();
        for (document.items) |item| {
            try self.writeItem(item);
        }
        try self.json.endArray();
        try self.endNode();
    }

    fn writeImport(self: *Renderer, import_decl: tree.ImportDecl) JsonError!void {
        try self.beginNode("Import", import_decl.span);
        try self.json.objectField("path");
        try self.writePath(import_decl.path);
        try self.endNode();
    }

    fn writeItem(self: *Renderer, item: tree.Item) JsonError!void {
        switch (item) {
            .struct_decl => |value| try self.writeStructDecl(value),
            .enum_decl => |value| try self.writeEnumDecl(value),
            .error_decl => |value| try self.writeErrorDecl(value),
            .function_decl => |value| try self.writeFunctionDecl(value),
            .const_decl => |value| try self.writeConstDecl(value),
            .test_decl => |value| try self.writeTestDecl(value),
        }
    }

    fn writeStructDecl(self: *Renderer, decl: tree.StructDecl) JsonError!void {
        try self.beginNode("StructDecl", decl.span);
        try self.writeNameField(decl.name);
        try self.writeVisibilityField(decl.visibility);
        try self.json.objectField("fields");
        try self.writeFieldArray(decl.fields);
        try self.endNode();
    }

    fn writeEnumDecl(self: *Renderer, decl: tree.EnumDecl) JsonError!void {
        try self.beginNode("EnumDecl", decl.span);
        try self.writeNameField(decl.name);
        try self.writeVisibilityField(decl.visibility);
        try self.json.objectField("variants");
        try self.writeVariantArray(decl.variants);
        try self.endNode();
    }

    fn writeErrorDecl(self: *Renderer, decl: tree.ErrorDecl) JsonError!void {
        try self.beginNode("ErrorDecl", decl.span);
        try self.writeNameField(decl.name);
        try self.writeVisibilityField(decl.visibility);
        try self.json.objectField("variants");
        try self.writeVariantArray(decl.variants);
        try self.endNode();
    }

    fn writeFunctionDecl(self: *Renderer, decl: tree.FunctionDecl) JsonError!void {
        try self.beginNode("FunctionDecl", decl.span);
        try self.writeNameField(decl.name);
        try self.writeVisibilityField(decl.visibility);
        try self.json.objectField("params");
        try self.writeFieldArray(decl.params);
        try self.json.objectField("return_type");
        try self.writeTypeRef(decl.return_type);
        try self.json.objectField("body");
        try self.writeBlock(decl.body);
        try self.endNode();
    }

    fn writeConstDecl(self: *Renderer, decl: tree.ConstDecl) JsonError!void {
        try self.beginNode("ConstDecl", decl.span);
        try self.writeNameField(decl.name);
        try self.writeVisibilityField(decl.visibility);
        try self.json.objectField("type");
        try self.writeTypeRef(decl.type_ref);
        try self.json.objectField("initializer");
        try self.writeExpr(decl.initializer);
        try self.endNode();
    }

    fn writeTestDecl(self: *Renderer, decl: tree.TestDecl) JsonError!void {
        try self.beginNode("TestDecl", decl.span);
        try self.json.objectField("name");
        try self.json.write(self.text(decl.name));
        try self.json.objectField("body");
        try self.writeBlock(decl.body);
        try self.endNode();
    }

    fn writeFieldArray(self: *Renderer, fields: []const tree.Field) JsonError!void {
        try self.json.beginArray();
        for (fields) |field| {
            try self.writeField(field);
        }
        try self.json.endArray();
    }

    fn writeField(self: *Renderer, field: tree.Field) JsonError!void {
        try self.beginNode("Field", field.span);
        try self.writeNameField(field.name);
        try self.json.objectField("type");
        try self.writeTypeRef(field.type_ref);
        try self.endNode();
    }

    fn writeVariantArray(self: *Renderer, variants: []const tree.Variant) JsonError!void {
        try self.json.beginArray();
        for (variants) |variant| {
            try self.writeVariant(variant);
        }
        try self.json.endArray();
    }

    fn writeVariant(self: *Renderer, variant: tree.Variant) JsonError!void {
        try self.beginNode("Variant", variant.span);
        try self.writeNameField(variant.name);
        try self.json.objectField("fields");
        try self.writeFieldArray(variant.fields);
        try self.endNode();
    }

    fn writeTypeRef(self: *Renderer, type_ref: tree.TypeRef) JsonError!void {
        try self.beginNode("TypeRef", type_ref.span);
        try self.json.objectField("path");
        try self.writePath(type_ref.path);
        try self.json.objectField("arguments");
        try self.json.beginArray();
        for (type_ref.arguments) |argument| {
            try self.writeTypeRef(argument);
        }
        try self.json.endArray();
        try self.endNode();
    }

    fn writePath(self: *Renderer, path: tree.Path) JsonError!void {
        try self.beginNode("Path", path.span);
        try self.json.objectField("segments");
        try self.json.beginArray();
        for (path.segments) |segment| {
            try self.json.write(self.text(segment.span));
        }
        try self.json.endArray();
        try self.endNode();
    }

    fn writeAccessPath(self: *Renderer, path: tree.AccessPath) JsonError!void {
        try self.beginNode("AccessPath", path.span);
        try self.json.objectField("segments");
        try self.json.beginArray();
        for (path.segments) |segment| {
            try self.json.write(self.text(segment));
        }
        try self.json.endArray();
        try self.endNode();
    }

    fn writeBlock(self: *Renderer, block: tree.Block) JsonError!void {
        try self.beginNode("Block", block.span);
        try self.json.objectField("statements");
        try self.json.beginArray();
        for (block.statements) |statement| {
            try self.writeStatement(statement);
        }
        try self.json.endArray();
        try self.endNode();
    }

    fn writeStatement(self: *Renderer, statement: tree.Statement) JsonError!void {
        switch (statement) {
            .let_stmt => |value| try self.writeLetStmt(value),
            .const_stmt => |value| try self.writeConstStmt(value),
            .bind_stmt => |value| try self.writeBindStmt(value),
            .if_stmt => |value| try self.writeIfStmt(value),
            .match_stmt => |value| try self.writeMatchExpr(value),
            .return_stmt => |value| try self.writeReturnStmt(value),
            .expr_stmt => |value| try self.writeExprStmt(value),
        }
    }

    fn writeLetStmt(self: *Renderer, stmt: tree.LetStmt) JsonError!void {
        try self.beginNode("LetStmt", stmt.span);
        try self.writeNameField(stmt.name);
        try self.json.objectField("type");
        if (stmt.type_ref) |type_ref| {
            try self.writeTypeRef(type_ref);
        } else {
            try self.json.write(@as(?[]const u8, null));
        }
        try self.json.objectField("value");
        try self.writeExpr(stmt.value);
        try self.endNode();
    }

    fn writeConstStmt(self: *Renderer, stmt: tree.ConstStmt) JsonError!void {
        try self.beginNode("ConstStmt", stmt.span);
        try self.writeNameField(stmt.name);
        try self.json.objectField("type");
        if (stmt.type_ref) |type_ref| {
            try self.writeTypeRef(type_ref);
        } else {
            try self.json.write(@as(?[]const u8, null));
        }
        try self.json.objectField("value");
        try self.writeExpr(stmt.value);
        try self.endNode();
    }

    fn writeBindStmt(self: *Renderer, stmt: tree.BindStmt) JsonError!void {
        try self.beginNode("BindStmt", stmt.span);
        try self.writeNameField(stmt.name);
        try self.json.objectField("type");
        if (stmt.type_ref) |type_ref| {
            try self.writeTypeRef(type_ref);
        } else {
            try self.json.write(@as(?[]const u8, null));
        }
        try self.json.objectField("value");
        try self.writeExpr(stmt.value);
        try self.json.objectField("else_name");
        try self.json.write(self.text(stmt.else_name));
        try self.json.objectField("else_body");
        switch (stmt.else_body) {
            .block => |value| try self.writeBlock(value),
            .expr => |value| try self.writeExpr(value),
        }
        try self.endNode();
    }

    fn writeIfStmt(self: *Renderer, stmt: tree.IfStmt) JsonError!void {
        try self.beginNode("IfStmt", stmt.span);
        try self.json.objectField("condition");
        try self.writeExpr(stmt.condition);
        try self.json.objectField("then_block");
        try self.writeBlock(stmt.then_block);
        try self.json.objectField("else_block");
        if (stmt.else_block) |value| {
            try self.writeBlock(value);
        } else {
            try self.json.write(@as(?[]const u8, null));
        }
        try self.endNode();
    }

    fn writeReturnStmt(self: *Renderer, stmt: tree.ReturnStmt) JsonError!void {
        try self.beginNode("ReturnStmt", stmt.span);
        try self.json.objectField("value");
        try self.writeExpr(stmt.value);
        try self.endNode();
    }

    fn writeExprStmt(self: *Renderer, stmt: tree.ExprStmt) JsonError!void {
        try self.beginNode("ExprStmt", stmt.span);
        try self.json.objectField("value");
        try self.writeExpr(stmt.value);
        try self.endNode();
    }

    fn writeMatchExpr(self: *Renderer, expr: tree.MatchExpr) JsonError!void {
        try self.beginNode("MatchExpr", expr.span);
        try self.json.objectField("value");
        try self.writeExpr(expr.value);
        try self.json.objectField("arms");
        try self.json.beginArray();
        for (expr.arms) |arm| {
            try self.writeMatchArm(arm);
        }
        try self.json.endArray();
        try self.endNode();
    }

    fn writeMatchArm(self: *Renderer, arm: tree.MatchArm) JsonError!void {
        try self.beginNode("MatchArm", arm.span);
        try self.json.objectField("pattern");
        try self.writePattern(arm.pattern);
        try self.json.objectField("body");
        switch (arm.body) {
            .block => |value| try self.writeBlock(value),
            .return_stmt => |value| try self.writeReturnStmt(value),
            .expr => |value| try self.writeExpr(value),
        }
        try self.endNode();
    }

    fn writePattern(self: *Renderer, pattern: tree.Pattern) JsonError!void {
        switch (pattern) {
            .binding => |value| {
                try self.beginNode("BindingPattern", value.span);
                try self.json.objectField("name");
                try self.json.write(self.text(value.span));
                try self.endNode();
            },
            .path => |value| {
                try self.beginNode("PathPattern", value.span);
                try self.json.objectField("path");
                try self.writeAccessPath(value.path);
                try self.json.objectField("payload");
                if (value.payload) |payload| {
                    switch (payload) {
                        .positional => |inner| try self.writePattern(inner.*),
                        .named => |fields| {
                            try self.json.beginArray();
                            for (fields) |field| {
                                try self.writePatternField(field);
                            }
                            try self.json.endArray();
                        },
                    }
                } else {
                    try self.json.write(@as(?[]const u8, null));
                }
                try self.endNode();
            },
        }
    }

    fn writePatternField(self: *Renderer, field: tree.PatternField) JsonError!void {
        try self.beginNode("PatternField", field.span);
        try self.writeNameField(field.name);
        try self.json.objectField("value");
        try self.writePattern(field.value.*);
        try self.endNode();
    }

    fn writeExpr(self: *Renderer, expr: *tree.Expr) JsonError!void {
        switch (expr.*) {
            .access_path => |value| try self.writeAccessPath(value),
            .bool_literal => |value| {
                try self.beginNode("BoolLiteral", value);
                try self.json.objectField("text");
                try self.json.write(self.text(value));
                try self.endNode();
            },
            .int_literal => |value| {
                try self.beginNode("IntLiteral", value);
                try self.json.objectField("text");
                try self.json.write(self.text(value));
                try self.endNode();
            },
            .string_literal => |value| {
                try self.beginNode("StringLiteral", value);
                try self.json.objectField("text");
                try self.json.write(self.text(value));
                try self.endNode();
            },
            .unary => |value| {
                try self.beginNode("UnaryExpr", value.span);
                try self.json.objectField("operator");
                try self.json.write(operatorText(value.operator));
                try self.json.objectField("value");
                try self.writeExpr(value.value);
                try self.endNode();
            },
            .binary => |value| {
                try self.beginNode("BinaryExpr", value.span);
                try self.json.objectField("operator");
                try self.json.write(operatorText(value.operator));
                try self.json.objectField("left");
                try self.writeExpr(value.left);
                try self.json.objectField("right");
                try self.writeExpr(value.right);
                try self.endNode();
            },
            .call => |value| {
                try self.beginNode("CallExpr", value.span);
                try self.json.objectField("callee");
                try self.writeExpr(value.callee);
                try self.json.objectField("args");
                try self.writeArgumentArray(value.args);
                try self.endNode();
            },
            .struct_init => |value| {
                try self.beginNode("StructInitExpr", value.span);
                try self.json.objectField("type_path");
                try self.writeAccessPath(value.type_path);
                try self.json.objectField("fields");
                try self.writeArgumentArray(value.fields);
                try self.endNode();
            },
            .variant => |value| {
                try self.beginNode("VariantExpr", value.span);
                try self.json.objectField("path");
                try self.writeAccessPath(value.path);
                switch (value.payload) {
                    .positional => |inner| {
                        try self.json.objectField("payload");
                        try self.writeExpr(inner);
                    },
                    .named => |fields| {
                        try self.json.objectField("fields");
                        try self.writeArgumentArray(fields);
                    },
                }
                try self.endNode();
            },
            .match_expr => |value| try self.writeMatchExpr(value),
        }
    }

    fn writeArgumentArray(self: *Renderer, args: []const tree.Argument) JsonError!void {
        try self.json.beginArray();
        for (args) |arg| {
            try self.writeArgument(arg);
        }
        try self.json.endArray();
    }

    fn writeArgument(self: *Renderer, arg: tree.Argument) JsonError!void {
        try self.beginNode("Argument", arg.span);
        try self.writeNameField(arg.name);
        try self.json.objectField("value");
        try self.writeExpr(arg.value);
        try self.endNode();
    }

    fn beginNode(self: *Renderer, kind: []const u8, span: source.Span) JsonError!void {
        try self.json.beginObject();
        try self.json.objectField("kind");
        try self.json.write(kind);
        try self.json.objectField("id");
        try self.writeNodeId();
        try self.json.objectField("semantic_id");
        try self.json.write(@as(?[]const u8, null));
        try self.json.objectField("span");
        try self.writeSpan(span);
    }

    fn endNode(self: *Renderer) JsonError!void {
        try self.json.endObject();
    }

    fn writeNodeId(self: *Renderer) JsonError!void {
        const node_id = self.generator.next(.ast_node);
        var buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "ast:{d}", .{node_id.index}) catch unreachable;
        try self.json.write(label);
    }

    fn writeSpan(self: *Renderer, span: source.Span) JsonError!void {
        const resolved = self.sources.resolveSpan(span);
        try self.json.beginObject();
        try self.json.objectField("file");
        try self.json.write(resolved.path);
        try self.json.objectField("start");
        try self.writeLocation(span.start, resolved.start);
        try self.json.objectField("end");
        try self.writeLocation(span.end, resolved.end);
        try self.json.endObject();
    }

    fn writeLocation(self: *Renderer, offset: usize, location: source.Location) JsonError!void {
        try self.json.beginObject();
        try self.json.objectField("offset");
        try self.json.write(offset);
        try self.json.objectField("line");
        try self.json.write(location.line);
        try self.json.objectField("column");
        try self.json.write(location.column);
        try self.json.endObject();
    }

    fn writeNameField(self: *Renderer, name: source.Span) JsonError!void {
        try self.json.objectField("name");
        try self.json.write(self.text(name));
    }

    fn writeVisibilityField(self: *Renderer, visibility: tree.Visibility) JsonError!void {
        try self.json.objectField("visibility");
        try self.json.write(switch (visibility) {
            .private => "private",
            .public => "public",
        });
    }

    fn text(self: *Renderer, span: source.Span) []const u8 {
        return span.slice(self.sources.getFile(span.file_id).source);
    }
};

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

test "ast json output is stable across repeated renders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/demo.lace",
        \\module demo;
        \\
        \\fn main() -> Result<Void, AppError> {
        \\    let user: User = User{
        \\        name: "Sam",
        \\    };
        \\
        \\    let port: Int = match parse_port(value: "3000") {
        \\        Ok(value) => value;
        \\        Err(AppError.invalid_name) => {
        \\            return Err(AppError.invalid_name);
        \\        }
        \\    };
        \\
        \\    bind checked = parse_port(value: "3000") else err => {
        \\        return Err(err);
        \\    };
        \\
        \\    print(value: user.name);
        \\
        \\    return Ok(Void);
        \\}
    );

    var diagnostics: @import("../diag/mod.zig").Store = .{};
    const document = try @import("parser.zig").parseFile(arena, &diagnostics, sources.getFile(file_id));

    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try renderJson(&first.writer, &sources, document);

    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try renderJson(&second.writer, &sources, document);

    try std.testing.expectEqualStrings(first.written(), second.written());
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"Module\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"FunctionDecl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"LetStmt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"MatchExpr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"BindStmt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"CallExpr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"StructInitExpr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"kind\":\"VariantExpr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"id\":\"ast:0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"semantic_id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"file\":\"src/demo.lace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"offset\":0") != null);
}
