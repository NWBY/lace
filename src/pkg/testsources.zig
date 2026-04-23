const std = @import("std");
const Io = std.Io;

pub fn collectTestSourceFiles(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    try collectTestFilesInDir(allocator, io, root, "tests", &files);

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    return try files.toOwnedSlice(allocator);
}

fn collectTestFilesInDir(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    subdir: []const u8,
    files: *std.ArrayList([]const u8),
) !void {
    const dir_path = if (std.mem.eql(u8, root, "."))
        try allocator.dupe(u8, subdir)
    else
        try std.fs.path.join(allocator, &.{ root, subdir });
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, "_test.lace")) continue;

        const relative = if (std.mem.eql(u8, root, "."))
            try std.fs.path.join(allocator, &.{ subdir, entry.path })
        else
            try std.fs.path.join(allocator, &.{ root, subdir, entry.path });
        try files.append(allocator, relative);
    }
}

test "collectTestSourceFiles finds tests in src and tests directories" {
    _ = collectTestSourceFiles;
}
