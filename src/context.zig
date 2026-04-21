const std = @import("std");
const Io = std.Io;

const cli = @import("cli/mod.zig");
const diag = @import("diag/mod.zig");

pub const LoadedFile = struct {
    path: []const u8,
    source: []const u8,
};

const SourceStore = struct {
    items: std.ArrayList(LoadedFile) = .empty,

    fn deinit(self: *SourceStore, allocator: std.mem.Allocator) void {
        for (self.items.items) |file| {
            allocator.free(file.path);
            allocator.free(file.source);
        }
        self.items.deinit(allocator);
        self.* = undefined;
    }

    fn load(
        self: *SourceStore,
        allocator: std.mem.Allocator,
        io: Io,
        path: []const u8,
    ) !LoadedFile {
        for (self.items.items) |file| {
            if (std.mem.eql(u8, file.path, path)) {
                return file;
            }
        }

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const source = try std.fs.cwd().readFileAlloc(io, path, allocator, .unlimited);
        errdefer allocator.free(source);

        const loaded_file = LoadedFile{
            .path = owned_path,
            .source = source,
        };

        try self.items.append(allocator, loaded_file);
        return self.items.items[self.items.items.len - 1];
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: ?Io,
    files: SourceStore = .{},
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

    pub fn loadFile(self: *Context, path: []const u8) !LoadedFile {
        const io = self.io orelse return error.IoUnavailable;
        return self.files.load(self.allocator, io, path);
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
