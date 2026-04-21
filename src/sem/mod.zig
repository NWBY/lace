pub const validateDocument = @import("validation.zig").validateDocument;
pub const validateDocuments = @import("validation.zig").validateDocuments;

test {
    _ = @import("validation.zig");
}
