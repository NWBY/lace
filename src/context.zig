const std = @import("std");
const Io = std.Io;

const cli = @import("cli/mod.zig");
const diag = @import("diag/mod.zig");
const pkg = @import("pkg/mod.zig");
const sem = @import("sem/mod.zig");
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
            .init => return self.executeInitCommand(stderr, command.args),
            .fmt => return self.executeFmtCommand(stderr, command.args),
            .check => return self.executeCheckCommand(stdout, stderr, command.args),
            .ast => return self.executeAstCommand(stdout, stderr, command.args),
            .diag => return self.executeDiagCommand(stdout, stderr, command.args),
            .new => return self.executeNewCommand(stderr, command.args),
            else => {
                _ = command.args;
                try stderr.print("`lace {s}` is not implemented yet.\n", .{command.kind.label()});
                try stderr.writeAll("Start with `lace --help` to see the current scaffold.\n");
                return 1;
            },
        }
    }

    fn executeFmtCommand(self: *Context, stderr: *Io.Writer, args: []const []const u8) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseFormatOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace fmt [path]\n");
            switch (err) {
                error.UnexpectedArgument => try stderr.writeAll("`lace fmt` accepts exactly one source file path.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace fmt` flag.\n"),
            }
            return 1;
        };

        var diagnostics: diag.Store = .{};
        const loaded = self.loadDocuments(arena, &diagnostics, sourceTargetFromPath(options.path)) catch |err| switch (err) {
            error.IoUnavailable => {
                try stderr.writeAll("`lace fmt` requires process I/O for package traversal.\n");
                return 1;
            },
            error.NoSourceFiles => {
                try stderr.writeAll("No Lace source files were found.\n");
                return 1;
            },
            else => {
                try stderr.print("Failed to load sources: {t}\n", .{err});
                return 1;
            },
        };

        if (diagnostics.count() != 0) {
            try self.renderDiagnostics(stderr, &diagnostics);
            return 1;
        }

        const io = self.io orelse {
            try stderr.writeAll("`lace fmt` requires process I/O.\n");
            return 1;
        };

        for (loaded.documents) |document| {
            const file_id = document.file_id;
            const formatted = try syntax.formatDocumentAlloc(arena, &self.files, document);
            const file_path = self.sourceFile(file_id).path;
            if (!std.mem.eql(u8, formatted, self.sourceFile(file_id).source)) {
                try std.Io.Dir.cwd().writeFile(io, .{
                    .sub_path = file_path,
                    .data = formatted,
                });
                try self.files.replaceSource(self.allocator, file_id, formatted);
            }
        }

        return 0;
    }

    fn executeCheckCommand(
        self: *Context,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        args: []const []const u8,
    ) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseCheckOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace check [--json] [path]\n");
            switch (err) {
                error.UnexpectedArgument => try stderr.writeAll("`lace check` accepts at most one path argument.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace check` flag.\n"),
            }
            return 1;
        };

        var diagnostics: diag.Store = .{};
        const loaded = self.loadDocuments(arena, &diagnostics, sourceTargetFromPath(options.path)) catch |err| switch (err) {
            error.IoUnavailable => {
                try stderr.writeAll("`lace check` requires process I/O for package traversal.\n");
                return 1;
            },
            error.NoSourceFiles => {
                try stderr.writeAll("No Lace source files were found.\n");
                return 1;
            },
            else => {
                try stderr.print("Failed to load sources: {t}\n", .{err});
                return 1;
            },
        };

        if (diagnostics.count() == 0) {
            _ = try sem.typecheckDocuments(arena, &diagnostics, &self.files, loaded.documents);
        }

        if (options.json) {
            try self.renderCheckJson(stdout, &diagnostics);
            try stdout.writeByte('\n');
        } else if (diagnostics.count() != 0) {
            try self.renderDiagnostics(stderr, &diagnostics);
        }

        return if (diagnostics.count() == 0) 0 else 1;
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

    fn executeDiagCommand(
        self: *Context,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        args: []const []const u8,
    ) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseDiagOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace diag [--json] [path]\n");
            switch (err) {
                error.UnexpectedArgument => try stderr.writeAll("`lace diag` accepts at most one path argument.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace diag` flag.\n"),
            }
            return 1;
        };

        var diagnostics: diag.Store = .{};
        const loaded = self.loadDocuments(arena, &diagnostics, sourceTargetFromPath(options.path)) catch |err| switch (err) {
            error.IoUnavailable => {
                try stderr.writeAll("`lace diag` requires process I/O for package traversal.\n");
                return 1;
            },
            error.NoSourceFiles => {
                try stderr.writeAll("No Lace source files were found.\n");
                return 1;
            },
            else => {
                try stderr.print("Failed to load sources: {t}\n", .{err});
                return 1;
            },
        };

        if (diagnostics.count() == 0) {
            _ = try sem.typecheckDocuments(arena, &diagnostics, &self.files, loaded.documents);
        }

        if (options.json) {
            try self.renderDiagJson(stdout, &diagnostics);
            try stdout.writeByte('\n');
        } else {
            try self.renderDiagnostics(stderr, &diagnostics);
        }

        return if (diagnostics.count() == 0) 0 else 1;
    }

    fn executeInitCommand(self: *Context, stderr: *Io.Writer, args: []const []const u8) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseInitOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace init [--name <package>] [--lib]\n");
            switch (err) {
                error.MissingNameValue => try stderr.writeAll("`lace init --name` requires a package name.\n"),
                error.UnexpectedArgument => try stderr.writeAll("`lace init` only accepts flags.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace init` flag.\n"),
            }
            return 1;
        };

        const io = self.io orelse {
            try stderr.writeAll("`lace init` requires process I/O.\n");
            return 1;
        };

        const package_name = options.name orelse try defaultInitPackageName(arena, io);
        pkg.initPackage(arena, io, std.Io.Dir.cwd(), .{
            .package_name = package_name,
            .lib = options.lib,
        }) catch |err| {
            try stderr.print("Failed to initialize package: {t}\n", .{err});
            return 1;
        };

        return 0;
    }

    fn executeNewCommand(self: *Context, stderr: *Io.Writer, args: []const []const u8) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseNewOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace new <package> [--lib]\n");
            switch (err) {
                error.MissingName => try stderr.writeAll("`lace new` requires a package name.\n"),
                error.UnexpectedArgument => try stderr.writeAll("`lace new` accepts one package name.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace new` flag.\n"),
            }
            return 1;
        };

        const io = self.io orelse {
            try stderr.writeAll("`lace new` requires process I/O.\n");
            return 1;
        };

        _ = pkg.newPackage(arena, io, std.Io.Dir.cwd(), .{
            .package_name = options.name,
            .lib = options.lib,
        }) catch |err| {
            switch (err) {
                error.AlreadyExists => try stderr.writeAll("Target directory already exists.\n"),
                else => try stderr.print("Failed to create package: {t}\n", .{err}),
            }
            return 1;
        };

        return 0;
    }

    fn renderDiagnostics(self: *Context, stderr: *Io.Writer, diagnostics: *const diag.Store) !void {
        for (diagnostics.items.items) |item| {
            try diag.renderText(stderr, &self.files, item);
        }
    }

    fn renderCheckJson(self: *Context, stdout: *Io.Writer, diagnostics: *const diag.Store) !void {
        var json: std.json.Stringify = .{ .writer = stdout, .options = .{} };
        try json.beginObject();
        try json.objectField("status");
        try json.write(if (diagnostics.count() == 0) "ok" else "error");
        try json.objectField("diagnostics");
        try self.renderDiagnosticsJsonArray(&json, diagnostics);
        try json.endObject();
    }

    fn renderDiagJson(self: *Context, stdout: *Io.Writer, diagnostics: *const diag.Store) !void {
        var json: std.json.Stringify = .{ .writer = stdout, .options = .{} };
        try json.beginObject();
        try json.objectField("diagnostics");
        try self.renderDiagnosticsJsonArray(&json, diagnostics);
        try json.endObject();
    }

    fn renderDiagnosticsJsonArray(self: *Context, json: *std.json.Stringify, diagnostics: *const diag.Store) !void {
        try json.beginArray();
        for (diagnostics.items.items) |item| {
            try json.beginWriteRaw();
            try diag.renderJson(json.writer, &self.files, item);
            json.endWriteRaw();
        }
        try json.endArray();
    }

    fn loadDocuments(
        self: *Context,
        arena: std.mem.Allocator,
        diagnostics: *diag.Store,
        target: pkg.SourceTarget,
    ) !LoadedDocuments {
        const paths = try pkg.collectSourceFiles(arena, self.io, target);
        if (paths.len == 0) {
            return error.NoSourceFiles;
        }

        var documents: std.ArrayList(syntax.Tree.Document) = .empty;
        for (paths) |path| {
            const file_id = try self.loadFile(path);
            const document = syntax.parseFile(arena, diagnostics, self.sourceFile(file_id)) catch |err| switch (err) {
                error.InvalidSyntax => continue,
                error.OutOfMemory => return err,
            };
            try documents.append(arena, document);
        }

        return .{
            .paths = paths,
            .documents = try documents.toOwnedSlice(arena),
        };
    }

    fn defaultInitPackageName(allocator: std.mem.Allocator, io: Io) ![]const u8 {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        const base = std.fs.path.basename(cwd);
        return try std.fmt.allocPrint(allocator, "example.com/{s}", .{base});
    }
};

const LoadedDocuments = struct {
    paths: []const []const u8,
    documents: []const syntax.Tree.Document,
};

fn sourceTargetFromPath(path: ?[]const u8) pkg.SourceTarget {
    if (path) |value| {
        if (std.mem.endsWith(u8, value, ".lace")) {
            return .{ .single_file = value };
        }
        return .{ .package = .{ .root = value } };
    }

    return .{ .package = .{} };
}

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

test "context executes check json for a valid loaded source file" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();

    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    _ = try context.addSource(
        "src/demo.lace",
        "module demo;\n\nfn main() -> Int {\n    return 1;\n}\n",
    );

    const exit_code = try context.execute(
        &stdout.writer,
        &stderr.writer,
        .{ .kind = .check, .args = &.{ "--json", "src/demo.lace" } },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"diagnostics\":[]}\n", stdout.written());
}

test "context executes diag json for an invalid loaded source file" {
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();

    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    _ = try context.addSource(
        "src/bad.lace",
        "module bad;\n\nfn main() -> Int {\n    if 1 {\n        return 1;\n    }\n\n    return 2;\n}\n",
    );

    const exit_code = try context.execute(
        &stdout.writer,
        &stderr.writer,
        .{ .kind = .diag, .args = &.{ "--json", "src/bad.lace" } },
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqualStrings(
        "{\"diagnostics\":[{\"code\":\"T1105\",\"level\":\"error\",\"message\":\"If conditions must have type `Bool`\",\"file\":\"src/bad.lace\",\"span\":{\"start_line\":4,\"start_col\":8,\"end_line\":4,\"end_col\":9},\"symbol\":null,\"details\":[],\"suggested_fixes\":[]}]}\n",
        stdout.written(),
    );
}
