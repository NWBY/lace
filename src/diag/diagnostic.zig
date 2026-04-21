const std = @import("std");
const source = @import("../source.zig");

pub const Level = enum {
    note,
    warning,
    @"error",

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .note => "note",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

pub const Detail = struct {
    key: []const u8,
    value: []const u8,
};

pub const SuggestedFix = struct {
    kind: []const u8,
    text: []const u8,
};

pub const Diagnostic = struct {
    level: Level = .@"error",
    code: []const u8,
    message: []const u8,
    span: ?source.Span = null,
    symbol: ?[]const u8 = null,
    details: []const Detail = &.{},
    suggested_fixes: []const SuggestedFix = &.{},
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
