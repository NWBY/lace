pub const validateDocument = @import("validation.zig").validateDocument;
pub const validateDocuments = @import("validation.zig").validateDocuments;
pub const Package = @import("resolution.zig").Package;
pub const resolveDocuments = @import("resolution.zig").resolveDocuments;
pub const PackageSurface = @import("types.zig").PackageSurface;
pub const Type = @import("types.zig").Type;
pub const buildPackageSurface = @import("types.zig").buildPackageSurface;
pub const lookupStdlibModule = @import("types.zig").lookupStdlibModule;
pub const resolveTypeRef = @import("types.zig").resolveTypeRef;
pub const typecheckDocuments = @import("typecheck.zig").typecheckDocuments;

test {
    _ = @import("resolution.zig");
    _ = @import("typecheck.zig");
    _ = @import("types.zig");
    _ = @import("validation.zig");
}
