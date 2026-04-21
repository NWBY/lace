const std = @import("std");
const Io = std.Io;

const lace = @import("lace");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cli_args = if (args.len > 1) args[1..] else &.{};

    var context = lace.Context.init(arena, init.io);
    defer context.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const exit_code = try lace.runCli(&context, stdout, stderr, cli_args);

    try stdout.flush();
    try stderr.flush();

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
