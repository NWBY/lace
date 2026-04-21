const std = @import("std");
const Io = std.Io;

pub const FileId = enum(u32) {
    _,

    pub fn fromIndex(value: usize) FileId {
        return @enumFromInt(value);
    }

    pub fn index(self: FileId) usize {
        return @intFromEnum(self);
    }
};

pub const Location = struct {
    line: usize,
    column: usize,
};

pub const Span = struct {
    file_id: FileId,
    start: usize,
    end: usize,

    pub fn init(file_id: FileId, start: usize, end: usize) Span {
        return .{
            .file_id = file_id,
            .start = start,
            .end = end,
        };
    }

    pub fn slice(self: Span, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
};

pub const ResolvedSpan = struct {
    path: []const u8,
    start: Location,
    end: Location,
};

pub const File = struct {
    id: FileId,
    path: []const u8,
    source: []const u8,
    line_starts: std.ArrayList(usize),

    fn deinit(self: *File, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        self.line_starts.deinit(allocator);
        self.* = undefined;
    }

    pub fn location(self: *const File, offset: usize) Location {
        const bounded_offset = @min(offset, self.source.len);
        var low: usize = 0;
        var high: usize = self.line_starts.items.len;
        var line_index: usize = 0;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.line_starts.items[mid] <= bounded_offset) {
                line_index = mid;
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        const line_start = self.line_starts.items[line_index];
        return .{
            .line = line_index + 1,
            .column = bounded_offset - line_start + 1,
        };
    }
};

pub const Manager = struct {
    files: std.ArrayList(File) = .empty,

    pub fn deinit(self: *Manager, allocator: std.mem.Allocator) void {
        for (self.files.items) |*loaded_file| {
            loaded_file.deinit(allocator);
        }
        self.files.deinit(allocator);
        self.* = undefined;
    }

    pub fn loadFile(
        self: *Manager,
        allocator: std.mem.Allocator,
        io: Io,
        path: []const u8,
    ) !FileId {
        if (self.findByPath(path)) |file_id| {
            return file_id;
        }

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const owned_source = try std.fs.cwd().readFileAlloc(io, path, allocator, .unlimited);
        errdefer allocator.free(owned_source);

        return self.appendOwned(allocator, owned_path, owned_source);
    }

    pub fn addSource(
        self: *Manager,
        allocator: std.mem.Allocator,
        path: []const u8,
        source: []const u8,
    ) !FileId {
        if (self.findByPath(path)) |file_id| {
            return file_id;
        }

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);

        return self.appendOwned(allocator, owned_path, owned_source);
    }

    pub fn getFile(self: *const Manager, file_id: FileId) *const File {
        return &self.files.items[file_id.index()];
    }

    pub fn resolveSpan(self: *const Manager, span: Span) ResolvedSpan {
        const loaded_file = self.getFile(span.file_id);
        return .{
            .path = loaded_file.path,
            .start = loaded_file.location(span.start),
            .end = loaded_file.location(span.end),
        };
    }

    fn appendOwned(
        self: *Manager,
        allocator: std.mem.Allocator,
        owned_path: []const u8,
        owned_source: []const u8,
    ) !FileId {
        var line_starts: std.ArrayList(usize) = .empty;
        errdefer line_starts.deinit(allocator);

        try line_starts.append(allocator, 0);
        for (owned_source, 0..) |byte, index| {
            if (byte == '\n') {
                try line_starts.append(allocator, index + 1);
            }
        }

        const file_id = FileId.fromIndex(self.files.items.len);
        try self.files.append(allocator, .{
            .id = file_id,
            .path = owned_path,
            .source = owned_source,
            .line_starts = line_starts,
        });
        return file_id;
    }

    fn findByPath(self: *const Manager, path: []const u8) ?FileId {
        for (self.files.items) |loaded_file| {
            if (std.mem.eql(u8, loaded_file.path, path)) {
                return loaded_file.id;
            }
        }

        return null;
    }
};

test "source manager resolves line and column positions" {
    var manager: Manager = .{};
    defer manager.deinit(std.testing.allocator);

    const file_id = try manager.addSource(
        std.testing.allocator,
        "src/demo.lace",
        "module demo;\nlet name = \"sam\";\n",
    );

    const loaded_file = manager.getFile(file_id);
    const start = loaded_file.location(13);
    const end = loaded_file.location(24);

    try std.testing.expectEqual(@as(usize, 2), start.line);
    try std.testing.expectEqual(@as(usize, 1), start.column);
    try std.testing.expectEqual(@as(usize, 2), end.line);
    try std.testing.expectEqual(@as(usize, 12), end.column);
}
