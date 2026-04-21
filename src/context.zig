const std = @import("std");
const Io = std.Io;

const cli = @import("cli/mod.zig");
const diag = @import("diag/mod.zig");
const source = @import("source.zig");
const syntax = @import("syntax/mod.zig");

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
        if (self.files.findFileId(path)) |file_id| {
            return file_id;
        }

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
        switch (command.kind) {
            .help => {
                try cli.writeHelp(stdout);
                return 0;
            },
            .ast => return self.executeAstCommand(stdout, stderr, command.args),
            else => {
                _ = command.args;
                try stderr.print("`lace {s}` is not implemented yet.\n", .{command.kind.label()});
                try stderr.writeAll("Start with `lace --help` to see the current scaffold.\n");
                return 1;
            },
        }
    }

    fn executeAstCommand(
        self: *Context,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        args: []const []const u8,
    ) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseAstOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace ast --json <file>\n");
            switch (err) {
                error.MissingJsonFlag => try stderr.writeAll("`lace ast` currently requires `--json`.\n"),
                error.MissingPath => try stderr.writeAll("`lace ast --json` requires a source file path.\n"),
                error.UnexpectedArgument => try stderr.writeAll("`lace ast` accepts exactly one source file path.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace ast` flag.\n"),
            }
            return 1;
        };

        var diagnostics: diag.Store = .{};

        const file_id = self.loadFile(options.path) catch |err| {
            try stderr.print("Failed to load `{s}`: {t}\n", .{ options.path, err });
            return 1;
        };

        const document = syntax.parseFile(arena, &diagnostics, self.sourceFile(file_id)) catch |err| switch (err) {
            error.InvalidSyntax => {
                try self.renderDiagnostics(stderr, &diagnostics);
                return 1;
            },
            error.OutOfMemory => return err,
        };

        if (options.json) {
            try syntax.renderAstJson(stdout, &self.files, document);
            try stdout.writeByte('\n');
            return 0;
        }

        return 1;
    }

    fn renderDiagnostics(self: *Context, stderr: *Io.Writer, diagnostics: *const diag.Store) !void {
        for (diagnostics.items.items) |item| {
            try diag.renderText(stderr, &self.files, item);
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

test "context executes ast json for a loaded source file" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();

    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    _ = try context.addSource(
        "src/demo.lace",
        "module demo;\nfn main() -> Void {\n    return Ok(Void);\n}\n",
    );

    const exit_code = try context.execute(
        &stdout.writer,
        &stderr.writer,
        .{ .kind = .ast, .args = &.{ "--json", "src/demo.lace" } },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"kind\":\"Module\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"kind\":\"FunctionDecl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"kind\":\"ReturnStmt\"") != null);
}
