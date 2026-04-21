const std = @import("std");
const Io = std.Io;

const manifest_mod = @import("manifest.zig");

pub const ScaffoldOptions = struct {
    package_name: []const u8,
    lib: bool = false,
};

pub const NewPackageOptions = struct {
    package_name: []const u8,
    lib: bool = false,
};

pub const ScaffoldError = error{AlreadyExists} || std.Io.Writer.Error || std.Io.Dir.WriteFileError || std.Io.Dir.CreateDirPathError || std.Io.Dir.OpenError || std.mem.Allocator.Error;

pub fn initPackage(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    options: ScaffoldOptions,
) ScaffoldError!void {
    const manifest = defaultManifest(options);
    const lockfile = manifest_mod.Lockfile{ .packages = &.{} };

    const manifest_text = try manifest_mod.renderManifestAlloc(allocator, manifest);
    defer allocator.free(manifest_text);
    const lock_text = try manifest_mod.renderLockfileAlloc(allocator, lockfile);
    defer allocator.free(lock_text);

    try dir.createDirPath(io, "src");
    try dir.writeFile(io, .{ .sub_path = "lace.toml", .data = manifest_text });
    try dir.writeFile(io, .{ .sub_path = "lace.lock", .data = lock_text });
    try dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "build/\n" });
    try dir.writeFile(io, .{
        .sub_path = if (options.lib) "src/lib.lace" else "src/main.lace",
        .data = sourceTemplate(options.lib),
    });
}

pub fn newPackage(
    allocator: std.mem.Allocator,
    io: Io,
    parent_dir: Io.Dir,
    options: NewPackageOptions,
) ScaffoldError![]const u8 {
    const dirname = try allocator.dupe(u8, packageDirName(options.package_name));
    errdefer allocator.free(dirname);

    var existing = parent_dir.openDir(io, dirname, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |*dir| {
        dir.close(io);
        return error.AlreadyExists;
    }

    var new_dir = try parent_dir.createDirPathOpen(io, dirname, .{});
    defer new_dir.close(io);
    try initPackage(allocator, io, new_dir, .{
        .package_name = options.package_name,
        .lib = options.lib,
    });
    return dirname;
}

pub fn defaultManifest(options: ScaffoldOptions) manifest_mod.Manifest {
    return .{
        .package = .{
            .name = options.package_name,
            .version = "0.1.0",
            .edition = "2026",
        },
        .dependencies = &.{},
        .build = .{
            .src = "src",
            .entry = if (options.lib) "src/lib.lace" else "src/main.lace",
        },
    };
}

fn packageDirName(package_name: []const u8) []const u8 {
    return std.fs.path.basename(package_name);
}

fn sourceTemplate(lib: bool) []const u8 {
    return if (lib)
        ("module lib;\n\n" ++
            "pub fn greet(\n" ++
            "    name: String,\n" ++
            ") -> String {\n" ++
            "    return \"hello \" + name;\n" ++
            "}\n")
    else
        ("module main;\n\n" ++
            "pub error AppError {\n" ++
            "    placeholder,\n" ++
            "}\n\n" ++
            "pub fn main() -> Result<Void, AppError> {\n" ++
            "    return Ok(Void);\n" ++
            "}\n");
}

test "initPackage writes a valid binary project scaffold" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try initPackage(std.testing.allocator, std.testing.io, tmp.dir, .{
        .package_name = "example.com/demo",
        .lib = false,
    });

    const manifest_text = try tmp.dir.readFileAlloc(std.testing.io, "lace.toml", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(manifest_text);
    var manifest = try manifest_mod.parseManifest(std.testing.allocator, manifest_text);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("example.com/demo", manifest.package.name);
    try std.testing.expectEqualStrings("src/main.lace", manifest.build.?.entry);

    const source_text = try tmp.dir.readFileAlloc(std.testing.io, "src/main.lace", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(source_text);
    try assertSourceTypechecks("src/main.lace", source_text);
}

test "initPackage writes a valid library project scaffold" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try initPackage(std.testing.allocator, std.testing.io, tmp.dir, .{
        .package_name = "example.com/libdemo",
        .lib = true,
    });

    const source_text = try tmp.dir.readFileAlloc(std.testing.io, "src/lib.lace", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(source_text);
    try assertSourceTypechecks("src/lib.lace", source_text);
}

test "newPackage creates a directory using the package basename" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dirname = try newPackage(std.testing.allocator, std.testing.io, tmp.dir, .{
        .package_name = "github.com/sam/my_app",
        .lib = false,
    });
    defer std.testing.allocator.free(dirname);

    try std.testing.expectEqualStrings("my_app", dirname);

    const manifest_text = try tmp.dir.readFileAlloc(std.testing.io, "my_app/lace.toml", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(manifest_text);
    var manifest = try manifest_mod.parseManifest(std.testing.allocator, manifest_text);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("github.com/sam/my_app", manifest.package.name);
}

fn assertSourceTypechecks(path: []const u8, contents: []const u8) !void {
    const sem = @import("../sem/mod.zig");
    const source_mod = @import("../source.zig");
    const syntax = @import("../syntax/mod.zig");
    const diag = @import("../diag/mod.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sources: source_mod.Manager = .{};
    defer sources.deinit(std.testing.allocator);
    var diagnostics: diag.Store = .{};

    const file_id = try sources.addSource(std.testing.allocator, path, contents);
    const document = try syntax.parseFile(arena, &diagnostics, sources.getFile(file_id));
    _ = try sem.typecheckDocuments(arena, &diagnostics, &sources, &.{document});
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());
}
