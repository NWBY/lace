pub const validateDocument = @import("validation.zig").validateDocument;
pub const validateDocuments = @import("validation.zig").validateDocuments;
pub const Package = @import("resolution.zig").Package;
pub const resolveDocuments = @import("resolution.zig").resolveDocuments;

test {
    _ = @import("resolution.zig");
    _ = @import("validation.zig");
}
