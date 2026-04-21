const std = @import("std");

const diag = @import("../diag/mod.zig");
const source = @import("../source.zig");
const token = @import("token.zig");

pub const LexError = error{
    InvalidSyntax,
    OutOfMemory,
};

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    file: *const source.File,
    cursor: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        diagnostics: *diag.Store,
        file: *const source.File,
    ) Lexer {
        return .{
            .allocator = allocator,
            .diagnostics = diagnostics,
            .file = file,
        };
    }

    pub fn lex(self: *Lexer) LexError!std.ArrayList(token.Token) {
        var tokens: std.ArrayList(token.Token) = .empty;
        errdefer tokens.deinit(self.allocator);

        while (true) {
            const next_token = try self.nextToken();
            try tokens.append(self.allocator, next_token);
            if (next_token.tag == .eof) {
                return tokens;
            }
        }
    }

    fn nextToken(self: *Lexer) LexError!token.Token {
        self.skipWhitespace();

        const start = self.cursor;
        const byte = self.peek() orelse return self.makeToken(.eof, start, start);

        if (isIdentifierStart(byte)) {
            return self.lexIdentifier(start);
        }

        if (std.ascii.isDigit(byte)) {
            return self.lexInteger(start);
        }

        _ = self.advance().?;
        return switch (byte) {
            ';' => self.makeToken(.semicolon, start, self.cursor),
            ',' => self.makeToken(.comma, start, self.cursor),
            ':' => self.makeToken(.colon, start, self.cursor),
            '.' => self.makeToken(.dot, start, self.cursor),
            '/' => self.makeToken(.slash, start, self.cursor),
            '+' => self.makeToken(.plus, start, self.cursor),
            '*' => self.makeToken(.star, start, self.cursor),
            '(' => self.makeToken(.l_paren, start, self.cursor),
            ')' => self.makeToken(.r_paren, start, self.cursor),
            '{' => self.makeToken(.l_brace, start, self.cursor),
            '}' => self.makeToken(.r_brace, start, self.cursor),
            '-' => if (self.consume('>')) self.makeToken(.arrow, start, self.cursor) else self.makeToken(.minus, start, self.cursor),
            '!' => if (self.consume('=')) self.makeToken(.bang_eq, start, self.cursor) else self.makeToken(.bang, start, self.cursor),
            '=' => if (self.consume('=')) self.makeToken(.eq_eq, start, self.cursor) else if (self.consume('>')) self.makeToken(.fat_arrow, start, self.cursor) else self.makeToken(.eq, start, self.cursor),
            '<' => if (self.consume('=')) self.makeToken(.lt_eq, start, self.cursor) else self.makeToken(.lt, start, self.cursor),
            '>' => if (self.consume('=')) self.makeToken(.gt_eq, start, self.cursor) else self.makeToken(.gt, start, self.cursor),
            '"' => self.lexString(start),
            else => self.reportError(
                "E0001",
                "Unexpected character",
                start,
                self.cursor,
            ),
        };
    }

    fn lexIdentifier(self: *Lexer, start: usize) token.Token {
        while (self.peek()) |byte| {
            if (!isIdentifierContinue(byte)) {
                break;
            }

            _ = self.advance();
        }

        const lexeme = self.file.source[start..self.cursor];
        const tag = keywordTag(lexeme) orelse .identifier;
        return self.makeToken(tag, start, self.cursor);
    }

    fn lexInteger(self: *Lexer, start: usize) token.Token {
        while (self.peek()) |byte| {
            if (!std.ascii.isDigit(byte)) {
                break;
            }

            _ = self.advance();
        }

        return self.makeToken(.int_literal, start, self.cursor);
    }

    fn lexString(self: *Lexer, start: usize) LexError!token.Token {
        while (self.peek()) |byte| {
            switch (byte) {
                '"' => {
                    _ = self.advance().?;
                    return self.makeToken(.string_literal, start, self.cursor);
                },
                '\n', '\r' => {
                    return self.reportError(
                        "E0002",
                        "Unterminated string literal",
                        start,
                        self.cursor,
                    );
                },
                '\\' => {
                    _ = self.advance().?;
                    if (self.peek() == null) {
                        return self.reportError(
                            "E0002",
                            "Unterminated string literal",
                            start,
                            self.cursor,
                        );
                    }
                    _ = self.advance().?;
                },
                else => _ = self.advance().?,
            }
        }

        return self.reportError(
            "E0002",
            "Unterminated string literal",
            start,
            self.cursor,
        );
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\n', '\r', '\t' => _ = self.advance().?,
                else => return,
            }
        }
    }

    fn makeToken(self: *const Lexer, tag: token.Tag, start: usize, end: usize) token.Token {
        return .{
            .tag = tag,
            .span = source.Span.init(self.file.id, start, end),
        };
    }

    fn reportError(
        self: *Lexer,
        code: []const u8,
        message: []const u8,
        start: usize,
        end: usize,
    ) LexError {
        self.diagnostics.append(self.allocator, .{
            .code = code,
            .message = message,
            .span = source.Span.init(self.file.id, start, end),
        }) catch return error.OutOfMemory;
        return error.InvalidSyntax;
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.cursor >= self.file.source.len) {
            return null;
        }

        return self.file.source[self.cursor];
    }

    fn advance(self: *Lexer) ?u8 {
        const byte = self.peek() orelse return null;
        self.cursor += 1;
        return byte;
    }

    fn consume(self: *Lexer, expected: u8) bool {
        if (self.peek() != expected) {
            return false;
        }

        _ = self.advance();
        return true;
    }
};

pub fn lexFile(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    file: *const source.File,
) LexError!std.ArrayList(token.Token) {
    var lexer = Lexer.init(allocator, diagnostics, file);
    return lexer.lex();
}

fn keywordTag(lexeme: []const u8) ?token.Tag {
    if (std.mem.eql(u8, lexeme, "module")) return .kw_module;
    if (std.mem.eql(u8, lexeme, "import")) return .kw_import;
    if (std.mem.eql(u8, lexeme, "pub")) return .kw_pub;
    if (std.mem.eql(u8, lexeme, "struct")) return .kw_struct;
    if (std.mem.eql(u8, lexeme, "enum")) return .kw_enum;
    if (std.mem.eql(u8, lexeme, "error")) return .kw_error;
    if (std.mem.eql(u8, lexeme, "fn")) return .kw_fn;
    if (std.mem.eql(u8, lexeme, "let")) return .kw_let;
    if (std.mem.eql(u8, lexeme, "const")) return .kw_const;
    if (std.mem.eql(u8, lexeme, "if")) return .kw_if;
    if (std.mem.eql(u8, lexeme, "else")) return .kw_else;
    if (std.mem.eql(u8, lexeme, "match")) return .kw_match;
    if (std.mem.eql(u8, lexeme, "return")) return .kw_return;
    if (std.mem.eql(u8, lexeme, "bind")) return .kw_bind;
    if (std.mem.eql(u8, lexeme, "test")) return .kw_test;
    if (std.mem.eql(u8, lexeme, "true")) return .kw_true;
    if (std.mem.eql(u8, lexeme, "false")) return .kw_false;
    if (std.mem.eql(u8, lexeme, "None")) return .kw_none;
    if (std.mem.eql(u8, lexeme, "Some")) return .kw_some;
    if (std.mem.eql(u8, lexeme, "Ok")) return .kw_ok;
    if (std.mem.eql(u8, lexeme, "Err")) return .kw_err;
    return null;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

test "lexer tokenizes canonical Lace syntax" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/demo.lace",
        \\module app/signup;
        \\pub fn add(
        \\    a: Int,
        \\    b: Int,
        \\) -> Int {
        \\    return add(
        \\        a: 2,
        \\        b: 3,
        \\    );
        \\}
    );

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const file = sources.getFile(file_id);
    var tokens = try lexFile(std.testing.allocator, &diagnostics, file);
    defer tokens.deinit(std.testing.allocator);

    const expected = [_]token.Tag{
        .kw_module,
        .identifier,
        .slash,
        .identifier,
        .semicolon,
        .kw_pub,
        .kw_fn,
        .identifier,
        .l_paren,
        .identifier,
        .colon,
        .identifier,
        .comma,
        .identifier,
        .colon,
        .identifier,
        .comma,
        .r_paren,
        .arrow,
        .identifier,
        .l_brace,
        .kw_return,
        .identifier,
        .l_paren,
        .identifier,
        .colon,
        .int_literal,
        .comma,
        .identifier,
        .colon,
        .int_literal,
        .comma,
        .r_paren,
        .semicolon,
        .r_brace,
        .eof,
    };

    try std.testing.expectEqual(expected.len, tokens.items.len);
    for (expected, tokens.items) |expected_tag, actual_token| {
        try std.testing.expectEqual(expected_tag, actual_token.tag);
    }

    try std.testing.expectEqualStrings("app", tokens.items[1].lexeme(file));
    try std.testing.expectEqualStrings("add", tokens.items[7].lexeme(file));
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "lexer reports unexpected characters" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/bad.lace",
        "let value = @;\n",
    );

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const file = sources.getFile(file_id);
    try std.testing.expectError(error.InvalidSyntax, lexFile(std.testing.allocator, &diagnostics, file));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.count());
    try std.testing.expectEqualStrings("E0001", diagnostics.items.items[0].code);
}

test "lexer reports unterminated strings" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/bad_string.lace",
        "let name = \"sam\n",
    );

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const file = sources.getFile(file_id);
    try std.testing.expectError(error.InvalidSyntax, lexFile(std.testing.allocator, &diagnostics, file));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.count());
    try std.testing.expectEqualStrings("E0002", diagnostics.items.items[0].code);
}
