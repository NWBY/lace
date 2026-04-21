const std = @import("std");
const Io = std.Io;

pub const BuildInfo = @import("manifest.zig").BuildInfo;
pub const Dependency = @import("manifest.zig").Dependency;
pub const LockPackage = @import("manifest.zig").LockPackage;
pub const Lockfile = @import("manifest.zig").Lockfile;
pub const Manifest = @import("manifest.zig").Manifest;
pub const NewPackageOptions = @import("scaffold.zig").NewPackageOptions;
pub const ScaffoldOptions = @import("scaffold.zig").ScaffoldOptions;
pub const initPackage = @import("scaffold.zig").initPackage;
pub const newPackage = @import("scaffold.zig").newPackage;
pub const parseLockfile = @import("manifest.zig").parseLockfile;
pub const parseManifest = @import("manifest.zig").parseManifest;
pub const renderLockfileAlloc = @import("manifest.zig").renderLockfileAlloc;
pub const renderManifestAlloc = @import("manifest.zig").renderManifestAlloc;

pub const SourceTarget = union(enum) {
    single_file: []const u8,
    package: PackageTarget,
};

pub const PackageTarget = struct {
    root: []const u8 = ".",
    src_dir: []const u8 = "src",
};

pub fn collectSourceFiles(
    allocator: std.mem.Allocator,
    io: ?Io,
    target: SourceTarget,
) ![]const []const u8 {
    return switch (target) {
        .single_file => |path| blk: {
            const paths = try allocator.alloc([]const u8, 1);
            paths[0] = try allocator.dupe(u8, path);
            break :blk paths;
        },
        .package => |package| collectPackageSourceFiles(allocator, io orelse return error.IoUnavailable, package),
    };
}

fn collectPackageSourceFiles(
    allocator: std.mem.Allocator,
    io: Io,
    package: PackageTarget,
) ![]const []const u8 {
    const allocated_src_path = if (std.mem.eql(u8, package.root, "."))
        null
    else
        try std.fs.path.join(allocator, &.{ package.root, package.src_dir });
    defer if (allocated_src_path) |value| allocator.free(value);

    const src_path = if (allocated_src_path) |value|
        value
    else
        package.src_dir
    ;

    var src_dir = try std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        if (!std.mem.endsWith(u8, entry.path, ".lace")) {
            continue;
        }

        const relative = if (std.mem.eql(u8, package.root, "."))
            try std.fs.path.join(allocator, &.{ package.src_dir, entry.path })
        else
            try std.fs.path.join(allocator, &.{ package.root, package.src_dir, entry.path });
        try files.append(allocator, relative);
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    return try files.toOwnedSlice(allocator);
}

test "package loader finds lace files recursively" {
    _ = collectSourceFiles;
}

test {
    _ = @import("manifest.zig");
    _ = @import("scaffold.zig");
}
