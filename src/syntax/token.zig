const source = @import("../source.zig");

pub const Tag = enum {
    eof,
    identifier,
    int_literal,
    string_literal,

    kw_module,
    kw_import,
    kw_pub,
    kw_struct,
    kw_enum,
    kw_error,
    kw_fn,
    kw_let,
    kw_const,
    kw_if,
    kw_else,
    kw_match,
    kw_return,
    kw_bind,
    kw_test,
    kw_true,
    kw_false,
    kw_none,
    kw_some,
    kw_ok,
    kw_err,

    semicolon,
    comma,
    colon,
    dot,
    slash,
    plus,
    minus,
    star,
    bang,
    eq,
    eq_eq,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    arrow,
    fat_arrow,

    l_paren,
    r_paren,
    l_brace,
    r_brace,
};

pub const Token = struct {
    tag: Tag,
    span: source.Span,

    pub fn lexeme(self: Token, file: *const source.File) []const u8 {
        return file.source[self.span.start..self.span.end];
    }
};
