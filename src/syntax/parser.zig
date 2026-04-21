const std = @import("std");

const diag = @import("../diag/mod.zig");
const lexer = @import("lexer.zig");
const source = @import("../source.zig");
const token = @import("token.zig");
const tree = @import("tree.zig");

pub const ParseError = error{
    InvalidSyntax,
    OutOfMemory,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    diagnostics: *diag.Store,
    file: *const source.File,
    tokens: []const token.Token,
    cursor: usize = 0,

    pub fn init(
        arena: std.mem.Allocator,
        diagnostics: *diag.Store,
        file: *const source.File,
        tokens: []const token.Token,
    ) Parser {
        return .{
            .arena = arena,
            .diagnostics = diagnostics,
            .file = file,
            .tokens = tokens,
        };
    }

    pub fn parseDocument(self: *Parser) ParseError!tree.Document {
        const module_decl = try self.parseModuleDecl();

        var imports: std.ArrayList(tree.ImportDecl) = .empty;
        while (self.at(.kw_import)) {
            try imports.append(self.arena, try self.parseImportDecl());
        }

        var items: std.ArrayList(tree.Item) = .empty;
        while (!self.at(.eof)) {
            try items.append(self.arena, try self.parseItem());
        }

        return .{
            .file_id = self.file.id,
            .tokens = self.tokens,
            .module_decl = module_decl,
            .imports = try imports.toOwnedSlice(self.arena),
            .items = try items.toOwnedSlice(self.arena),
        };
    }

    fn parseModuleDecl(self: *Parser) ParseError!tree.ModuleDecl {
        const module_token = try self.expect(.kw_module, "P0001", "Expected `module` declaration at file start");
        const path = try self.parsePath();
        const semicolon = try self.expect(.semicolon, "P0002", "Expected `;` after module declaration");
        return .{
            .span = joinSpans(module_token.span, semicolon.span),
            .path = path,
        };
    }

    fn parseImportDecl(self: *Parser) ParseError!tree.ImportDecl {
        const import_token = try self.expect(.kw_import, "P0003", "Expected `import` declaration");
        const path = try self.parsePath();
        const semicolon = try self.expect(.semicolon, "P0004", "Expected `;` after import declaration");
        return .{
            .span = joinSpans(import_token.span, semicolon.span),
            .path = path,
        };
    }

    fn parseItem(self: *Parser) ParseError!tree.Item {
        var visibility: tree.Visibility = .private;
        var visibility_token: ?token.Token = null;

        if (self.match(.kw_pub)) |pub_token| {
            visibility = .public;
            visibility_token = pub_token;
        }

        const next_token = self.current();
        return switch (next_token.tag) {
            .kw_struct => .{ .struct_decl = try self.parseStructDecl(visibility, visibility_token) },
            .kw_enum => .{ .enum_decl = try self.parseEnumDecl(visibility, visibility_token) },
            .kw_error => .{ .error_decl = try self.parseErrorDecl(visibility, visibility_token) },
            .kw_fn => .{ .function_decl = try self.parseFunctionDecl(visibility, visibility_token) },
            .kw_const => .{ .const_decl = try self.parseConstDecl(visibility, visibility_token) },
            .kw_test => {
                if (visibility == .public) {
                    return self.failCurrent("P0005", "`test` blocks cannot be declared `pub`");
                }
                return .{ .test_decl = try self.parseTestDecl() };
            },
            .kw_import => self.failCurrent("P0006", "Imports must appear before top-level declarations"),
            else => self.failCurrent("P0007", "Unexpected token at top level"),
        };
    }

    fn parseStructDecl(
        self: *Parser,
        visibility: tree.Visibility,
        visibility_token: ?token.Token,
    ) ParseError!tree.StructDecl {
        const struct_token = try self.expect(.kw_struct, "P0008", "Expected `struct` declaration");
        const name = try self.expectIdentifier("P0009", "Expected struct name");
        _ = try self.expect(.l_brace, "P0010", "Expected `{` before struct fields");
        const fields = try self.parseFieldList(.r_brace, "struct field", "P0011", "P0012");
        const closing = try self.expect(.r_brace, "P0013", "Expected `}` after struct declaration");
        return .{
            .span = declSpan(visibility_token, struct_token.span, closing.span),
            .visibility = visibility,
            .name = name.span,
            .fields = fields,
        };
    }

    fn parseEnumDecl(
        self: *Parser,
        visibility: tree.Visibility,
        visibility_token: ?token.Token,
    ) ParseError!tree.EnumDecl {
        const enum_token = try self.expect(.kw_enum, "P0014", "Expected `enum` declaration");
        const name = try self.expectIdentifier("P0015", "Expected enum name");
        _ = try self.expect(.l_brace, "P0016", "Expected `{` before enum variants");
        const variants = try self.parseVariantList("enum variant", "P0017", "P0018");
        const closing = try self.expect(.r_brace, "P0019", "Expected `}` after enum declaration");
        return .{
            .span = declSpan(visibility_token, enum_token.span, closing.span),
            .visibility = visibility,
            .name = name.span,
            .variants = variants,
        };
    }

    fn parseErrorDecl(
        self: *Parser,
        visibility: tree.Visibility,
        visibility_token: ?token.Token,
    ) ParseError!tree.ErrorDecl {
        const error_token = try self.expect(.kw_error, "P0020", "Expected `error` declaration");
        const name = try self.expectIdentifier("P0021", "Expected error name");
        _ = try self.expect(.l_brace, "P0022", "Expected `{` before error variants");
        const variants = try self.parseVariantList("error variant", "P0023", "P0024");
        const closing = try self.expect(.r_brace, "P0025", "Expected `}` after error declaration");
        return .{
            .span = declSpan(visibility_token, error_token.span, closing.span),
            .visibility = visibility,
            .name = name.span,
            .variants = variants,
        };
    }

    fn parseFunctionDecl(
        self: *Parser,
        visibility: tree.Visibility,
        visibility_token: ?token.Token,
    ) ParseError!tree.FunctionDecl {
        const fn_token = try self.expect(.kw_fn, "P0026", "Expected `fn` declaration");
        const name = try self.expectIdentifier("P0027", "Expected function name");
        _ = try self.expect(.l_paren, "P0028", "Expected `(` before function parameters");
        const params = try self.parseFieldList(.r_paren, "function parameter", "P0029", "P0030");
        _ = try self.expect(.r_paren, "P0031", "Expected `)` after function parameters");

        if (!self.at(.arrow)) {
            return self.failCurrent("P0032", "Functions require an explicit return type");
        }

        _ = self.advance();
        const return_type = try self.parseTypeRef();
        const body = try self.parseBlock("P0033", "Expected function body");

        return .{
            .span = declSpan(visibility_token, fn_token.span, body.span),
            .visibility = visibility,
            .name = name.span,
            .params = params,
            .return_type = return_type,
            .body = body,
        };
    }

    fn parseConstDecl(
        self: *Parser,
        visibility: tree.Visibility,
        visibility_token: ?token.Token,
    ) ParseError!tree.ConstDecl {
        const const_token = try self.expect(.kw_const, "P0034", "Expected `const` declaration");
        const name = try self.expectIdentifier("P0035", "Expected constant name");
        _ = try self.expect(.colon, "P0036", "Expected `:` after constant name");
        const type_ref = try self.parseTypeRef();
        _ = try self.expect(.eq, "P0037", "Expected `=` after constant type");
        const initializer = try self.parseInitializer();
        const semicolon = try self.expect(.semicolon, "P0038", "Expected `;` after constant declaration");
        return .{
            .span = declSpan(visibility_token, const_token.span, semicolon.span),
            .visibility = visibility,
            .name = name.span,
            .type_ref = type_ref,
            .initializer = initializer,
        };
    }

    fn parseTestDecl(self: *Parser) ParseError!tree.TestDecl {
        const test_token = try self.expect(.kw_test, "P0039", "Expected `test` declaration");
        const name = try self.expect(.string_literal, "P0040", "Expected string literal test name");
        const body = try self.parseBlock("P0041", "Expected test body");
        return .{
            .span = joinSpans(test_token.span, body.span),
            .name = name.span,
            .body = body,
        };
    }

    fn parseFieldList(
        self: *Parser,
        closing_tag: token.Tag,
        item_name: []const u8,
        missing_separator_code: []const u8,
        missing_trailing_comma_code: []const u8,
    ) ParseError![]const tree.Field {
        var fields: std.ArrayList(tree.Field) = .empty;
        var saw_item = false;
        var last_item_line: usize = 0;

        while (!self.at(closing_tag)) {
            const field = try self.parseField(item_name);
            saw_item = true;
            last_item_line = self.file.location(field.span.end).line;
            try fields.append(self.arena, field);

            if (self.match(.comma) != null) {
                continue;
            }

            if (!self.at(closing_tag)) {
                return self.failCurrent(missing_separator_code, separatorMessage(item_name, closing_tag));
            }

            if (saw_item and self.file.location(self.current().span.start).line != last_item_line) {
                return self.failCurrent(missing_trailing_comma_code, trailingCommaMessage(item_name));
            }
        }

        return try fields.toOwnedSlice(self.arena);
    }

    fn parseField(self: *Parser, item_name: []const u8) ParseError!tree.Field {
        const name = try self.expectIdentifier("P0042", nameMessage(item_name));
        _ = try self.expect(.colon, "P0043", colonMessage(item_name));
        const type_ref = try self.parseTypeRef();
        return .{
            .span = joinSpans(name.span, type_ref.span),
            .name = name.span,
            .type_ref = type_ref,
        };
    }

    fn parseVariantList(
        self: *Parser,
        item_name: []const u8,
        missing_separator_code: []const u8,
        missing_trailing_comma_code: []const u8,
    ) ParseError![]const tree.Variant {
        var variants: std.ArrayList(tree.Variant) = .empty;
        var saw_item = false;
        var last_item_line: usize = 0;

        while (!self.at(.r_brace)) {
            const variant = try self.parseVariant(item_name);
            saw_item = true;
            last_item_line = self.file.location(variant.span.end).line;
            try variants.append(self.arena, variant);

            if (self.match(.comma) != null) {
                continue;
            }

            if (!self.at(.r_brace)) {
                return self.failCurrent(missing_separator_code, separatorMessage(item_name, .r_brace));
            }

            if (saw_item and self.file.location(self.current().span.start).line != last_item_line) {
                return self.failCurrent(missing_trailing_comma_code, trailingCommaMessage(item_name));
            }
        }

        return try variants.toOwnedSlice(self.arena);
    }

    fn parseVariant(self: *Parser, item_name: []const u8) ParseError!tree.Variant {
        const name = try self.expectIdentifier("P0044", nameMessage(item_name));
        var fields: []const tree.Field = &.{};
        var end_span = name.span;

        if (self.match(.l_paren)) |open_paren| {
            _ = open_paren;
            fields = try self.parseFieldList(.r_paren, "variant field", "P0045", "P0046");
            const close_paren = try self.expect(.r_paren, "P0047", "Expected `)` after variant payload");
            end_span = close_paren.span;
        }

        return .{
            .span = joinSpans(name.span, end_span),
            .name = name.span,
            .fields = fields,
        };
    }

    fn parseTypeRef(self: *Parser) ParseError!tree.TypeRef {
        const path = try self.parsePath();
        var arguments: []const tree.TypeRef = &.{};
        var end_span = path.span;

        if (self.match(.lt) != null) {
            var argument_list: std.ArrayList(tree.TypeRef) = .empty;

            while (!self.at(.gt)) {
                try argument_list.append(self.arena, try self.parseTypeRef());

                if (self.match(.comma) != null) {
                    continue;
                }

                if (!self.at(.gt)) {
                    return self.failCurrent("P0048", "Expected `,` or `>` in generic type argument list");
                }
            }

            const closing = try self.expect(.gt, "P0049", "Expected `>` after generic type argument list");
            arguments = try argument_list.toOwnedSlice(self.arena);
            end_span = closing.span;
        }

        return .{
            .span = joinSpans(path.span, end_span),
            .path = path,
            .arguments = arguments,
        };
    }

    fn parsePath(self: *Parser) ParseError!tree.Path {
        var segments: std.ArrayList(tree.PathSegment) = .empty;

        const first_segment = try self.parsePathSegment();
        try segments.append(self.arena, first_segment);

        while (self.match(.slash) != null) {
            try segments.append(self.arena, try self.parsePathSegment());
        }

        const owned_segments = try segments.toOwnedSlice(self.arena);
        return .{
            .span = joinSpans(owned_segments[0].span, owned_segments[owned_segments.len - 1].span),
            .segments = owned_segments,
        };
    }

    fn parsePathSegment(self: *Parser) ParseError!tree.PathSegment {
        const first = try self.expectIdentifier("P0050", "Expected path segment");
        var end_span = first.span;

        while (self.match(.dot) != null) {
            const next = try self.expectIdentifier("P0051", "Expected identifier after `.` in path segment");
            end_span = next.span;
        }

        return .{
            .span = joinSpans(first.span, end_span),
        };
    }

    fn parseBlock(self: *Parser, code: []const u8, message: []const u8) ParseError!tree.Block {
        const open = try self.expect(.l_brace, code, message);
        const body_start = self.cursor;
        const body_span_start = open.span.end;
        var depth: usize = 1;

        while (self.cursor < self.tokens.len) {
            const current_token = self.advance();
            switch (current_token.tag) {
                .l_brace => depth += 1,
                .r_brace => {
                    depth -= 1;
                    if (depth == 0) {
                        return .{
                            .span = joinSpans(open.span, current_token.span),
                            .body = .{
                                .span = source.Span.init(self.file.id, body_span_start, current_token.span.start),
                                .token_start = body_start,
                                .token_end = self.cursor - 1,
                            },
                        };
                    }
                },
                .eof => break,
                else => {},
            }
        }

        return self.failAt(open.span, "P0052", "Unterminated block");
    }

    fn parseInitializer(self: *Parser) ParseError!tree.OpaqueRange {
        if (self.at(.semicolon)) {
            return self.failCurrent("P0053", "Expected constant initializer");
        }

        const start_index = self.cursor;
        const start_token = self.current();
        var paren_depth: usize = 0;
        var brace_depth: usize = 0;

        while (!self.at(.eof)) {
            const current_token = self.current();

            if (paren_depth == 0 and brace_depth == 0 and current_token.tag == .semicolon) {
                return .{
                    .span = source.Span.init(self.file.id, start_token.span.start, current_token.span.start),
                    .token_start = start_index,
                    .token_end = self.cursor,
                };
            }

            switch (current_token.tag) {
                .l_paren => paren_depth += 1,
                .r_paren => {
                    if (paren_depth == 0) {
                        return self.failAt(current_token.span, "P0054", "Unexpected `)` in constant initializer");
                    }
                    paren_depth -= 1;
                },
                .l_brace => brace_depth += 1,
                .r_brace => {
                    if (brace_depth == 0) {
                        return self.failAt(current_token.span, "P0055", "Unexpected `}` in constant initializer");
                    }
                    brace_depth -= 1;
                },
                else => {},
            }

            _ = self.advance();
        }

        return self.failAt(start_token.span, "P0056", "Unterminated constant initializer");
    }

    fn current(self: *const Parser) token.Token {
        return self.tokens[self.cursor];
    }

    fn at(self: *const Parser, tag: token.Tag) bool {
        return self.current().tag == tag;
    }

    fn advance(self: *Parser) token.Token {
        const current_token = self.current();
        if (self.cursor < self.tokens.len - 1) {
            self.cursor += 1;
        }
        return current_token;
    }

    fn match(self: *Parser, tag: token.Tag) ?token.Token {
        if (!self.at(tag)) {
            return null;
        }

        return self.advance();
    }

    fn expect(self: *Parser, tag: token.Tag, code: []const u8, message: []const u8) ParseError!token.Token {
        if (!self.at(tag)) {
            return self.failCurrent(code, message);
        }

        return self.advance();
    }

    fn expectIdentifier(self: *Parser, code: []const u8, message: []const u8) ParseError!token.Token {
        return self.expect(.identifier, code, message);
    }

    fn failCurrent(self: *Parser, code: []const u8, message: []const u8) ParseError {
        return self.failAt(self.current().span, code, message);
    }

    fn failAt(self: *Parser, span: source.Span, code: []const u8, message: []const u8) ParseError {
        self.diagnostics.append(self.arena, .{
            .code = code,
            .message = message,
            .span = span,
        }) catch return error.OutOfMemory;
        return error.InvalidSyntax;
    }
};

pub fn parseFile(
    arena: std.mem.Allocator,
    diagnostics: *diag.Store,
    file: *const source.File,
) ParseError!tree.Document {
    var tokens = try lexer.lexFile(arena, diagnostics, file);
    const owned_tokens = try tokens.toOwnedSlice(arena);

    var parser = Parser.init(arena, diagnostics, file, owned_tokens);
    return parser.parseDocument();
}

fn joinSpans(start: source.Span, end: source.Span) source.Span {
    return source.Span.init(start.file_id, start.start, end.end);
}

fn declSpan(prefix: ?token.Token, start: source.Span, end: source.Span) source.Span {
    if (prefix) |value| {
        return joinSpans(value.span, end);
    }

    return joinSpans(start, end);
}

fn separatorMessage(item_name: []const u8, closing_tag: token.Tag) []const u8 {
    return switch (closing_tag) {
        .r_paren => switchString(item_name, "Expected `,` or `)` after function parameter", "Expected `,` or `)` after variant field"),
        .r_brace => switchString(item_name, "Expected `,` or `}` after struct field", "Expected `,` or `}` after variant"),
        else => "Expected separator",
    };
}

fn trailingCommaMessage(item_name: []const u8) []const u8 {
    if (std.mem.eql(u8, item_name, "function parameter")) return "Multiline function parameters require a trailing comma";
    if (std.mem.eql(u8, item_name, "struct field")) return "Multiline struct fields require a trailing comma";
    if (std.mem.eql(u8, item_name, "enum variant")) return "Multiline enum variants require a trailing comma";
    if (std.mem.eql(u8, item_name, "error variant")) return "Multiline error variants require a trailing comma";
    if (std.mem.eql(u8, item_name, "variant field")) return "Multiline variant payload fields require a trailing comma";
    return "Multiline declarations require a trailing comma";
}

fn nameMessage(item_name: []const u8) []const u8 {
    if (std.mem.eql(u8, item_name, "struct field")) return "Expected struct field name";
    if (std.mem.eql(u8, item_name, "function parameter")) return "Expected function parameter name";
    if (std.mem.eql(u8, item_name, "variant field")) return "Expected variant field name";
    if (std.mem.eql(u8, item_name, "enum variant")) return "Expected enum variant name";
    if (std.mem.eql(u8, item_name, "error variant")) return "Expected error variant name";
    return "Expected name";
}

fn colonMessage(item_name: []const u8) []const u8 {
    if (std.mem.eql(u8, item_name, "struct field")) return "Expected `:` after struct field name";
    if (std.mem.eql(u8, item_name, "function parameter")) return "Expected `:` after function parameter name";
    if (std.mem.eql(u8, item_name, "variant field")) return "Expected `:` after variant field name";
    return "Expected `:` after name";
}

fn switchString(item_name: []const u8, left: []const u8, right: []const u8) []const u8 {
    if (std.mem.eql(u8, item_name, "function parameter")) return left;
    return right;
}

test "parser accepts top-level Lace declarations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/app/signup.lace",
        \\module app/signup;
        \\import std/string;
        \\import github.com/sam/validation/email;
        \\
        \\pub struct SignupInput {
        \\    name: String,
        \\    email: String,
        \\}
        \\
        \\pub enum Token {
        \\    identifier(value: String),
        \\    eof,
        \\}
        \\
        \\pub error SignupError {
        \\    bad_email(source: String),
        \\    duplicate_email(email: String),
        \\}
        \\
        \\pub const DEFAULT_PORT: Result<Int, SignupError> = Ok(3000);
        \\
        \\pub fn signup(
        \\    input: SignupInput,
        \\) -> Result<String, SignupError> {
        \\    return Ok("ok");
        \\}
        \\
        \\test "signup works" {
        \\    return Ok("test");
        \\}
    );

    var diagnostics: diag.Store = .{};

    const document = try parseFile(arena, &diagnostics, sources.getFile(file_id));

    try std.testing.expectEqual(@as(usize, 2), document.imports.len);
    try std.testing.expectEqual(@as(usize, 6), document.items.len);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());

    const module_path = document.module_decl.path;
    try std.testing.expectEqual(@as(usize, 2), module_path.segments.len);
    try std.testing.expectEqualStrings("app", module_path.segments[0].span.slice(sources.getFile(file_id).source));
    try std.testing.expectEqualStrings("signup", module_path.segments[1].span.slice(sources.getFile(file_id).source));

    const struct_decl = document.items[0].struct_decl;
    try std.testing.expectEqual(tree.Visibility.public, struct_decl.visibility);
    try std.testing.expectEqual(@as(usize, 2), struct_decl.fields.len);

    const enum_decl = document.items[1].enum_decl;
    try std.testing.expectEqual(@as(usize, 2), enum_decl.variants.len);
    try std.testing.expectEqual(@as(usize, 1), enum_decl.variants[0].fields.len);

    const const_decl = document.items[3].const_decl;
    try std.testing.expectEqual(@as(usize, 2), const_decl.type_ref.arguments.len);

    const fn_decl = document.items[4].function_decl;
    try std.testing.expectEqual(@as(usize, 1), fn_decl.params.len);
    try std.testing.expect(fn_decl.body.body.token_end > fn_decl.body.body.token_start);

    const test_decl = document.items[5].test_decl;
    try std.testing.expect(test_decl.body.body.token_end > test_decl.body.body.token_start);
}

test "parser requires explicit function return types" {
    try expectParseError(
        \\module demo;
        \\
        \\fn greet(name: String) {
        \\    return name;
        \\}
    , "P0032");
}

test "parser requires semicolons after imports" {
    try expectParseError(
        \\module demo;
        \\import std/string
        \\
        \\fn main() -> Void {
        \\}
    , "P0004");
}

test "parser requires trailing commas in multiline field lists" {
    try expectParseError(
        \\module demo;
        \\
        \\pub struct User {
        \\    name: String
        \\    email: String,
        \\}
    , "P0011");
}

test "parser requires trailing commas before multiline closes" {
    try expectParseError(
        \\module demo;
        \\
        \\pub struct User {
        \\    name: String
        \\}
    , "P0012");
}

fn expectParseError(contents: []const u8, expected_code: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(std.testing.allocator, "src/test.lace", contents);

    var diagnostics: diag.Store = .{};

    try std.testing.expectError(error.InvalidSyntax, parseFile(arena, &diagnostics, sources.getFile(file_id)));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.count());
    try std.testing.expectEqualStrings(expected_code, diagnostics.items.items[0].code);
}
