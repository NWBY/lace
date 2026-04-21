const std = @import("std");
const Io = std.Io;

pub const backend = @import("backend/mod.zig");
pub const cli = @import("cli/mod.zig");
pub const diag = @import("diag/mod.zig");
pub const id = @import("id.zig");
pub const pkg = @import("pkg/mod.zig");
pub const sem = @import("sem/mod.zig");
pub const source = @import("source.zig");
pub const syntax = @import("syntax/mod.zig");

pub const Context = @import("context.zig").Context;

pub fn runCli(
    context: *Context,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    args: []const []const u8,
) !u8 {
    const command = cli.parse(args) catch |err| switch (err) {
        error.UnknownCommand => {
            try stderr.print("Unknown command `{s}`.\n\n", .{args[0]});
            try cli.writeHelp(stderr);
            return 1;
        },
    };

    return context.execute(stdout, stderr, command);
}

test {
    std.testing.refAllDecls(@This());
}

test "runCli falls back to help for unknown commands" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();

    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    const exit_code = try runCli(
        &context,
        &stdout.writer,
        &stderr.writer,
        &.{"unknown"},
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "Unknown command `unknown`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "lace check") != null);
}
