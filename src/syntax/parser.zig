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

        return switch (self.current().tag) {
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
        const fields = try self.parseFieldList(.r_brace, .struct_field);
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
        const variants = try self.parseVariantList(.enum_variant);
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
        const variants = try self.parseVariantList(.error_variant);
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
        const params = try self.parseFieldList(.r_paren, .function_parameter);
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
        const initializer = try self.parseExpression();
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

    fn parseBlock(self: *Parser, code: []const u8, message: []const u8) ParseError!tree.Block {
        const open = try self.expect(.l_brace, code, message);
        var statements: std.ArrayList(tree.Statement) = .empty;

        while (!self.at(.r_brace)) {
            if (self.at(.eof)) {
                return self.failAt(open.span, "P0052", "Unterminated block");
            }

            try statements.append(self.arena, try self.parseStatement());
        }

        const close = try self.expect(.r_brace, "P0052", "Unterminated block");
        return .{
            .span = joinSpans(open.span, close.span),
            .statements = try statements.toOwnedSlice(self.arena),
        };
    }

    fn parseStatement(self: *Parser) ParseError!tree.Statement {
        return switch (self.current().tag) {
            .kw_let => .{ .let_stmt = try self.parseLetStmt() },
            .kw_const => .{ .const_stmt = try self.parseLocalConstStmt() },
            .kw_bind => .{ .bind_stmt = try self.parseBindStmt() },
            .kw_if => .{ .if_stmt = try self.parseIfStmt() },
            .kw_match => .{ .match_stmt = try self.parseMatchExprNode() },
            .kw_return => .{ .return_stmt = try self.parseReturnStmt() },
            else => .{ .expr_stmt = try self.parseExprStmt() },
        };
    }

    fn parseLetStmt(self: *Parser) ParseError!tree.LetStmt {
        const let_token = try self.expect(.kw_let, "P0053", "Expected `let` statement");
        const name = try self.expectIdentifier("P0054", "Expected binding name after `let`");
        const type_ref = try self.parseOptionalTypeRef();
        _ = try self.expect(.eq, "P0055", "Expected `=` after `let` binding");
        const value = try self.parseExpression();
        const semicolon = try self.expect(.semicolon, "P0056", "Expected `;` after `let` statement");
        return .{
            .span = joinSpans(let_token.span, semicolon.span),
            .name = name.span,
            .type_ref = type_ref,
            .value = value,
        };
    }

    fn parseLocalConstStmt(self: *Parser) ParseError!tree.ConstStmt {
        const const_token = try self.expect(.kw_const, "P0057", "Expected `const` statement");
        const name = try self.expectIdentifier("P0058", "Expected binding name after `const`");
        const type_ref = try self.parseOptionalTypeRef();
        _ = try self.expect(.eq, "P0059", "Expected `=` after `const` binding");
        const value = try self.parseExpression();
        const semicolon = try self.expect(.semicolon, "P0061", "Expected `;` after `const` statement");
        return .{
            .span = joinSpans(const_token.span, semicolon.span),
            .name = name.span,
            .type_ref = type_ref,
            .value = value,
        };
    }

    fn parseBindStmt(self: *Parser) ParseError!tree.BindStmt {
        const bind_token = try self.expect(.kw_bind, "P0062", "Expected `bind` statement");
        const name = try self.expectIdentifier("P0063", "Expected binding name after `bind`");
        const type_ref = try self.parseOptionalTypeRef();
        _ = try self.expect(.eq, "P0064", "Expected `=` after bind target");
        const value = try self.parseExpression();

        if (!self.at(.kw_else)) {
            return self.failCurrent("P0065", "Result binding requires an explicit else branch");
        }

        _ = self.advance();
        const else_name = try self.expectIdentifier("P0066", "Expected error binding name after `else`");
        _ = try self.expect(.fat_arrow, "P0067", "Expected `=>` after bind else binding");

        const else_body: tree.BindElseBody = if (self.at(.l_brace))
            .{ .block = try self.parseBlock("P0068", "Expected bind else body") }
        else
            .{ .expr = try self.parseExpression() };

        const semicolon = try self.expect(.semicolon, "P0069", "Expected `;` after bind statement");
        return .{
            .span = joinSpans(bind_token.span, semicolon.span),
            .name = name.span,
            .type_ref = type_ref,
            .value = value,
            .else_name = else_name.span,
            .else_body = else_body,
        };
    }

    fn parseIfStmt(self: *Parser) ParseError!tree.IfStmt {
        const if_token = try self.expect(.kw_if, "P0070", "Expected `if` statement");
        const condition = try self.parseExpression();
        const then_block = try self.parseBlock("P0071", "Expected `if` body");

        var else_block: ?tree.Block = null;
        var end_span = then_block.span;

        if (self.match(.kw_else) != null) {
            else_block = try self.parseBlock("P0072", "Expected `{` after `else`");
            end_span = else_block.?.span;
        }

        return .{
            .span = joinSpans(if_token.span, end_span),
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
        };
    }

    fn parseReturnStmt(self: *Parser) ParseError!tree.ReturnStmt {
        const return_token = try self.expect(.kw_return, "P0073", "Expected `return` statement");
        const value = try self.parseExpression();
        const semicolon = try self.expect(.semicolon, "P0074", "Expected `;` after `return` statement");
        return .{
            .span = joinSpans(return_token.span, semicolon.span),
            .value = value,
        };
    }

    fn parseExprStmt(self: *Parser) ParseError!tree.ExprStmt {
        const value = try self.parseExpression();
        const semicolon = try self.expect(.semicolon, "P0075", "Expected `;` after expression statement");
        return .{
            .span = joinSpans(value.*.span(), semicolon.span),
            .value = value,
        };
    }

    fn parseExpression(self: *Parser) ParseError!*tree.Expr {
        if (self.at(.kw_match)) {
            return self.allocExpr(.{ .match_expr = try self.parseMatchExprNode() });
        }

        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!*tree.Expr {
        var expr = try self.parseAdditive();

        while (isComparisonOperator(self.current().tag)) {
            const operator = self.advance();
            const right = try self.parseAdditive();
            expr = try self.allocExpr(.{ .binary = .{
                .span = joinSpans(expr.*.span(), right.*.span()),
                .operator = operator.tag,
                .left = expr,
                .right = right,
            } });
        }

        return expr;
    }

    fn parseAdditive(self: *Parser) ParseError!*tree.Expr {
        var expr = try self.parseMultiplicative();

        while (self.at(.plus) or self.at(.minus)) {
            const operator = self.advance();
            const right = try self.parseMultiplicative();
            expr = try self.allocExpr(.{ .binary = .{
                .span = joinSpans(expr.*.span(), right.*.span()),
                .operator = operator.tag,
                .left = expr,
                .right = right,
            } });
        }

        return expr;
    }

    fn parseMultiplicative(self: *Parser) ParseError!*tree.Expr {
        var expr = try self.parseUnary();

        while (self.at(.star)) {
            const operator = self.advance();
            const right = try self.parseUnary();
            expr = try self.allocExpr(.{ .binary = .{
                .span = joinSpans(expr.*.span(), right.*.span()),
                .operator = operator.tag,
                .left = expr,
                .right = right,
            } });
        }

        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!*tree.Expr {
        if (self.at(.bang) or self.at(.minus)) {
            const operator = self.advance();
            const value = try self.parseUnary();
            return self.allocExpr(.{ .unary = .{
                .span = joinSpans(operator.span, value.*.span()),
                .operator = operator.tag,
                .value = value,
            } });
        }

        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*tree.Expr {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.at(.l_paren)) {
                if (self.accessPathFromExpr(expr) != null) {
                    if (self.exprStartsWithUppercasePath(expr)) {
                        expr = try self.parseVariantExpr(expr);
                    } else {
                        expr = try self.parseCallExpr(expr);
                    }
                    continue;
                }

                return expr;
            }

            if (self.at(.l_brace)) {
                if (self.exprStartsWithUppercasePath(expr)) {
                    expr = try self.parseStructInitExpr(expr);
                    continue;
                }

                return expr;
            }

            return expr;
        }
    }

    fn parsePrimary(self: *Parser) ParseError!*tree.Expr {
        if (self.at(.l_paren)) {
            _ = self.advance();
            const expr = try self.parseExpression();
            _ = try self.expect(.r_paren, "P0076", "Expected `)` after grouped expression");
            return expr;
        }

        if (self.at(.kw_true) or self.at(.kw_false)) {
            const literal = self.advance();
            return self.allocExpr(.{ .bool_literal = literal.span });
        }

        if (self.at(.int_literal)) {
            const literal = self.advance();
            return self.allocExpr(.{ .int_literal = literal.span });
        }

        if (self.at(.string_literal)) {
            const literal = self.advance();
            return self.allocExpr(.{ .string_literal = literal.span });
        }

        if (isAccessSegmentTag(self.current().tag)) {
            return self.allocExpr(.{ .access_path = try self.parseAccessPath() });
        }

        return self.failCurrent("P0077", "Expected expression");
    }

    fn parseMatchExprNode(self: *Parser) ParseError!tree.MatchExpr {
        const match_token = try self.expect(.kw_match, "P0078", "Expected `match` expression");
        const value = try self.parseExpression();
        _ = try self.expect(.l_brace, "P0079", "Expected `{` after match value");

        var arms: std.ArrayList(tree.MatchArm) = .empty;
        while (!self.at(.r_brace)) {
            if (self.at(.eof)) {
                return self.failAt(match_token.span, "P0080", "Unterminated match expression");
            }

            try arms.append(self.arena, try self.parseMatchArm());
        }

        const close = try self.expect(.r_brace, "P0080", "Unterminated match expression");
        return .{
            .span = joinSpans(match_token.span, close.span),
            .value = value,
            .arms = try arms.toOwnedSlice(self.arena),
        };
    }

    fn parseMatchArm(self: *Parser) ParseError!tree.MatchArm {
        const pattern = try self.parsePattern();
        _ = try self.expect(.fat_arrow, "P0081", "Expected `=>` after match pattern");
        const body = try self.parseMatchArmBody();
        return .{
            .span = joinSpans(pattern.span(), armBodyEnd(body)),
            .pattern = pattern,
            .body = body,
        };
    }

    fn parseMatchArmBody(self: *Parser) ParseError!tree.ArmBody {
        if (self.at(.l_brace)) {
            return .{ .block = try self.parseBlock("P0082", "Expected match arm body") };
        }

        if (self.at(.kw_return)) {
            return .{ .return_stmt = try self.parseReturnStmt() };
        }

        const expr = try self.parseExpression();
        _ = try self.expect(.semicolon, "P0083", "Expected `;` after match arm expression");
        return .{ .expr = expr };
    }

    fn parsePattern(self: *Parser) ParseError!tree.Pattern {
        const first = self.current();
        if (!isAccessSegmentTag(first.tag) and first.tag != .identifier) {
            return self.failCurrent("P0084", "Expected pattern");
        }

        if (first.tag == .identifier and !startsWithUppercase(self.tokenText(first)) and self.peekTag(1) != .dot and self.peekTag(1) != .l_paren) {
            _ = self.advance();
            return .{ .binding = .{ .span = first.span } };
        }

        const path = try self.parseAccessPath();
        var payload: ?tree.PatternPayload = null;
        var end_span = path.span;

        if (self.match(.l_paren) != null) {
            if (self.isNamedPatternFieldStart()) {
                payload = .{ .named = try self.parsePatternFieldList() };
            } else {
                payload = .{ .positional = try self.allocPattern(try self.parsePattern()) };
            }

            const close = try self.expect(.r_paren, "P0085", "Expected `)` after pattern payload");
            end_span = close.span;
        }

        return .{ .path = .{
            .span = joinSpans(path.span, end_span),
            .path = path,
            .payload = payload,
        } };
    }

    fn parsePatternFieldList(self: *Parser) ParseError![]const tree.PatternField {
        var fields: std.ArrayList(tree.PatternField) = .empty;
        var saw_item = false;
        var last_line: usize = 0;

        while (!self.at(.r_paren)) {
            const field_name = try self.expectIdentifier("P0086", "Expected pattern field name");
            _ = try self.expect(.colon, "P0087", "Expected `:` after pattern field name");
            const value = try self.allocPattern(try self.parsePattern());
            const span = joinSpans(field_name.span, value.*.span());

            saw_item = true;
            last_line = self.file.location(span.end).line;
            try fields.append(self.arena, .{
                .span = span,
                .name = field_name.span,
                .value = value,
            });

            if (self.match(.comma) != null) {
                continue;
            }

            if (!self.at(.r_paren)) {
                return self.failCurrent("P0088", "Expected `,` or `)` after pattern field");
            }

            if (saw_item and self.file.location(self.current().span.start).line != last_line) {
                return self.failCurrent("P0089", "Multiline pattern fields require a trailing comma");
            }
        }

        return try fields.toOwnedSlice(self.arena);
    }

    fn parseCallExpr(self: *Parser, callee: *tree.Expr) ParseError!*tree.Expr {
        const open = try self.expect(.l_paren, "P0090", "Expected `(` after call target");
        const args = try self.parseNamedArguments(.r_paren, .call_argument);
        const close = try self.expect(.r_paren, "P0091", "Expected `)` after call arguments");

        _ = open;
        return self.allocExpr(.{ .call = .{
            .span = joinSpans(callee.*.span(), close.span),
            .callee = callee,
            .args = args,
        } });
    }

    fn parseStructInitExpr(self: *Parser, value: *tree.Expr) ParseError!*tree.Expr {
        const path = self.accessPathFromExpr(value) orelse return self.failCurrent("P0092", "Struct initialization requires a type path");
        _ = try self.expect(.l_brace, "P0093", "Expected `{` after struct type");
        const fields = try self.parseNamedArguments(.r_brace, .struct_init_field);
        const close = try self.expect(.r_brace, "P0094", "Expected `}` after struct initializer");

        return self.allocExpr(.{ .struct_init = .{
            .span = joinSpans(path.span, close.span),
            .type_path = path,
            .fields = fields,
        } });
    }

    fn parseVariantExpr(self: *Parser, value: *tree.Expr) ParseError!*tree.Expr {
        const path = self.accessPathFromExpr(value) orelse return self.failCurrent("P0095", "Variant construction requires a path");
        _ = try self.expect(.l_paren, "P0096", "Expected `(` after variant path");

        if (self.at(.r_paren)) {
            return self.failCurrent("P0097", "Empty variant payloads are not allowed; use the bare variant path instead");
        }

        var payload: tree.VariantPayload = undefined;

        if (self.isNamedArgumentStart()) {
            payload = .{ .named = try self.parseNamedArguments(.r_paren, .variant_field) };
        } else {
            const positional = try self.parseExpression();
            if (!self.at(.r_paren)) {
                return self.failCurrent("P0098", "Variant expressions support one positional value or named fields");
            }
            payload = .{ .positional = positional };
        }

        const close = try self.expect(.r_paren, "P0099", "Expected `)` after variant payload");
        return self.allocExpr(.{ .variant = .{
            .span = joinSpans(path.span, close.span),
            .path = path,
            .payload = payload,
        } });
    }

    fn parseNamedArguments(self: *Parser, closing_tag: token.Tag, kind: NamedArgumentKind) ParseError![]const tree.Argument {
        var args: std.ArrayList(tree.Argument) = .empty;
        var saw_item = false;
        var last_line: usize = 0;

        while (!self.at(closing_tag)) {
            if (!self.isNamedArgumentStart()) {
                return self.failCurrent(namedArgumentCode(kind, true), namedArgumentStartMessage(kind));
            }

            const name = try self.expectIdentifier(namedArgumentCode(kind, true), namedArgumentNameMessage(kind));
            _ = try self.expect(.colon, namedArgumentCode(kind, false), namedArgumentColonMessage(kind));
            const value = try self.parseExpression();
            const span = joinSpans(name.span, value.*.span());

            saw_item = true;
            last_line = self.file.location(span.end).line;
            try args.append(self.arena, .{
                .span = span,
                .name = name.span,
                .value = value,
            });

            if (self.match(.comma) != null) {
                continue;
            }

            if (!self.at(closing_tag)) {
                return self.failCurrent(namedArgumentSeparatorCode(kind), namedArgumentSeparatorMessage(kind, closing_tag));
            }

            if (saw_item and self.file.location(self.current().span.start).line != last_line) {
                return self.failCurrent(namedArgumentTrailingCode(kind), namedArgumentTrailingMessage(kind));
            }
        }

        return try args.toOwnedSlice(self.arena);
    }

    fn parseOptionalTypeRef(self: *Parser) ParseError!?tree.TypeRef {
        if (self.match(.colon) == null) {
            return null;
        }

        return try self.parseTypeRef();
    }

    fn parseFieldList(self: *Parser, closing_tag: token.Tag, kind: DeclFieldKind) ParseError![]const tree.Field {
        var fields: std.ArrayList(tree.Field) = .empty;
        var saw_item = false;
        var last_line: usize = 0;

        while (!self.at(closing_tag)) {
            const name = try self.expectIdentifier(fieldNameCode(kind), fieldNameMessage(kind));
            _ = try self.expect(.colon, fieldColonCode(kind), fieldColonMessage(kind));
            const type_ref = try self.parseTypeRef();
            const span = joinSpans(name.span, type_ref.span);

            saw_item = true;
            last_line = self.file.location(span.end).line;
            try fields.append(self.arena, .{
                .span = span,
                .name = name.span,
                .type_ref = type_ref,
            });

            if (self.match(.comma) != null) {
                continue;
            }

            if (!self.at(closing_tag)) {
                return self.failCurrent(fieldSeparatorCode(kind), fieldSeparatorMessage(kind, closing_tag));
            }

            if (saw_item and self.file.location(self.current().span.start).line != last_line) {
                return self.failCurrent(fieldTrailingCode(kind), fieldTrailingMessage(kind));
            }
        }

        return try fields.toOwnedSlice(self.arena);
    }

    fn parseVariantList(self: *Parser, kind: VariantKind) ParseError![]const tree.Variant {
        var variants: std.ArrayList(tree.Variant) = .empty;
        var saw_item = false;
        var last_line: usize = 0;

        while (!self.at(.r_brace)) {
            const name = try self.expectIdentifier(variantNameCode(kind), variantNameMessage(kind));
            var fields: []const tree.Field = &.{};
            var end_span = name.span;

            if (self.match(.l_paren) != null) {
                fields = try self.parseFieldList(.r_paren, .variant_field);
                const close = try self.expect(.r_paren, "P0047", "Expected `)` after variant payload");
                end_span = close.span;
            }

            const span = joinSpans(name.span, end_span);
            saw_item = true;
            last_line = self.file.location(span.end).line;
            try variants.append(self.arena, .{
                .span = span,
                .name = name.span,
                .fields = fields,
            });

            if (self.match(.comma) != null) {
                continue;
            }

            if (!self.at(.r_brace)) {
                return self.failCurrent(variantSeparatorCode(kind), variantSeparatorMessage(kind));
            }

            if (saw_item and self.file.location(self.current().span.start).line != last_line) {
                return self.failCurrent(variantTrailingCode(kind), variantTrailingMessage(kind));
            }
        }

        return try variants.toOwnedSlice(self.arena);
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
        try segments.append(self.arena, .{ .span = try self.parsePathSegment() });

        while (self.match(.slash) != null) {
            try segments.append(self.arena, .{ .span = try self.parsePathSegment() });
        }

        const owned_segments = try segments.toOwnedSlice(self.arena);
        return .{
            .span = joinSpans(owned_segments[0].span, owned_segments[owned_segments.len - 1].span),
            .segments = owned_segments,
        };
    }

    fn parseAccessPath(self: *Parser) ParseError!tree.AccessPath {
        var segments: std.ArrayList(source.Span) = .empty;
        try segments.append(self.arena, (try self.expectAccessSegment("P0100", "Expected path segment")).span);

        while (self.match(.dot) != null) {
            try segments.append(self.arena, (try self.expectAccessSegment("P0101", "Expected identifier after `.`")).span);
        }

        const owned_segments = try segments.toOwnedSlice(self.arena);
        return .{
            .span = joinSpans(owned_segments[0], owned_segments[owned_segments.len - 1]),
            .segments = owned_segments,
        };
    }

    fn parsePathSegment(self: *Parser) ParseError!source.Span {
        const first = try self.expectIdentifier("P0050", "Expected path segment");
        var end_span = first.span;

        while (self.match(.dot) != null) {
            const next = try self.expectIdentifier("P0051", "Expected identifier after `.` in path segment");
            end_span = next.span;
        }

        return joinSpans(first.span, end_span);
    }

    fn current(self: *const Parser) token.Token {
        return self.tokens[self.cursor];
    }

    fn peekTag(self: *const Parser, offset: usize) token.Tag {
        const index = self.cursor + offset;
        if (index >= self.tokens.len) {
            return .eof;
        }

        return self.tokens[index].tag;
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

    fn expectAccessSegment(self: *Parser, code: []const u8, message: []const u8) ParseError!token.Token {
        if (!isAccessSegmentTag(self.current().tag)) {
            return self.failCurrent(code, message);
        }

        return self.advance();
    }

    fn accessPathFromExpr(self: *Parser, expr: *tree.Expr) ?tree.AccessPath {
        _ = self;
        return switch (expr.*) {
            .access_path => |value| value,
            else => null,
        };
    }

    fn exprStartsWithUppercasePath(self: *Parser, expr: *tree.Expr) bool {
        const path = self.accessPathFromExpr(expr) orelse return false;
        return startsWithUppercase(path.segments[0].slice(self.file.source));
    }

    fn isNamedArgumentStart(self: *const Parser) bool {
        return self.at(.identifier) and self.peekTag(1) == .colon;
    }

    fn isNamedPatternFieldStart(self: *const Parser) bool {
        return self.isNamedArgumentStart();
    }

    fn tokenText(self: *const Parser, value: token.Token) []const u8 {
        return value.span.slice(self.file.source);
    }

    fn allocExpr(self: *Parser, value: tree.Expr) ParseError!*tree.Expr {
        const expr = self.arena.create(tree.Expr) catch return error.OutOfMemory;
        expr.* = value;
        return expr;
    }

    fn allocPattern(self: *Parser, value: tree.Pattern) ParseError!*tree.Pattern {
        const pattern = self.arena.create(tree.Pattern) catch return error.OutOfMemory;
        pattern.* = value;
        return pattern;
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

const DeclFieldKind = enum {
    struct_field,
    function_parameter,
    variant_field,
};

const VariantKind = enum {
    enum_variant,
    error_variant,
};

const NamedArgumentKind = enum {
    call_argument,
    struct_init_field,
    variant_field,
};

fn joinSpans(start: source.Span, end: source.Span) source.Span {
    return source.Span.init(start.file_id, start.start, end.end);
}

fn declSpan(prefix: ?token.Token, start: source.Span, end: source.Span) source.Span {
    if (prefix) |value| {
        return joinSpans(value.span, end);
    }

    return joinSpans(start, end);
}

fn armBodyEnd(body: tree.ArmBody) source.Span {
    return switch (body) {
        .block => |value| value.span,
        .return_stmt => |value| value.span,
        .expr => |value| value.*.span(),
    };
}

fn isAccessSegmentTag(tag: token.Tag) bool {
    return switch (tag) {
        .identifier, .kw_none, .kw_some, .kw_ok, .kw_err, .kw_true, .kw_false => true,
        else => false,
    };
}

fn startsWithUppercase(text: []const u8) bool {
    return text.len > 0 and std.ascii.isUpper(text[0]);
}

fn isComparisonOperator(tag: token.Tag) bool {
    return switch (tag) {
        .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => true,
        else => false,
    };
}

fn fieldNameCode(kind: DeclFieldKind) []const u8 {
    return switch (kind) {
        .struct_field => "P0042",
        .function_parameter => "P0042",
        .variant_field => "P0042",
    };
}

fn fieldNameMessage(kind: DeclFieldKind) []const u8 {
    return switch (kind) {
        .struct_field => "Expected struct field name",
        .function_parameter => "Expected function parameter name",
        .variant_field => "Expected variant field name",
    };
}

fn fieldColonCode(kind: DeclFieldKind) []const u8 {
    return switch (kind) {
        .struct_field => "P0043",
        .function_parameter => "P0043",
        .variant_field => "P0043",
    };
}

fn fieldColonMessage(kind: DeclFieldKind) []const u8 {
    return switch (kind) {
        .struct_field => "Expected `:` after struct field name",
        .function_parameter => "Expected `:` after function parameter name",
        .variant_field => "Expected `:` after variant field name",
    };
}

fn fieldSeparatorCode(kind: DeclFieldKind) []const u8 {
    return switch (kind) {
        .struct_field => "P0011",
        .function_parameter => "P0029",
        .variant_field => "P0045",
    };
}

fn fieldSeparatorMessage(kind: DeclFieldKind, closing_tag: token.Tag) []const u8 {
    _ = closing_tag;
    return switch (kind) {
        .struct_field => "Expected `,` or `}` after struct field",
        .function_parameter => "Expected `,` or `)` after function parameter",
        .variant_field => "Expected `,` or `)` after variant field",
    };
}

fn fieldTrailingCode(kind: DeclFieldKind) []const u8 {
    return switch (kind) {
        .struct_field => "P0012",
        .function_parameter => "P0030",
        .variant_field => "P0046",
    };
}

fn fieldTrailingMessage(kind: DeclFieldKind) []const u8 {
    return switch (kind) {
        .struct_field => "Multiline struct fields require a trailing comma",
        .function_parameter => "Multiline function parameters require a trailing comma",
        .variant_field => "Multiline variant payload fields require a trailing comma",
    };
}

fn variantNameCode(kind: VariantKind) []const u8 {
    return switch (kind) {
        .enum_variant => "P0017",
        .error_variant => "P0023",
    };
}

fn variantNameMessage(kind: VariantKind) []const u8 {
    return switch (kind) {
        .enum_variant => "Expected enum variant name",
        .error_variant => "Expected error variant name",
    };
}

fn variantSeparatorCode(kind: VariantKind) []const u8 {
    return switch (kind) {
        .enum_variant => "P0017",
        .error_variant => "P0023",
    };
}

fn variantSeparatorMessage(kind: VariantKind) []const u8 {
    return switch (kind) {
        .enum_variant => "Expected `,` or `}` after enum variant",
        .error_variant => "Expected `,` or `}` after error variant",
    };
}

fn variantTrailingCode(kind: VariantKind) []const u8 {
    return switch (kind) {
        .enum_variant => "P0018",
        .error_variant => "P0024",
    };
}

fn variantTrailingMessage(kind: VariantKind) []const u8 {
    return switch (kind) {
        .enum_variant => "Multiline enum variants require a trailing comma",
        .error_variant => "Multiline error variants require a trailing comma",
    };
}

fn namedArgumentCode(kind: NamedArgumentKind, for_name: bool) []const u8 {
    return switch (kind) {
        .call_argument => if (for_name) "P0102" else "P0103",
        .struct_init_field => if (for_name) "P0104" else "P0105",
        .variant_field => if (for_name) "P0106" else "P0107",
    };
}

fn namedArgumentNameMessage(kind: NamedArgumentKind) []const u8 {
    return switch (kind) {
        .call_argument => "Expected call argument name",
        .struct_init_field => "Expected struct field name",
        .variant_field => "Expected variant field name",
    };
}

fn namedArgumentColonMessage(kind: NamedArgumentKind) []const u8 {
    return switch (kind) {
        .call_argument => "Expected `:` after call argument name",
        .struct_init_field => "Expected `:` after struct field name",
        .variant_field => "Expected `:` after variant field name",
    };
}

fn namedArgumentStartMessage(kind: NamedArgumentKind) []const u8 {
    return switch (kind) {
        .call_argument => "Function calls require named arguments",
        .struct_init_field => "Expected named struct initializer field",
        .variant_field => "Expected variant field name",
    };
}

fn namedArgumentSeparatorCode(kind: NamedArgumentKind) []const u8 {
    return switch (kind) {
        .call_argument => "P0108",
        .struct_init_field => "P0109",
        .variant_field => "P0110",
    };
}

fn namedArgumentSeparatorMessage(kind: NamedArgumentKind, closing_tag: token.Tag) []const u8 {
    _ = closing_tag;
    return switch (kind) {
        .call_argument => "Expected `,` or `)` after call argument",
        .struct_init_field => "Expected `,` or `}` after struct initializer field",
        .variant_field => "Expected `,` or `)` after variant field",
    };
}

fn namedArgumentTrailingCode(kind: NamedArgumentKind) []const u8 {
    return switch (kind) {
        .call_argument => "P0111",
        .struct_init_field => "P0112",
        .variant_field => "P0113",
    };
}

fn namedArgumentTrailingMessage(kind: NamedArgumentKind) []const u8 {
    return switch (kind) {
        .call_argument => "Multiline call arguments require a trailing comma",
        .struct_init_field => "Multiline struct initializer fields require a trailing comma",
        .variant_field => "Multiline variant fields require a trailing comma",
    };
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

    const const_decl = document.items[3].const_decl;
    try std.testing.expectEqual(@as(usize, 2), const_decl.type_ref.arguments.len);
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Expr), .variant), std.meta.activeTag(const_decl.initializer.*));

    const fn_decl = document.items[4].function_decl;
    try std.testing.expectEqual(@as(usize, 1), fn_decl.body.statements.len);

    const test_decl = document.items[5].test_decl;
    try std.testing.expectEqual(@as(usize, 1), test_decl.body.statements.len);
}

test "parser accepts end-to-end Lace function bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/main.lace",
        \\module main;
        \\
        \\pub error AppError {
        \\    invalid_name,
        \\}
        \\
        \\fn greet(
        \\    name: String,
        \\) -> Result<String, AppError> {
        \\    if name == "" {
        \\        return Err(AppError.invalid_name);
        \\    } else {
        \\        return Ok("hello " + name);
        \\    }
        \\}
        \\
        \\pub fn main() -> Result<Void, AppError> {
        \\    bind message: String = greet(
        \\        name: "Sam",
        \\    ) else err => {
        \\        return Err(err);
        \\    };
        \\
        \\    print(value: message);
        \\
        \\    return Ok(Void);
        \\}
    );

    var diagnostics: diag.Store = .{};
    const document = try parseFile(arena, &diagnostics, sources.getFile(file_id));

    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());
    const greet_decl = document.items[1].function_decl;
    try std.testing.expectEqual(@as(usize, 1), greet_decl.body.statements.len);
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Statement), .if_stmt), std.meta.activeTag(greet_decl.body.statements[0]));

    const main_decl = document.items[2].function_decl;
    try std.testing.expectEqual(@as(usize, 3), main_decl.body.statements.len);
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Statement), .bind_stmt), std.meta.activeTag(main_decl.body.statements[0]));
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Statement), .expr_stmt), std.meta.activeTag(main_decl.body.statements[1]));
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Statement), .return_stmt), std.meta.activeTag(main_decl.body.statements[2]));
}

test "parser accepts let match bind and struct init expressions" {
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
        \\fn parse(input: String) -> Result<Int, ParseError> {
        \\    let user: User = User{
        \\        name: input,
        \\        age: Some(10),
        \\    };
        \\
        \\    let port: Int = match parse_port(value: input) {
        \\        Ok(value) => value;
        \\        Err(ParseError.invalid(input: bad_input)) => {
        \\            return Err(ParseError.invalid(input: bad_input));
        \\        }
        \\    };
        \\
        \\    bind checked = parse_port(value: input) else err => match err {
        \\        ParseError.invalid(input: invalid_input) => return Err(ParseError.invalid(input: invalid_input));
        \\    };
        \\
        \\    return Ok(port + checked);
        \\}
    );

    var diagnostics: diag.Store = .{};
    const document = try parseFile(arena, &diagnostics, sources.getFile(file_id));
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());

    const function_decl = document.items[0].function_decl;
    try std.testing.expectEqual(@as(usize, 4), function_decl.body.statements.len);

    const let_user = function_decl.body.statements[0].let_stmt;
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Expr), .struct_init), std.meta.activeTag(let_user.value.*));

    const let_port = function_decl.body.statements[1].let_stmt;
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Expr), .match_expr), std.meta.activeTag(let_port.value.*));

    const bind_stmt = function_decl.body.statements[2].bind_stmt;
    try std.testing.expectEqual(@as(std.meta.Tag(tree.BindElseBody), .expr), std.meta.activeTag(bind_stmt.else_body));

    const return_stmt = function_decl.body.statements[3].return_stmt;
    try std.testing.expectEqual(@as(std.meta.Tag(tree.Expr), .variant), std.meta.activeTag(return_stmt.value.*));
}

test "parser rejects positional calls" {
    try expectParseError(
        \\module demo;
        \\
        \\fn main() -> Int {
        \\    return add(2, 3);
        \\}
    , "P0102");
}

test "parser requires bind else branches" {
    try expectParseError(
        \\module demo;
        \\
        \\fn main() -> Int {
        \\    bind value = parse_port(value: "3000");
        \\    return value;
        \\}
    , "P0065");
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
        \\    return Ok(Void);
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
