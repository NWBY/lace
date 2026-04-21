const std = @import("std");
const Io = std.Io;

const cli = @import("cli/mod.zig");
const diag = @import("diag/mod.zig");
const source = @import("source.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: ?Io,
    files: source.Manager = .{},
    diagnostics: diag.Store = .{},

    pub fn init(allocator: std.mem.Allocator, io: ?Io) Context {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Context) void {
        self.files.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loadFile(self: *Context, path: []const u8) !source.FileId {
        const io = self.io orelse return error.IoUnavailable;
        return self.files.loadFile(self.allocator, io, path);
    }

    pub fn addSource(self: *Context, path: []const u8, contents: []const u8) !source.FileId {
        return self.files.addSource(self.allocator, path, contents);
    }

    pub fn sourceFile(self: *const Context, file_id: source.FileId) *const source.File {
        return self.files.getFile(file_id);
    }

    pub fn addDiagnostic(self: *Context, diagnostic: diag.Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diagnostic);
    }

    pub fn execute(
        self: *Context,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        command: cli.Command,
    ) !u8 {
        _ = self;

        switch (command.kind) {
            .help => {
                try cli.writeHelp(stdout);
                return 0;
            },
            else => {
                _ = command.args;
                try stderr.print("`lace {s}` is not implemented yet.\n", .{command.kind.label()});
                try stderr.writeAll("Start with `lace --help` to see the current scaffold.\n");
                return 1;
            },
        }
    }
};

test "context stores diagnostics" {
    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    try context.addDiagnostic(.{
        .level = .warning,
        .code = "W0001",
        .message = "placeholder warning",
    });

    try std.testing.expectEqual(@as(usize, 1), context.diagnostics.count());
    try std.testing.expect(!context.diagnostics.hasErrors());
}

test "context caches source files by path" {
    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    const first = try context.addSource("src/demo.lace", "module demo;\n");
    const second = try context.addSource("src/demo.lace", "module ignored;\n");

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("module demo;\n", context.sourceFile(first).source);
}
