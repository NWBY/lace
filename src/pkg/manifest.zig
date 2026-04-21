const std = @import("std");

pub const Dependency = struct {
    name: []const u8,
    version: []const u8,
};

pub const BuildInfo = struct {
    src: []const u8,
    entry: []const u8,
};

pub const Manifest = struct {
    package: struct {
        name: []const u8,
        version: []const u8,
        edition: []const u8,
    },
    dependencies: []const Dependency,
    build: ?BuildInfo = null,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.package.name);
        allocator.free(self.package.version);
        allocator.free(self.package.edition);
        for (self.dependencies) |dependency| {
            allocator.free(dependency.name);
            allocator.free(dependency.version);
        }
        allocator.free(self.dependencies);
        if (self.build) |build| {
            allocator.free(build.src);
            allocator.free(build.entry);
        }
        self.* = undefined;
    }
};

pub const LockPackage = struct {
    name: []const u8,
    version: []const u8,
    checksum: []const u8,
};

pub const Lockfile = struct {
    packages: []const LockPackage,

    pub fn deinit(self: *Lockfile, allocator: std.mem.Allocator) void {
        for (self.packages) |package| {
            allocator.free(package.name);
            allocator.free(package.version);
            allocator.free(package.checksum);
        }
        allocator.free(self.packages);
        self.* = undefined;
    }
};

pub const ParseError = error{
    DuplicateKey,
    InvalidLine,
    InvalidSection,
    InvalidString,
    MissingField,
    MissingSection,
    UnexpectedSection,
    UnknownKey,
};

pub fn parseManifest(allocator: std.mem.Allocator, contents: []const u8) !Manifest {
    var parser = LineParser.init(allocator, contents);
    var dependencies: std.ArrayList(Dependency) = .empty;
    errdefer {
        for (dependencies.items) |dependency| {
            allocator.free(dependency.name);
            allocator.free(dependency.version);
        }
        dependencies.deinit(allocator);
    }

    var section: Section = .none;
    var package_name: ?[]const u8 = null;
    var package_version: ?[]const u8 = null;
    var package_edition: ?[]const u8 = null;
    var build_src: ?[]const u8 = null;
    var build_entry: ?[]const u8 = null;
    var saw_package = false;

    while (parser.nextLine()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        if (line[0] == '[') {
            section = parseSection(line) catch return error.InvalidSection;
            if (section == .package) {
                saw_package = true;
            }
            continue;
        }

        const key, const value = parseAssignment(line) catch return error.InvalidLine;
        switch (section) {
            .package => {
                if (std.mem.eql(u8, key, "name")) {
                    if (package_name != null) return error.DuplicateKey;
                    package_name = try parseTomlString(allocator, value);
                } else if (std.mem.eql(u8, key, "version")) {
                    if (package_version != null) return error.DuplicateKey;
                    package_version = try parseTomlString(allocator, value);
                } else if (std.mem.eql(u8, key, "edition")) {
                    if (package_edition != null) return error.DuplicateKey;
                    package_edition = try parseTomlString(allocator, value);
                } else {
                    return error.UnknownKey;
                }
            },
            .dependencies => {
                const dependency_name = try parseTomlKey(allocator, key);
                errdefer allocator.free(dependency_name);

                if (hasDependency(dependencies.items, dependency_name)) {
                    return error.DuplicateKey;
                }

                try dependencies.append(allocator, .{
                    .name = dependency_name,
                    .version = try parseTomlString(allocator, value),
                });
            },
            .build => {
                if (std.mem.eql(u8, key, "src")) {
                    if (build_src != null) return error.DuplicateKey;
                    build_src = try parseTomlString(allocator, value);
                } else if (std.mem.eql(u8, key, "entry")) {
                    if (build_entry != null) return error.DuplicateKey;
                    build_entry = try parseTomlString(allocator, value);
                } else {
                    return error.UnknownKey;
                }
            },
            .none => return error.MissingSection,
        }
    }

    if (!saw_package) return error.MissingSection;
    if (package_name == null or package_version == null or package_edition == null) {
        return error.MissingField;
    }

    return .{
        .package = .{
            .name = package_name.?,
            .version = package_version.?,
            .edition = package_edition.?,
        },
        .dependencies = try dependencies.toOwnedSlice(allocator),
        .build = if (build_src != null or build_entry != null) .{
            .src = build_src orelse return error.MissingField,
            .entry = build_entry orelse return error.MissingField,
        } else null,
    };
}

pub fn renderManifestAlloc(allocator: std.mem.Allocator, manifest: Manifest) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("[package]\n");
    try writeTomlStringField(&out.writer, "name", manifest.package.name);
    try writeTomlStringField(&out.writer, "version", manifest.package.version);
    try writeTomlStringField(&out.writer, "edition", manifest.package.edition);
    try out.writer.writeByte('\n');

    try out.writer.writeAll("[dependencies]\n");
    if (manifest.dependencies.len > 0) {
        const sorted = try allocator.dupe(Dependency, manifest.dependencies);
        defer allocator.free(sorted);
        std.mem.sort(Dependency, sorted, {}, struct {
            fn lessThan(_: void, left: Dependency, right: Dependency) bool {
                return std.mem.order(u8, left.name, right.name) == .lt;
            }
        }.lessThan);

        for (sorted) |dependency| {
            try writeTomlQuotedKeyField(&out.writer, dependency.name, dependency.version);
        }
    }

    if (manifest.build) |build| {
        try out.writer.writeByte('\n');
        try out.writer.writeAll("[build]\n");
        try writeTomlStringField(&out.writer, "src", build.src);
        try writeTomlStringField(&out.writer, "entry", build.entry);
    }

    return try out.toOwnedSlice();
}

pub fn parseLockfile(allocator: std.mem.Allocator, contents: []const u8) !Lockfile {
    var parser = LineParser.init(allocator, contents);
    var packages: std.ArrayList(LockPackage) = .empty;
    errdefer {
        for (packages.items) |package| {
            allocator.free(package.name);
            allocator.free(package.version);
            allocator.free(package.checksum);
        }
        packages.deinit(allocator);
    }

    var current_name: ?[]const u8 = null;
    var current_version: ?[]const u8 = null;
    var current_checksum: ?[]const u8 = null;
    var in_package = false;

    while (parser.nextLine()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        if (std.mem.eql(u8, line, "[[package]]")) {
            if (in_package) {
                try packages.append(allocator, .{
                    .name = current_name orelse return error.MissingField,
                    .version = current_version orelse return error.MissingField,
                    .checksum = current_checksum orelse return error.MissingField,
                });
                current_name = null;
                current_version = null;
                current_checksum = null;
            }
            in_package = true;
            continue;
        }

        const key, const value = parseAssignment(line) catch return error.InvalidLine;
        if (!in_package) return error.UnexpectedSection;

        if (std.mem.eql(u8, key, "name")) {
            if (current_name != null) return error.DuplicateKey;
            current_name = try parseTomlString(allocator, value);
        } else if (std.mem.eql(u8, key, "version")) {
            if (current_version != null) return error.DuplicateKey;
            current_version = try parseTomlString(allocator, value);
        } else if (std.mem.eql(u8, key, "checksum")) {
            if (current_checksum != null) return error.DuplicateKey;
            current_checksum = try parseTomlString(allocator, value);
        } else {
            return error.UnknownKey;
        }
    }

    if (in_package) {
        try packages.append(allocator, .{
            .name = current_name orelse return error.MissingField,
            .version = current_version orelse return error.MissingField,
            .checksum = current_checksum orelse return error.MissingField,
        });
    }

    return .{ .packages = try packages.toOwnedSlice(allocator) };
}

pub fn renderLockfileAlloc(allocator: std.mem.Allocator, lockfile: Lockfile) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    if (lockfile.packages.len == 0) {
        return try out.toOwnedSlice();
    }

    const sorted = try allocator.dupe(LockPackage, lockfile.packages);
    defer allocator.free(sorted);
    std.mem.sort(LockPackage, sorted, {}, struct {
        fn lessThan(_: void, left: LockPackage, right: LockPackage) bool {
            return switch (std.mem.order(u8, left.name, right.name)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, left.version, right.version) == .lt,
            };
        }
    }.lessThan);

    for (sorted, 0..) |package, index| {
        if (index > 0) {
            try out.writer.writeByte('\n');
        }
        try out.writer.writeAll("[[package]]\n");
        try writeTomlStringField(&out.writer, "name", package.name);
        try writeTomlStringField(&out.writer, "version", package.version);
        try writeTomlStringField(&out.writer, "checksum", package.checksum);
    }

    return try out.toOwnedSlice();
}

const Section = enum {
    none,
    package,
    dependencies,
    build,
};

const LineParser = struct {
    contents: []const u8,
    index: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, contents: []const u8) LineParser {
        return .{ .allocator = allocator, .contents = contents };
    }

    fn nextLine(self: *LineParser) ?[]const u8 {
        if (self.index >= self.contents.len) return null;
        const start = self.index;
        while (self.index < self.contents.len and self.contents[self.index] != '\n') {
            self.index += 1;
        }
        const end = self.index;
        if (self.index < self.contents.len) self.index += 1;
        return std.mem.trim(u8, self.contents[start..end], " \t\r");
    }
};

fn parseSection(line: []const u8) ParseError!Section {
    if (std.mem.eql(u8, line, "[package]")) return .package;
    if (std.mem.eql(u8, line, "[dependencies]")) return .dependencies;
    if (std.mem.eql(u8, line, "[build]")) return .build;
    return error.InvalidSection;
}

fn parseAssignment(line: []const u8) ParseError!struct { []const u8, []const u8 } {
    const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLine;
    const key = std.mem.trim(u8, line[0..eq_index], " \t");
    const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
    if (key.len == 0 or value.len == 0) return error.InvalidLine;
    return .{ key, value };
}

fn parseTomlKey(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (key.len > 0 and key[0] == '"') {
        return parseTomlString(allocator, key);
    }
    return allocator.dupe(u8, key);
}

fn parseTomlString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
        return error.InvalidString;
    }

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var index: usize = 1;
    while (index < raw.len - 1) : (index += 1) {
        const byte = raw[index];
        if (byte == '\\') {
            index += 1;
            if (index >= raw.len - 1) return error.InvalidString;
            const escaped = raw[index];
            switch (escaped) {
                '\\', '"' => try out.writer.writeByte(escaped),
                'n' => try out.writer.writeByte('\n'),
                'r' => try out.writer.writeByte('\r'),
                't' => try out.writer.writeByte('\t'),
                else => return error.InvalidString,
            }
        } else {
            try out.writer.writeByte(byte);
        }
    }

    return try out.toOwnedSlice();
}

fn writeTomlStringField(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.print("{s} = \"", .{key});
    try writeEscapedString(writer, value);
    try writer.writeAll("\"\n");
}

fn writeTomlQuotedKeyField(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.writeByte('"');
    try writeEscapedString(writer, key);
    try writer.writeAll("\" = \"");
    try writeEscapedString(writer, value);
    try writer.writeAll("\"\n");
}

fn writeEscapedString(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
}

fn hasDependency(dependencies: []const Dependency, name: []const u8) bool {
    for (dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.name, name)) {
            return true;
        }
    }
    return false;
}

test "manifest round-trips through parser and serializer" {
    const input =
        "[package]\n" ++
        "name = \"github.com/sam/demo\"\n" ++
        "version = \"0.1.0\"\n" ++
        "edition = \"2026\"\n\n" ++
        "[dependencies]\n" ++
        "\"github.com/sam/store\" = \"0.4.0\"\n" ++
        "\"github.com/sam/validation\" = \"0.2.1\"\n\n" ++
        "[build]\n" ++
        "src = \"src\"\n" ++
        "entry = \"src/main.lace\"\n";

    var manifest = try parseManifest(std.testing.allocator, input);
    defer manifest.deinit(std.testing.allocator);

    const rendered = try renderManifestAlloc(std.testing.allocator, manifest);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(input, rendered);
}

test "lockfile serialization is deterministic" {
    const lockfile = Lockfile{
        .packages = &.{
            .{ .name = "github.com/sam/store", .version = "0.4.0", .checksum = "sha256:bbb" },
            .{ .name = "github.com/sam/validation", .version = "0.2.1", .checksum = "sha256:aaa" },
        },
    };

    const rendered = try renderLockfileAlloc(std.testing.allocator, lockfile);
    defer std.testing.allocator.free(rendered);

    const expected =
        "[[package]]\n" ++
        "name = \"github.com/sam/store\"\n" ++
        "version = \"0.4.0\"\n" ++
        "checksum = \"sha256:bbb\"\n\n" ++
        "[[package]]\n" ++
        "name = \"github.com/sam/validation\"\n" ++
        "version = \"0.2.1\"\n" ++
        "checksum = \"sha256:aaa\"\n";
    try std.testing.expectEqualStrings(expected, rendered);

    var parsed = try parseLockfile(std.testing.allocator, rendered);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.packages.len);
}
