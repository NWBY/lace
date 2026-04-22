const std = @import("std");
const Io = std.Io;

const diag = @import("../diag/mod.zig");
const manifest_mod = @import("manifest.zig");

pub const DependencyRoots = struct {
    registry_root: []const u8,
    cache_root: []const u8,
};

pub const WorkspaceSource = struct {
    actual_path: []const u8,
    logical_path: []const u8,
};

pub const ResolvedPackage = struct {
    name: []const u8,
    version: []const u8,
    checksum: []const u8,
    registry_path: []const u8,
    cache_path: []const u8,
};

pub const FetchResult = struct {
    lockfile: manifest_mod.Lockfile,
    packages: []const ResolvedPackage,

    pub fn deinit(self: *FetchResult, allocator: std.mem.Allocator) void {
        for (self.packages) |package| {
            allocator.free(package.name);
            allocator.free(package.version);
            allocator.free(package.checksum);
            allocator.free(package.registry_path);
            allocator.free(package.cache_path);
        }
        allocator.free(self.packages);
        allocator.free(self.lockfile.packages);
        self.* = undefined;
    }
};

pub fn defaultDependencyRoots(allocator: std.mem.Allocator) !DependencyRoots {
    const home_ptr = std.c.getenv("HOME") orelse return error.MissingHome;
    const home = std.mem.span(home_ptr);
    return .{
        .registry_root = try std.fs.path.join(allocator, &.{ home, ".lace", "registry" }),
        .cache_root = try std.fs.path.join(allocator, &.{ home, ".lace", "pkg" }),
    };
}

pub fn fetchDependencies(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    package_root: []const u8,
    roots: DependencyRoots,
) !?FetchResult {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp = temp_arena.allocator();

    var manifest = readManifestFromRoot(temp, io, package_root) catch |err| switch (err) {
        error.FileNotFound => {
            try diagnostics.append(allocator, .{
                .code = "P1501",
                .message = "Package manifest `lace.toml` was not found",
            });
            return null;
        },
        else => return err,
    };
    defer manifest.deinit(temp);

    var packages: std.ArrayList(ResolvedPackage) = .empty;
    var version_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;

    for (manifest.dependencies) |dependency| {
        const ok = try resolveDependency(
            allocator,
            temp,
            diagnostics,
            io,
            roots,
            dependency,
            &packages,
            &version_map,
            &visited,
        );
        if (!ok) {
            freeResolvedPackages(allocator, packages.items);
            packages.deinit(allocator);
            return null;
        }
    }

    const lock_packages = try allocator.alloc(manifest_mod.LockPackage, packages.items.len);
    for (packages.items, 0..) |package, index| {
        lock_packages[index] = .{
            .name = package.name,
            .version = package.version,
            .checksum = package.checksum,
        };
    }

    const lockfile = manifest_mod.Lockfile{ .packages = lock_packages };
    const lock_text = try manifest_mod.renderLockfileAlloc(allocator, lockfile);
    defer allocator.free(lock_text);

    const lock_path = try std.fs.path.join(allocator, &.{ package_root, "lace.lock" });
    defer allocator.free(lock_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = lock_text });

    for (packages.items) |package| {
        try cachePackage(allocator, io, roots, package);
    }

    return .{
        .lockfile = lockfile,
        .packages = try packages.toOwnedSlice(allocator),
    };
}

pub fn collectWorkspaceSourceFiles(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    package: @import("mod.zig").PackageTarget,
    roots: DependencyRoots,
) ![]const []const u8 {
    const sources = try collectWorkspaceSources(allocator, diagnostics, io, package, roots);
    const paths = try allocator.alloc([]const u8, sources.len);
    for (sources, 0..) |entry, index| {
        paths[index] = entry.logical_path;
    }
    return paths;
}

pub fn collectWorkspaceSources(
    allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    package: @import("mod.zig").PackageTarget,
    roots: DependencyRoots,
) ![]const WorkspaceSource {
    const root_files = try @import("mod.zig").collectSourceFiles(allocator, io, .{ .package = package });
    var manifest = readManifestFromRoot(allocator, io, package.root) catch |err| switch (err) {
        error.FileNotFound => {
            const sources = try allocator.alloc(WorkspaceSource, root_files.len);
            for (root_files, 0..) |path, index| {
                sources[index] = .{ .actual_path = path, .logical_path = path };
            }
            return sources;
        },
        else => return err,
    };
    defer manifest.deinit(allocator);

    if (manifest.dependencies.len == 0) {
        const sources = try allocator.alloc(WorkspaceSource, root_files.len);
        for (root_files, 0..) |path, index| {
            sources[index] = .{ .actual_path = path, .logical_path = path };
        }
        return sources;
    }

    var lockfile = readLockfileFromRoot(allocator, io, package.root) catch |err| switch (err) {
        error.FileNotFound => {
            try diagnostics.append(allocator, .{
                .code = "P1505",
                .message = "Dependencies are declared but `lace.lock` is missing; run `lace fetch`",
            });
            const sources = try allocator.alloc(WorkspaceSource, root_files.len);
            for (root_files, 0..) |path, index| {
                sources[index] = .{ .actual_path = path, .logical_path = path };
            }
            return sources;
        },
        else => return err,
    };
    defer lockfile.deinit(allocator);

    var files: std.ArrayList(WorkspaceSource) = .empty;
    for (root_files) |path| {
        try files.append(allocator, .{ .actual_path = path, .logical_path = path });
    }

    for (manifest.dependencies) |dependency| {
        const locked = findLockedPackage(lockfile.packages, dependency.name) orelse {
            try diagnostics.append(allocator, .{
                .code = "P1505",
                .message = "Dependency lockfile is missing a declared dependency",
            });
            continue;
        };

        if (!std.mem.eql(u8, locked.version, dependency.version)) {
            try diagnostics.append(allocator, .{
                .code = "P1505",
                .message = "Dependency lockfile is out of date",
            });
            continue;
        }

        const cache_package_root = try packageVersionPath(allocator, roots.cache_root, locked.name, locked.version);
        defer allocator.free(cache_package_root);

        const dep_files = @import("mod.zig").collectSourceFiles(allocator, io, .{ .package = .{ .root = cache_package_root } }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => {
                try diagnostics.append(allocator, .{
                    .code = "P1506",
                    .message = "Dependency package is not cached; run `lace fetch`",
                });
                continue;
            },
            else => return err,
        };
        for (dep_files) |dep_path| {
            const logical = try logicalDependencyPath(allocator, locked.name, dep_path);
            try files.append(allocator, .{
                .actual_path = dep_path,
                .logical_path = logical,
            });
        }
    }

    return try files.toOwnedSlice(allocator);
}

fn resolveDependency(
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    diagnostics: *diag.Store,
    io: Io,
    roots: DependencyRoots,
    dependency: manifest_mod.Dependency,
    packages: *std.ArrayList(ResolvedPackage),
    version_map: *std.StringHashMapUnmanaged([]const u8),
    visited: *std.StringHashMapUnmanaged(void),
) !bool {
    if (version_map.get(dependency.name)) |existing_version| {
        if (!std.mem.eql(u8, existing_version, dependency.version)) {
            try diagnostics.append(allocator, .{
                .code = "P1503",
                .message = "Dependency graph contains conflicting exact versions",
            });
            return false;
        }
    } else {
        try version_map.put(
            temp_allocator,
            try temp_allocator.dupe(u8, dependency.name),
            try temp_allocator.dupe(u8, dependency.version),
        );
    }

    const visit_key = try std.fmt.allocPrint(temp_allocator, "{s}@{s}", .{ dependency.name, dependency.version });
    const visit_entry = try visited.getOrPut(temp_allocator, visit_key);
    if (visit_entry.found_existing) {
        return true;
    }

    const registry_path = try packageVersionPath(allocator, roots.registry_root, dependency.name, dependency.version);
    defer allocator.free(registry_path);

    var manifest = readManifestFromRoot(temp_allocator, io, registry_path) catch |err| switch (err) {
        error.FileNotFound => {
            try diagnostics.append(allocator, .{
                .code = "P1502",
                .message = "Dependency package was not found in the registry source tree",
            });
            return false;
        },
        else => return err,
    };
    defer manifest.deinit(temp_allocator);

    if (!std.mem.eql(u8, manifest.package.name, dependency.name) or !std.mem.eql(u8, manifest.package.version, dependency.version)) {
        try diagnostics.append(allocator, .{
            .code = "P1504",
            .message = "Dependency manifest does not match the requested package identity",
        });
        return false;
    }

    for (manifest.dependencies) |child| {
        const ok = try resolveDependency(allocator, temp_allocator, diagnostics, io, roots, child, packages, version_map, visited);
        if (!ok) {
            return false;
        }
    }

    const cache_path = try packageVersionPath(allocator, roots.cache_root, dependency.name, dependency.version);
    defer allocator.free(cache_path);
    const checksum = try computePackageChecksum(allocator, io, registry_path);

    try packages.append(allocator, .{
        .name = try allocator.dupe(u8, dependency.name),
        .version = try allocator.dupe(u8, dependency.version),
        .checksum = checksum,
        .registry_path = try allocator.dupe(u8, registry_path),
        .cache_path = try allocator.dupe(u8, cache_path),
    });
    return true;
}

fn cachePackage(
    allocator: std.mem.Allocator,
    io: Io,
    roots: DependencyRoots,
    package: ResolvedPackage,
) !void {
    _ = roots;
    try std.Io.Dir.cwd().createDirPath(io, package.cache_path);

    var source_dir = try std.Io.Dir.cwd().openDir(io, package.registry_path, .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const destination_path = try std.fs.path.join(allocator, &.{ package.cache_path, entry.path });
        defer allocator.free(destination_path);

        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, destination_path),
            .file => {
                const source_path = try std.fs.path.join(allocator, &.{ package.registry_path, entry.path });
                defer allocator.free(source_path);
                const contents = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .unlimited);
                defer allocator.free(contents);
                const parent = std.fs.path.dirname(destination_path);
                if (parent) |parent_path| {
                    try std.Io.Dir.cwd().createDirPath(io, parent_path);
                }
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination_path, .data = contents });
            },
            else => {},
        }
    }
}

fn computePackageChecksum(allocator: std.mem.Allocator, io: Io, package_root: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, package_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) {
            try paths.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths.items) |path| {
        hasher.update(path);
        hasher.update(&.{0});
        const full_path = try std.fs.path.join(allocator, &.{ package_root, path });
        defer allocator.free(full_path);
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited);
        defer allocator.free(contents);
        hasher.update(contents);
        hasher.update(&.{0});
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn readManifestFromRoot(allocator: std.mem.Allocator, io: Io, root: []const u8) !manifest_mod.Manifest {
    const path = try std.fs.path.join(allocator, &.{ root, "lace.toml" });
    defer allocator.free(path);
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(contents);
    return try manifest_mod.parseManifest(allocator, contents);
}

fn readLockfileFromRoot(allocator: std.mem.Allocator, io: Io, root: []const u8) !manifest_mod.Lockfile {
    const path = try std.fs.path.join(allocator, &.{ root, "lace.lock" });
    defer allocator.free(path);
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(contents);
    return try manifest_mod.parseLockfile(allocator, contents);
}

fn packageVersionPath(allocator: std.mem.Allocator, root: []const u8, name: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, name, version });
}

fn logicalDependencyPath(allocator: std.mem.Allocator, package_name: []const u8, actual_path: []const u8) ![]const u8 {
    const marker = "/src/";
    const start = std.mem.lastIndexOf(u8, actual_path, marker) orelse return allocator.dupe(u8, actual_path);
    return std.fs.path.join(allocator, &.{ "src", package_name, actual_path[start + marker.len ..] });
}

fn findLockedPackage(packages: []const manifest_mod.LockPackage, name: []const u8) ?manifest_mod.LockPackage {
    for (packages) |package| {
        if (std.mem.eql(u8, package.name, name)) {
            return package;
        }
    }
    return null;
}

fn freeResolvedPackages(allocator: std.mem.Allocator, packages: []const ResolvedPackage) void {
    for (packages) |package| {
        allocator.free(package.name);
        allocator.free(package.version);
        allocator.free(package.checksum);
        allocator.free(package.registry_path);
        allocator.free(package.cache_path);
    }
}

test "fetchDependencies populates cache and lockfile deterministically" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/store/0.4.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/store\"\nversion = \"0.4.0\"\nedition = \"2026\"\n\n[dependencies]\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/store/0.4.0/src/lib.lace", .data =
        "module store;\n\npub struct Store {\n    name: String,\n}\n" });

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

    var result = (try fetchDependencies(std.testing.allocator, &diagnostics, std.testing.io, app_root, .{
        .registry_root = registry_root,
        .cache_root = cache_root,
    })).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());
    try std.testing.expectEqual(@as(usize, 1), result.lockfile.packages.len);

    const lock_text = try tmp.dir.readFileAlloc(std.testing.io, "app/lace.lock", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(lock_text);
    try std.testing.expect(std.mem.indexOf(u8, lock_text, "github.com/sam/store") != null);

    const cached_manifest = try tmp.dir.readFileAlloc(std.testing.io, "cache/github.com/sam/store/0.4.0/lace.toml", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(cached_manifest);
    try std.testing.expect(std.mem.indexOf(u8, cached_manifest, "github.com/sam/store") != null);
}

test "fetchDependencies reports missing packages and conflicts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/a/1.0.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/a/1.0.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/a\"\nversion = \"1.0.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/c\" = \"1.0.0\"\n" });
    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/b/1.0.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/b/1.0.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/b\"\nversion = \"1.0.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/c\" = \"2.0.0\"\n" });
    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/c/1.0.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/c/1.0.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/c\"\nversion = \"1.0.0\"\nedition = \"2026\"\n\n[dependencies]\n" });

    try tmp.dir.createDirPath(std.testing.io, "conflict");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "conflict/lace.toml", .data =
        "[package]\nname = \"github.com/sam/root\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/a\" = \"1.0.0\"\n\"github.com/sam/b\" = \"1.0.0\"\n" });

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);

    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const cache_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "cache" });
    defer std.testing.allocator.free(cache_root);
    const conflict_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "conflict" });
    defer std.testing.allocator.free(conflict_root);

    const conflict_result = try fetchDependencies(std.testing.allocator, &diagnostics, std.testing.io, conflict_root, .{ .registry_root = registry_root, .cache_root = cache_root });
    try std.testing.expect(conflict_result == null);
    try std.testing.expectEqualStrings("P1503", diagnostics.items.items[0].code);

    diagnostics.clearRetainingCapacity();
    try tmp.dir.createDirPath(std.testing.io, "missing");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "missing/lace.toml", .data =
        "[package]\nname = \"github.com/sam/root\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/missing\" = \"9.9.9\"\n" });
    const missing_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "missing" });
    defer std.testing.allocator.free(missing_root);
    const missing_result = try fetchDependencies(std.testing.allocator, &diagnostics, std.testing.io, missing_root, .{ .registry_root = registry_root, .cache_root = cache_root });
    try std.testing.expect(missing_result == null);
    try std.testing.expectEqualStrings("P1502", diagnostics.items.items[0].code);
}

test "workspace loading includes fetched dependency sources for cross-package imports" {
    const sem = @import("../sem/mod.zig");
    const source_mod = @import("../source.zig");
    const syntax = @import("../syntax/mod.zig");

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/user/0.1.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/user/0.1.0/lace.toml", .data =
        "[package]\nname = \"github.com/sam/user\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/user/0.1.0/src/model.lace", .data =
        "module github.com/sam/user/model;\n\npub struct User {\n    name: String,\n}\n\npub fn make(\n    name: String,\n) -> User {\n    return User{\n        name: name,\n    };\n}\n" });

    try tmp.dir.createDirPath(std.testing.io, "app/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/lace.toml", .data =
        "[package]\nname = \"github.com/sam/app\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/user\" = \"0.1.0\"\n\n[build]\nsrc = \"src\"\nentry = \"src/main.lace\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/src/main.lace", .data =
        "module main;\n\nimport github.com/sam/user/model;\n\nfn main() -> model.User {\n    return model.make(name: \"Sam\");\n}\n" });

    var diagnostics: diag.Store = .{};
    defer diagnostics.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const registry_root = try std.fs.path.join(arena, &.{ tmp_root, "registry" });
    const cache_root = try std.fs.path.join(arena, &.{ tmp_root, "cache" });
    const app_root = try std.fs.path.join(arena, &.{ tmp_root, "app" });

    var fetched = (try fetchDependencies(std.testing.allocator, &diagnostics, std.testing.io, app_root, .{
        .registry_root = registry_root,
        .cache_root = cache_root,
    })).?;
    defer fetched.deinit(std.testing.allocator);

    const entries = try collectWorkspaceSources(arena, &diagnostics, std.testing.io, .{ .root = app_root }, .{
        .registry_root = registry_root,
        .cache_root = cache_root,
    });

    var sources: source_mod.Manager = .{};
    defer sources.deinit(std.testing.allocator);
    var documents = std.ArrayList(syntax.Tree.Document).empty;

    for (entries) |entry| {
        const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, entry.actual_path, arena, .unlimited);
        const file_id = try sources.addSource(std.testing.allocator, entry.logical_path, contents);
        const document = try syntax.parseFile(arena, &diagnostics, sources.getFile(file_id));
        try documents.append(arena, document);
    }

    _ = try sem.typecheckDocuments(arena, &diagnostics, &sources, documents.items);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.count());
}
