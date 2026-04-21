pub const Lexer = @import("lexer.zig");
pub const Parser = @import("parser.zig");
pub const Token = @import("token.zig").Token;
pub const TokenTag = @import("token.zig").Tag;
pub const Tree = @import("tree.zig");

pub const lexFile = @import("lexer.zig").lexFile;
pub const parseFile = @import("parser.zig").parseFile;

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("token.zig");
    _ = @import("tree.zig");
}
