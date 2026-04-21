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
    try writer.writeAll("This is the Lace v0.1 Zig scaffold. Only `--help` is implemented so far.\n");
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
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Only `--help` is implemented") != null);
}
