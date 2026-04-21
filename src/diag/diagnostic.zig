const std = @import("std");

pub const Level = enum {
    note,
    warning,
    @"error",
};

pub const Diagnostic = struct {
    level: Level = .@"error",
    code: []const u8,
    message: []const u8,
    path: ?[]const u8 = null,
};

pub const Store = struct {
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(self: *Store, allocator: std.mem.Allocator, diagnostic: Diagnostic) !void {
        try self.items.append(allocator, diagnostic);
    }

    pub fn count(self: *const Store) usize {
        return self.items.items.len;
    }

    pub fn hasErrors(self: *const Store) bool {
        for (self.items.items) |diagnostic| {
            if (diagnostic.level == .@"error") {
                return true;
            }
        }

        return false;
    }
};
