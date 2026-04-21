const std = @import("std");
const Io = std.Io;

pub const CommandKind = enum {
    help,
    init,
    @"new",
    fmt,
    check,
    build,
    run,
    @"test",
    types,
    ast,
    diag,
    add,
    remove,
    fetch,
    publish,
    update,
    clean,

    pub fn label(self: CommandKind) []const u8 {
        return switch (self) {
            .help => "help",
            .init => "init",
            .@"new" => "new",
            .fmt => "fmt",
            .check => "check",
            .build => "build",
            .run => "run",
            .@"test" => "test",
            .types => "types",
            .ast => "ast",
            .diag => "diag",
            .add => "add",
            .remove => "remove",
            .fetch => "fetch",
            .publish => "publish",
            .update => "update",
            .clean => "clean",
        };
    }
};

pub const Command = struct {
    kind: CommandKind,
    args: []const []const u8 = &.{},
};

pub const FormatOptions = struct {
    path: ?[]const u8 = null,
};

pub const InitOptions = struct {
    name: ?[]const u8 = null,
    lib: bool = false,
};

pub const NewOptions = struct {
    name: []const u8,
    lib: bool = false,
};

pub const CheckOptions = struct {
    path: ?[]const u8 = null,
    json: bool = false,
};

pub const DiagOptions = struct {
    path: ?[]const u8 = null,
    json: bool = false,
};

pub const AstOptions = struct {
    path: []const u8,
    json: bool,
};

pub const CommandInfo = struct {
    kind: CommandKind,
    summary: []const u8,
};

pub const command_list = [_]CommandInfo{
    .{ .kind = .init, .summary = "Initialize a package in the current directory." },
    .{ .kind = .@"new", .summary = "Create a new package directory." },
    .{ .kind = .fmt, .summary = "Format Lace source files canonically." },
    .{ .kind = .check, .summary = "Parse, resolve, and type-check a package." },
    .{ .kind = .build, .summary = "Compile the current package." },
    .{ .kind = .run, .summary = "Build and run the entry target." },
    .{ .kind = .@"test", .summary = "Discover and run tests." },
    .{ .kind = .types, .summary = "Emit exported type information." },
    .{ .kind = .ast, .summary = "Emit the stable AST." },
    .{ .kind = .diag, .summary = "Render diagnostics for a package." },
    .{ .kind = .add, .summary = "Add an exact-version dependency." },
    .{ .kind = .remove, .summary = "Remove a dependency." },
    .{ .kind = .fetch, .summary = "Resolve and fetch dependencies." },
    .{ .kind = .publish, .summary = "Publish the current package." },
    .{ .kind = .update, .summary = "Refresh the lock file." },
    .{ .kind = .clean, .summary = "Remove generated build artifacts." },
};

pub const ParseError = error{UnknownCommand};
pub const InitOptionsError = error{
    MissingNameValue,
    UnexpectedArgument,
    UnsupportedFlag,
};
pub const NewOptionsError = error{
    MissingName,
    UnexpectedArgument,
    UnsupportedFlag,
};
pub const FormatOptionsError = error{
    UnexpectedArgument,
    UnsupportedFlag,
};
pub const CheckOptionsError = error{
    UnexpectedArgument,
    UnsupportedFlag,
};
pub const AstOptionsError = error{
    MissingPath,
    MissingJsonFlag,
    UnexpectedArgument,
    UnsupportedFlag,
};

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) {
        return .{ .kind = .help };
    }

    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        return .{ .kind = .help, .args = args[1..] };
    }

    const kind = std.meta.stringToEnum(CommandKind, args[0]) orelse return error.UnknownCommand;
    return .{
        .kind = kind,
        .args = args[1..],
    };
}

pub fn writeHelp(writer: *Io.Writer) !void {
    try writer.writeAll("lace\n\n");
    try writer.writeAll("Usage:\n");
    try writer.writeAll("    lace <command> [options]\n\n");
    try writer.writeAll("Commands:\n");

    for (command_list) |command| {
        try writer.print("    lace {s}\n        {s}\n", .{
            command.kind.label(),
            command.summary,
        });
    }

    try writer.writeAll("\n");
    try writer.writeAll("Implemented so far: `lace init`, `lace new`, `lace fmt`, `lace check`, `lace ast --json <file>`, `lace diag --json`, and `lace --help`.\n");
}

pub fn parseInitOptions(args: []const []const u8) InitOptionsError!InitOptions {
    var options: InitOptions = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--lib")) {
            options.lib = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            index += 1;
            if (index >= args.len) return error.MissingNameValue;
            options.name = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedFlag;
        }
        return error.UnexpectedArgument;
    }
    return options;
}

pub fn parseNewOptions(args: []const []const u8) NewOptionsError!NewOptions {
    var name: ?[]const u8 = null;
    var lib = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--lib")) {
            lib = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedFlag;
        }
        if (name == null) {
            name = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }

    return .{
        .name = name orelse return error.MissingName,
        .lib = lib,
    };
}

pub fn parseFormatOptions(args: []const []const u8) FormatOptionsError!FormatOptions {
    var path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedFlag;
        }

        if (path == null) {
            path = arg;
            continue;
        }

        return error.UnexpectedArgument;
    }

    return .{
        .path = path,
    };
}

pub fn parseCheckOptions(args: []const []const u8) CheckOptionsError!CheckOptions {
    var options: CheckOptions = .{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedFlag;
        }

        if (options.path == null) {
            options.path = arg;
            continue;
        }

        return error.UnexpectedArgument;
    }

    return options;
}

pub fn parseDiagOptions(args: []const []const u8) CheckOptionsError!DiagOptions {
    const options = try parseCheckOptions(args);
    return .{
        .path = options.path,
        .json = options.json,
    };
}

pub fn parseAstOptions(args: []const []const u8) AstOptionsError!AstOptions {
    var path: ?[]const u8 = null;
    var json = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnsupportedFlag;
        }

        if (path == null) {
            path = arg;
            continue;
        }

        return error.UnexpectedArgument;
    }

    if (!json) {
        return error.MissingJsonFlag;
    }

    return .{
        .path = path orelse return error.MissingPath,
        .json = json,
    };
}

test "parse defaults to help" {
    const command = try parse(&.{});
    try std.testing.expectEqual(CommandKind.help, command.kind);
}

test "help output lists check command" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try writeHelp(&output.writer);

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "lace check") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "lace ast --json <file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "lace diag") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "lace fmt") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "lace init") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "lace new") != null);
}

test "parse init options supports name and lib" {
    const options = try parseInitOptions(&.{ "--name", "github.com/sam/demo", "--lib" });
    try std.testing.expectEqualStrings("github.com/sam/demo", options.name.?);
    try std.testing.expect(options.lib);

    const default_options = try parseInitOptions(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), default_options.name);
    try std.testing.expect(!default_options.lib);

    try std.testing.expectError(error.MissingNameValue, parseInitOptions(&.{"--name"}));
    try std.testing.expectError(error.UnsupportedFlag, parseInitOptions(&.{"--bad"}));
}

test "parse new options requires a package name" {
    const options = try parseNewOptions(&.{ "github.com/sam/demo", "--lib" });
    try std.testing.expectEqualStrings("github.com/sam/demo", options.name);
    try std.testing.expect(options.lib);

    try std.testing.expectError(error.MissingName, parseNewOptions(&.{}));
    try std.testing.expectError(error.UnexpectedArgument, parseNewOptions(&.{ "a", "b" }));
    try std.testing.expectError(error.UnsupportedFlag, parseNewOptions(&.{"--bad"}));
}

test "parse format options requires one path" {
    const options = try parseFormatOptions(&.{"src/main.lace"});
    try std.testing.expectEqualStrings("src/main.lace", options.path.?);
    const package_options = try parseFormatOptions(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), package_options.path);

    try std.testing.expectError(error.UnexpectedArgument, parseFormatOptions(&.{ "a.lace", "b.lace" }));
    try std.testing.expectError(error.UnsupportedFlag, parseFormatOptions(&.{"--check"}));
}

test "parse check options allows package defaults and json" {
    const default_options = try parseCheckOptions(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), default_options.path);
    try std.testing.expect(!default_options.json);

    const json_options = try parseCheckOptions(&.{ "--json", "src/main.lace" });
    try std.testing.expectEqualStrings("src/main.lace", json_options.path.?);
    try std.testing.expect(json_options.json);

    try std.testing.expectError(error.UnsupportedFlag, parseCheckOptions(&.{"--bad"}));
    try std.testing.expectError(error.UnexpectedArgument, parseCheckOptions(&.{ "a", "b" }));
}

test "parse ast options requires json and a path" {
    const options = try parseAstOptions(&.{ "--json", "src/main.lace" });
    try std.testing.expectEqualStrings("src/main.lace", options.path);
    try std.testing.expect(options.json);

    try std.testing.expectError(error.MissingJsonFlag, parseAstOptions(&.{"src/main.lace"}));
    try std.testing.expectError(error.MissingPath, parseAstOptions(&.{"--json"}));
    try std.testing.expectError(error.UnexpectedArgument, parseAstOptions(&.{ "--json", "a.lace", "b.lace" }));
}
