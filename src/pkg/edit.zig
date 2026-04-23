const std = @import("std");
const Io = std.Io;

const deps = @import("deps.zig");
const diag = @import("../diag/mod.zig");
const manifest_mod = @import("manifest.zig");

pub const EditError = anyerror;

pub fn addDependency(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    package_root: []const u8,
    spec: []const u8,
    roots: deps.DependencyRoots,
) EditError!bool {
    var manifest = try readManifestFromRoot(allocator, io, package_root);
    defer manifest.deinit(allocator);

    const parsed = try parseDependencySpec(spec);

    var changed = false;
    for (manifest.dependencies, 0..) |dependency, index| {
        if (!std.mem.eql(u8, dependency.name, parsed.name)) continue;
        if (!std.mem.eql(u8, dependency.version, parsed.version)) {
            const new_dependencies = try allocator.alloc(manifest_mod.Dependency, manifest.dependencies.len);
            @memcpy(new_dependencies, manifest.dependencies);
            allocator.free(new_dependencies[index].version);
            new_dependencies[index].version = try allocator.dupe(u8, parsed.version);
            allocator.free(manifest.dependencies);
            manifest.dependencies = new_dependencies;
            changed = true;
        }
        return try finishManifestUpdate(allocator, diagnostics, io, package_root, roots, &manifest, changed);
    }

    const new_dependencies = try allocator.alloc(manifest_mod.Dependency, manifest.dependencies.len + 1);
    @memcpy(new_dependencies[0..manifest.dependencies.len], manifest.dependencies);
    allocator.free(manifest.dependencies);
    new_dependencies[manifest.dependencies.len] = .{
        .name = try allocator.dupe(u8, parsed.name),
        .version = try allocator.dupe(u8, parsed.version),
    };
    manifest.dependencies = new_dependencies;
    return try finishManifestUpdate(allocator, diagnostics, io, package_root, roots, &manifest, true);
}

pub fn removeDependency(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    package_root: []const u8,
    name: []const u8,
    roots: deps.DependencyRoots,
) EditError!bool {
    var manifest = try readManifestFromRoot(allocator, io, package_root);
    defer manifest.deinit(allocator);

    const index = dependencyIndex(manifest.dependencies, name) orelse return false;

    allocator.free(manifest.dependencies[index].name);
    allocator.free(manifest.dependencies[index].version);

    const new_len = manifest.dependencies.len - 1;
    const new_dependencies = try allocator.alloc(manifest_mod.Dependency, new_len);
    if (index > 0) {
        @memcpy(new_dependencies[0..index], manifest.dependencies[0..index]);
    }
    if (index < new_len) {
        @memcpy(new_dependencies[index..], manifest.dependencies[index + 1 ..]);
    }
    allocator.free(manifest.dependencies);
    manifest.dependencies = new_dependencies;

    return try finishManifestUpdate(allocator, diagnostics, io, package_root, roots, &manifest, true);
}

pub fn updateDependencies(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    package_root: []const u8,
    roots: deps.DependencyRoots,
) EditError!bool {
    var result = (try deps.fetchDependencies(allocator, diagnostics, io, package_root, roots)) orelse return false;
    defer result.deinit(allocator);
    return diagnostics.count() == 0;
}

pub fn cleanBuildArtifacts(io: Io, package_root: []const u8) EditError!bool {
    const build_path = if (std.mem.eql(u8, package_root, "."))
        "build"
    else
        try std.fs.path.join(std.heap.page_allocator, &.{ package_root, "build" });
    defer if (!std.mem.eql(u8, package_root, ".")) std.heap.page_allocator.free(build_path);

    var maybe_dir = std.Io.Dir.cwd().openDir(io, build_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
    if (maybe_dir == null) return false;
    maybe_dir.?.close(io);
    try std.Io.Dir.cwd().deleteTree(io, build_path);
    return true;
}

fn finishManifestUpdate(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    package_root: []const u8,
    roots: deps.DependencyRoots,
    manifest: *manifest_mod.Manifest,
    changed: bool,
) EditError!bool {
    if (changed) {
        const text = try manifest_mod.renderManifestAlloc(allocator, manifest.*);
        defer allocator.free(text);
        const path = try std.fs.path.join(allocator, &.{ package_root, "lace.toml" });
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    }

    var result = (try deps.fetchDependencies(allocator, diagnostics, io, package_root, roots)) orelse return false;
    defer result.deinit(allocator);
    return true;
}

fn readManifestFromRoot(allocator: std.mem.Allocator, io: Io, package_root: []const u8) EditError!manifest_mod.Manifest {
    const path = try std.fs.path.join(allocator, &.{ package_root, "lace.toml" });
    defer allocator.free(path);
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(contents);
    return try manifest_mod.parseManifest(allocator, contents);
}

fn parseDependencySpec(spec: []const u8) EditError!struct { name: []const u8, version: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return error.InvalidDependencySpec;
    if (at == 0 or at == spec.len - 1) return error.InvalidDependencySpec;
    return .{ .name = spec[0..at], .version = spec[at + 1 ..] };
}

fn dependencyIndex(dependencies: []const manifest_mod.Dependency, name: []const u8) ?usize {
    for (dependencies, 0..) |dependency, index| {
        if (std.mem.eql(u8, dependency.name, name)) return index;
    }
    return null;
}

test "addDependency writes manifest and lock deterministically" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/store/0.4.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/store\"\nversion = \"0.4.0\"\nedition = \"2026\"\n\n[dependencies]\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/src/lib.lace", .data =
        "module lib;\n\npub fn noop() -> Void {\n    return Void;\n}\n" });
    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/lace.toml", .data =
        "[package]\nname = \"github.com/sam/app\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\n[build]\nsrc = \"src\"\nentry = \"src/main.lace\"\n" });

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const cache_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "cache" });
    defer std.testing.allocator.free(cache_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "app" });
    defer std.testing.allocator.free(app_root);

    const changed = try addDependency(std.testing.allocator, &diagnostics, std.testing.io, app_root, "github.com/sam/store@0.4.0", .{
        .registry_root = registry_root,
        .cache_root = cache_root,
    });
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());

    const manifest_text = try tmp.dir.readFileAlloc(std.testing.io, "app/lace.toml", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(manifest_text);
    try std.testing.expect(std.mem.indexOf(u8, manifest_text, "\"github.com/sam/store\" = \"0.4.0\"") != null);

    const lock_text = try tmp.dir.readFileAlloc(std.testing.io, "app/lace.lock", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(lock_text);
    try std.testing.expect(std.mem.indexOf(u8, lock_text, "github.com/sam/store") != null);
}

test "removeDependency updates manifest and lock and no-ops when missing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/store/0.4.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/store\"\nversion = \"0.4.0\"\nedition = \"2026\"\n\n[dependencies]\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/src/lib.lace", .data =
        "module lib;\n\npub fn noop() -> Void {\n    return Void;\n}\n" });
    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/lace.toml", .data =
        "[package]\nname = \"github.com/sam/app\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/store\" = \"0.4.0\"\n\n[build]\nsrc = \"src\"\nentry = \"src/main.lace\"\n" });

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const cache_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "cache" });
    defer std.testing.allocator.free(cache_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "app" });
    defer std.testing.allocator.free(app_root);

    try std.testing.expect(try removeDependency(std.testing.allocator, &diagnostics, std.testing.io, app_root, "github.com/sam/store", .{
        .registry_root = registry_root,
        .cache_root = cache_root,
    }));
    const manifest_text = try tmp.dir.readFileAlloc(std.testing.io, "app/lace.toml", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(manifest_text);
    try std.testing.expect(std.mem.indexOf(u8, manifest_text, "github.com/sam/store") == null);

    const lock_text = try tmp.dir.readFileAlloc(std.testing.io, "app/lace.lock", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(lock_text);
    try std.testing.expectEqualStrings("", lock_text);

    try std.testing.expect(!(try removeDependency(std.testing.allocator, &diagnostics, std.testing.io, app_root, "github.com/sam/missing", .{
        .registry_root = registry_root,
        .cache_root = cache_root,
    })));
}

test "updateDependencies refreshes lockfile and cleanBuildArtifacts removes build output" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/store/0.4.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/store\"\nversion = \"0.4.0\"\nedition = \"2026\"\n\n[dependencies]\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/src/lib.lace", .data =
        "module lib;\n\npub fn noop() -> Void {\n    return Void;\n}\n" });
    try tmp.dir.createDirPath(std.testing.io, "app/build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/lace.toml", .data =
        "[package]\nname = \"github.com/sam/app\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/store\" = \"0.4.0\"\n\n[build]\nsrc = \"src\"\nentry = \"src/main.lace\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/build/program.json", .data = "{}" });

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);
    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const cache_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "cache" });
    defer std.testing.allocator.free(cache_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "app" });
    defer std.testing.allocator.free(app_root);

    try std.testing.expect(try updateDependencies(std.testing.allocator, &diagnostics, std.testing.io, app_root, .{
        .registry_root = registry_root,
        .cache_root = cache_root,
    }));

    const lock_text = try tmp.dir.readFileAlloc(std.testing.io, "app/lace.lock", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(lock_text);
    try std.testing.expect(std.mem.indexOf(u8, lock_text, "sha256:") != null);

    try std.testing.expect(try cleanBuildArtifacts(std.testing.io, app_root));
    const build_file = tmp.dir.readFileAlloc(std.testing.io, "app/build/program.json", std.testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try std.testing.expect(build_file == null);
    try std.testing.expect(!(try cleanBuildArtifacts(std.testing.io, app_root)));
}
