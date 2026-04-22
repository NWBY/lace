const std = @import("std");
const Io = std.Io;

const cli = @import("cli/mod.zig");
const diag = @import("diag/mod.zig");
const backend = @import("backend/mod.zig");
const pkg = @import("pkg/mod.zig");
const sem = @import("sem/mod.zig");
const source = @import("source.zig");
const syntax = @import("syntax/mod.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: ?Io,
    dependency_roots: ?pkg.DependencyRoots = null,
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
            .build => return self.executeBuildCommand(stdout, stderr, command.args),
            .run => return self.executeRunCommand(stdout, stderr, command.args),
            .types => return self.executeTypesCommand(stdout, stderr, command.args),
            .ast => return self.executeAstCommand(stdout, stderr, command.args),
            .diag => return self.executeDiagCommand(stdout, stderr, command.args),
            .fetch => return self.executeFetchCommand(stderr, command.args),
            .new => return self.executeNewCommand(stderr, command.args),
            else => {
                _ = command.args;
                try stderr.print("`lace {s}` is not implemented yet.\n", .{command.kind.label()});
                try stderr.writeAll("Start with `lace --help` to see the implemented commands.\n");
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
        const loaded = self.loadDocuments(arena, &diagnostics, sourceTargetFromPath(options.path), false) catch |err| switch (err) {
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
        const loaded = self.loadDocuments(arena, &diagnostics, sourceTargetFromPath(options.path), true) catch |err| switch (err) {
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

    fn executeBuildCommand(
        self: *Context,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        args: []const []const u8,
    ) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseBuildOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace build [--json] [--release] [--target <triple>] [path]\n");
            switch (err) {
                error.MissingTargetValue => try stderr.writeAll("`lace build --target` requires a target triple.\n"),
                error.UnexpectedArgument => try stderr.writeAll("`lace build` accepts at most one path argument.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace build` flag.\n"),
            }
            return 1;
        };

        if (options.release or options.target != null) {
            try stderr.writeAll("The interpreter backend does not support `--release` or `--target` yet.\n");
            return 1;
        }

        const io = self.io orelse {
            try stderr.writeAll("`lace build` requires process I/O.\n");
            return 1;
        };

        const package_root = try self.resolvePackageRoot(arena, io, options.path);
        const manifest = self.loadManifestFromRoot(arena, io, package_root) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.writeAll("`lace build` requires a package with `lace.toml`.\n");
                return 1;
            },
            else => return err,
        };
        defer {
            var manifest_mut = manifest;
            manifest_mut.deinit(arena);
        }

        var diagnostics: diag.Store = .{};
        const loaded = self.loadDocuments(arena, &diagnostics, .{ .package = .{ .root = package_root } }, true) catch |err| switch (err) {
            error.IoUnavailable => {
                try stderr.writeAll("`lace build` requires process I/O for package traversal.\n");
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

        const program = backend.prepareProgram(arena, &diagnostics, &self.files, loaded.documents) catch |err| switch (err) {
            error.DiagnosticsPresent => null,
            else => return err,
        };
        if (diagnostics.count() != 0 or program == null) {
            if (options.json) {
                try self.renderCheckJson(stdout, &diagnostics);
                try stdout.writeByte('\n');
            } else {
                try self.renderDiagnostics(stderr, &diagnostics);
            }
            return 1;
        }

        const entry = self.resolveEntry(arena, package_root, manifest, loaded.documents) catch |err| switch (err) {
            error.MissingBuildEntry => {
                try stderr.writeAll("`lace build` requires a `[build]` section with an entry file.\n");
                return 1;
            },
            error.EntryNotFound => {
                try stderr.writeAll("The manifest entry target was not found in the loaded package sources.\n");
                return 1;
            },
            else => return err,
        };
        const artifact_path = try self.writeBuildArtifact(arena, io, package_root, manifest.package.name, entry.module_path, loaded.paths);

        if (options.json) {
            var json: std.json.Stringify = .{ .writer = stdout, .options = .{} };
            try json.beginObject();
            try json.objectField("status");
            try json.write("ok");
            try json.objectField("artifact");
            try json.write(artifact_path);
            try json.endObject();
            try stdout.writeByte('\n');
        }

        return 0;
    }

    fn executeRunCommand(
        self: *Context,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        args: []const []const u8,
    ) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseRunOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace run [path] [-- arg1 arg2 ...]\n");
            switch (err) {
                error.UnexpectedArgument => try stderr.writeAll("`lace run` accepts at most one path argument before `--`.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace run` flag.\n"),
            }
            return 1;
        };

        const io = self.io orelse {
            try stderr.writeAll("`lace run` requires process I/O.\n");
            return 1;
        };

        const package_root = try self.resolvePackageRoot(arena, io, options.path);
        const manifest = self.loadManifestFromRoot(arena, io, package_root) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.writeAll("`lace run` requires a package with `lace.toml`.\n");
                return 1;
            },
            else => return err,
        };
        defer {
            var manifest_mut = manifest;
            manifest_mut.deinit(arena);
        }

        var diagnostics: diag.Store = .{};
        const loaded = self.loadDocuments(arena, &diagnostics, .{ .package = .{ .root = package_root } }, true) catch |err| switch (err) {
            error.IoUnavailable => {
                try stderr.writeAll("`lace run` requires process I/O for package traversal.\n");
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

        var program = backend.prepareProgram(arena, &diagnostics, &self.files, loaded.documents) catch |err| switch (err) {
            error.DiagnosticsPresent => null,
            else => return err,
        };
        if (diagnostics.count() != 0 or program == null) {
            try self.renderDiagnostics(stderr, &diagnostics);
            return 1;
        }

        const entry = self.resolveEntry(arena, package_root, manifest, loaded.documents) catch |err| switch (err) {
            error.MissingBuildEntry => {
                try stderr.writeAll("`lace run` requires a `[build]` section with an entry file.\n");
                return 1;
            },
            error.EntryNotFound => {
                try stderr.writeAll("The manifest entry target was not found in the loaded package sources.\n");
                return 1;
            },
            else => return err,
        };
        const result = try backend.runEntry(&program.?, stdout, entry.module_path, "main", options.forwarded_args);
        return switch (result) {
            .variant => |variant| if (std.mem.eql(u8, variant.owner_module_path, "builtin") and std.mem.eql(u8, variant.owner_name, "Result") and std.mem.eql(u8, variant.name, "Err")) 1 else 0,
            else => 0,
        };
    }

    fn executeTypesCommand(
        self: *Context,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        args: []const []const u8,
    ) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseTypesOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace types --json [path]\n");
            switch (err) {
                error.MissingJsonFlag => try stderr.writeAll("`lace types` currently requires `--json`.\n"),
                error.UnexpectedArgument => try stderr.writeAll("`lace types` accepts at most one path argument.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace types` flag.\n"),
            }
            return 1;
        };

        const io = self.io orelse {
            try stderr.writeAll("`lace types` requires process I/O.\n");
            return 1;
        };

        const package_root = try self.resolveTypesPackageRoot(arena, io, options.path);
        const manifest = self.loadManifestFromRoot(arena, io, package_root) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.writeAll("`lace types` requires a package with `lace.toml`.\n");
                return 1;
            },
            else => return err,
        };
        defer {
            var manifest_mut = manifest;
            manifest_mut.deinit(arena);
        }

        var diagnostics: diag.Store = .{};
        const loaded = self.loadDocuments(arena, &diagnostics, .{ .package = .{ .root = package_root } }, true) catch |err| switch (err) {
            error.IoUnavailable => {
                try stderr.writeAll("`lace types` requires process I/O for package traversal.\n");
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

        const surface = try sem.typecheckDocuments(arena, &diagnostics, &self.files, loaded.documents);
        if (diagnostics.count() != 0) {
            try self.renderDiagnostics(stderr, &diagnostics);
            return 1;
        }

        const module_paths = try self.selectedTypesModules(arena, package_root, options.path, loaded.documents);
        if (module_paths.len == 0) {
            try stderr.writeAll("No exported modules matched the requested target.\n");
            return 1;
        }
        try sem.renderTypesJson(arena, stdout, manifest.package.name, surface, module_paths);
        try stdout.writeByte('\n');
        return 0;
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
        const loaded = self.loadDocuments(arena, &diagnostics, sourceTargetFromPath(options.path), true) catch |err| switch (err) {
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

    fn executeFetchCommand(self: *Context, stderr: *Io.Writer, args: []const []const u8) !u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const options = cli.parseFetchOptions(args) catch |err| {
            try stderr.writeAll("Usage: lace fetch [path]\n");
            switch (err) {
                error.UnexpectedArgument => try stderr.writeAll("`lace fetch` accepts at most one package path.\n"),
                error.UnsupportedFlag => try stderr.writeAll("Unsupported `lace fetch` flag.\n"),
            }
            return 1;
        };

        const io = self.io orelse {
            try stderr.writeAll("`lace fetch` requires process I/O.\n");
            return 1;
        };

        const roots = try self.dependencyRoots(arena);
        var diagnostics: diag.Store = .{};
        const package_root = options.path orelse ".";
        const result = try pkg.fetchDependencies(arena, &diagnostics, io, package_root, roots);

        if (result == null or diagnostics.count() != 0) {
            try self.renderDiagnostics(stderr, &diagnostics);
            return 1;
        }

        return 0;
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
        include_dependencies: bool,
    ) !LoadedDocuments {
        if (include_dependencies) {
            switch (target) {
                .package => |package_target| {
                    const workspace_sources = try pkg.collectWorkspaceSources(arena, diagnostics, self.io orelse return error.IoUnavailable, package_target, try self.dependencyRoots(arena));
                    if (workspace_sources.len == 0) {
                        return error.NoSourceFiles;
                    }

                    var workspace_paths: std.ArrayList([]const u8) = .empty;
                    var workspace_documents: std.ArrayList(syntax.Tree.Document) = .empty;
                    for (workspace_sources) |entry| {
                        const contents = try std.Io.Dir.cwd().readFileAlloc(self.io.?, entry.actual_path, arena, .unlimited);
                        const file_id = try self.addSource(entry.logical_path, contents);
                        try workspace_paths.append(arena, entry.logical_path);
                        const document = syntax.parseFile(arena, diagnostics, self.sourceFile(file_id)) catch |err| switch (err) {
                            error.InvalidSyntax => continue,
                            error.OutOfMemory => return err,
                        };
                        try workspace_documents.append(arena, document);
                    }

                    return .{
                        .paths = try workspace_paths.toOwnedSlice(arena),
                        .documents = try workspace_documents.toOwnedSlice(arena),
                    };
                },
                .single_file => {},
            }
        }

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

    fn resolvePackageRoot(self: *const Context, allocator: std.mem.Allocator, io: Io, path: ?[]const u8) ![]const u8 {
        if (path) |value| {
            if (std.mem.endsWith(u8, value, ".lace")) {
                return try self.findPackageRootForFile(allocator, io, value) orelse error.FileNotFound;
            }
            return allocator.dupe(u8, value);
        }
        return allocator.dupe(u8, ".");
    }

    fn resolveEntry(
        self: *const Context,
        allocator: std.mem.Allocator,
        package_root: []const u8,
        manifest: pkg.Manifest,
        documents: []const syntax.Tree.Document,
    ) !EntryTarget {
        const build = manifest.build orelse return error.MissingBuildEntry;
        const entry_path = if (std.mem.eql(u8, package_root, "."))
            build.entry
        else
            try std.fs.path.join(allocator, &.{ package_root, build.entry });
        defer if (!std.mem.eql(u8, package_root, ".")) allocator.free(entry_path);

        for (documents) |document| {
            const file = self.sourceFile(document.file_id);
            if (std.mem.eql(u8, file.path, entry_path)) {
                return .{
                    .path = build.entry,
                    .module_path = file.source[document.module_decl.path.span.start..document.module_decl.path.span.end],
                };
            }
        }
        return error.EntryNotFound;
    }

    fn writeBuildArtifact(
        self: *Context,
        allocator: std.mem.Allocator,
        io: Io,
        package_root: []const u8,
        package_name: []const u8,
        entry_module_path: []const u8,
        source_paths: []const []const u8,
    ) ![]const u8 {
        _ = self;
        const build_dir = if (std.mem.eql(u8, package_root, "."))
            try allocator.dupe(u8, "build")
        else
            try std.fs.path.join(allocator, &.{ package_root, "build" });
        defer allocator.free(build_dir);
        try std.Io.Dir.cwd().createDirPath(io, build_dir);

        const artifact_path = if (std.mem.eql(u8, package_root, "."))
            try allocator.dupe(u8, "build/program.json")
        else
            try std.fs.path.join(allocator, &.{ package_root, "build", "program.json" });

        var json_out = std.Io.Writer.Allocating.init(allocator);
        defer json_out.deinit();
        var json: std.json.Stringify = .{ .writer = &json_out.writer, .options = .{} };
        try json.beginObject();
        try json.objectField("backend");
        try json.write("interpreter");
        try json.objectField("package");
        try json.write(package_name);
        try json.objectField("entry_module");
        try json.write(entry_module_path);
        try json.objectField("entry_function");
        try json.write("main");
        try json.objectField("sources");
        try json.beginArray();
        for (source_paths) |path| {
            try json.write(path);
        }
        try json.endArray();
        try json.endObject();

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = artifact_path, .data = json_out.written() });
        return artifact_path;
    }

    fn defaultInitPackageName(allocator: std.mem.Allocator, io: Io) ![]const u8 {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        const base = std.fs.path.basename(cwd);
        return try std.fmt.allocPrint(allocator, "example.com/{s}", .{base});
    }

    fn resolveTypesPackageRoot(self: *const Context, allocator: std.mem.Allocator, io: Io, path: ?[]const u8) ![]const u8 {
        if (path) |value| {
            if (std.mem.endsWith(u8, value, ".lace")) {
                return try self.findPackageRootForFile(allocator, io, value) orelse error.FileNotFound;
            }
            return allocator.dupe(u8, value);
        }
        return allocator.dupe(u8, ".");
    }

    fn findPackageRootForFile(self: *const Context, allocator: std.mem.Allocator, io: Io, file_path: []const u8) !?[]const u8 {
        _ = self;
        var current = try allocator.dupe(u8, std.fs.path.dirname(file_path) orelse ".");
        while (true) {
            const manifest_path = try std.fs.path.join(allocator, &.{ current, "lace.toml" });
            defer allocator.free(manifest_path);

            var file = std.Io.Dir.cwd().openFile(io, manifest_path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => null,
                else => return err,
            };
            if (file) |*opened| {
                opened.close(io);
                return current;
            }

            const parent = std.fs.path.dirname(current) orelse return null;
            if (std.mem.eql(u8, parent, current)) {
                return null;
            }
            current = try allocator.dupe(u8, parent);
        }
    }

    fn loadManifestFromRoot(self: *const Context, allocator: std.mem.Allocator, io: Io, root: []const u8) !pkg.Manifest {
        _ = self;
        const manifest_path = try std.fs.path.join(allocator, &.{ root, "lace.toml" });
        defer allocator.free(manifest_path);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer allocator.free(contents);
        return try pkg.parseManifest(allocator, contents);
    }

    fn selectedTypesModules(
        self: *const Context,
        allocator: std.mem.Allocator,
        package_root: []const u8,
        path: ?[]const u8,
        documents: []const syntax.Tree.Document,
    ) ![]const []const u8 {
        var modules = std.ArrayList([]const u8).empty;
        if (path) |value| {
            if (std.mem.endsWith(u8, value, ".lace")) {
                for (documents) |document| {
                    const file = self.sourceFile(document.file_id);
                    if (std.mem.eql(u8, file.path, value)) {
                        try modules.append(allocator, file.source[document.module_decl.path.span.start..document.module_decl.path.span.end]);
                        return try modules.toOwnedSlice(allocator);
                    }
                }
                return try modules.toOwnedSlice(allocator);
            }
        }

        const prefix = if (std.mem.eql(u8, package_root, ".")) "src/" else try std.fs.path.join(allocator, &.{ package_root, "src" });
        defer if (!std.mem.eql(u8, package_root, ".")) allocator.free(prefix);
        for (documents) |document| {
            const file = self.sourceFile(document.file_id);
            if (std.mem.startsWith(u8, file.path, prefix)) {
                try modules.append(allocator, file.source[document.module_decl.path.span.start..document.module_decl.path.span.end]);
            }
        }
        return try modules.toOwnedSlice(allocator);
    }

    fn dependencyRoots(self: *const Context, allocator: std.mem.Allocator) !pkg.DependencyRoots {
        return self.dependency_roots orelse try pkg.defaultDependencyRoots(allocator);
    }
};

const EntryTarget = struct {
    path: []const u8,
    module_path: []const u8,
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

test "context executes fetch for a package root" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.createDirPath(std.testing.io, "registry/github.com/sam/user/0.1.0/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/user/0.1.0/lace.toml", .data = "[package]\nname = \"github.com/sam/user\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "registry/github.com/sam/user/0.1.0/src/model.lace", .data = "module github.com/sam/user/model;\n" });

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/lace.toml", .data = "[package]\nname = \"github.com/sam/app\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\"github.com/sam/user\" = \"0.1.0\"\n" });

    const registry_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "registry" });
    defer std.testing.allocator.free(registry_root);
    const cache_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "cache" });
    defer std.testing.allocator.free(cache_root);
    const app_root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "app" });
    defer std.testing.allocator.free(app_root);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = Context.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    context.dependency_roots = .{ .registry_root = registry_root, .cache_root = cache_root };

    const exit_code = try context.execute(
        &stdout.writer,
        &stderr.writer,
        .{ .kind = .fetch, .args = &.{app_root} },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());

    const lock_text = try tmp.dir.readFileAlloc(std.testing.io, "app/lace.lock", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(lock_text);
    try std.testing.expect(std.mem.indexOf(u8, lock_text, "github.com/sam/user") != null);
}

test "context executes build json for a package root" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "pkg/src/app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/lace.toml", .data =
        "[package]\nname = \"github.com/sam/build-demo\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\n[build]\nsrc = \"src\"\nentry = \"src/app/main.lace\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/src/app/main.lace", .data =
        "module app/main;\n\nfn main() -> Result<Void, AppError> {\n    return Ok(Void);\n}\n\npub error AppError {\n    placeholder,\n}\n" });

    const package_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "pkg" });
    defer std.testing.allocator.free(package_root);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = Context.init(std.testing.allocator, std.testing.io);
    defer context.deinit();

    const exit_code = try context.execute(
        &stdout.writer,
        &stderr.writer,
        .{ .kind = .build, .args = &.{ "--json", package_root } },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "build/program.json") != null);

    const artifact = try tmp.dir.readFileAlloc(std.testing.io, "pkg/build/program.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(artifact);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"backend\":\"interpreter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"entry_module\":\"app/main\"") != null);
}

test "context executes run and forwards args to main list parameter" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "pkg/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/lace.toml", .data =
        "[package]\nname = \"github.com/sam/run-demo\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\n[build]\nsrc = \"src\"\nentry = \"src/main.lace\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/src/main.lace", .data =
        "module main;\n\npub error AppError {\n    placeholder,\n}\n\nfn main(\n    args: List<String>,\n) -> Result<Void, AppError> {\n    print(value: args);\n    return Ok(Void);\n}\n" });

    const package_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "pkg" });
    defer std.testing.allocator.free(package_root);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = Context.init(std.testing.allocator, std.testing.io);
    defer context.deinit();

    const exit_code = try context.execute(
        &stdout.writer,
        &stderr.writer,
        .{ .kind = .run, .args = &.{ package_root, "--", "one", "two" } },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqualStrings("[one, two]", stdout.written());
}

test "context executes types json for a package root" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "pkg/src/app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/lace.toml", .data = "[package]\nname = \"github.com/sam/signup\"\nversion = \"0.1.0\"\nedition = \"2026\"\n\n[dependencies]\n\n[build]\nsrc = \"src\"\nentry = \"src/app/signup.lace\"\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/src/app/signup.lace", .data = "module app/signup;\n\npub struct User {\n    email: String,\n}\n\npub error SignupError {\n    duplicate_email(email: String),\n}\n\npub fn signup(\n    input: User,\n) -> Result<User, SignupError> {\n    return Ok(input);\n}\n" });

    const tmp_root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "pkg" });
    defer std.testing.allocator.free(tmp_root);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context = Context.init(std.testing.allocator, std.testing.io);
    defer context.deinit();

    const exit_code = try context.execute(
        &stdout.writer,
        &stderr.writer,
        .{ .kind = .types, .args = &.{ "--json", tmp_root } },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqualStrings(
        "{\"package\":\"github.com/sam/signup\",\"module\":\"app/signup\",\"structs\":[{\"name\":\"User\",\"fields\":[{\"name\":\"email\",\"type\":\"String\",\"optional\":false}]}],\"enums\":[],\"errors\":[{\"name\":\"SignupError\",\"variants\":[{\"name\":\"duplicate_email\",\"fields\":[{\"name\":\"email\",\"type\":\"String\"}]}]}],\"functions\":[{\"name\":\"signup\",\"params\":[{\"name\":\"input\",\"type\":\"User\"}],\"returns\":\"Result<User, SignupError>\"}]}\n",
        stdout.written(),
    );
}
