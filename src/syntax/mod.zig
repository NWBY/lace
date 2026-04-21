pub const Lexer = @import("lexer.zig");
pub const Parser = @import("parser.zig");
pub const Token = @import("token.zig").Token;
pub const TokenTag = @import("token.zig").Tag;
pub const Tree = @import("tree.zig");

pub const formatDocument = @import("format.zig").formatDocument;
pub const formatDocumentAlloc = @import("format.zig").formatDocumentAlloc;
pub const renderAstJson = @import("ast_json.zig").renderJson;
pub const lexFile = @import("lexer.zig").lexFile;
pub const parseFile = @import("parser.zig").parseFile;

test {
    _ = @import("ast_json.zig");
    _ = @import("format.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("token.zig");
    _ = @import("tree.zig");
}
