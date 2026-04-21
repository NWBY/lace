pub const Kind = enum(u8) {
    source_file,
    ast_node,
    symbol,
};

pub const StableId = struct {
    kind: Kind,
    index: u32,
};

pub const Generator = struct {
    next_indices: [3]u32 = .{ 0, 0, 0 },

    pub fn next(self: *Generator, kind: Kind) StableId {
        const slot = @intFromEnum(kind);
        const index = self.next_indices[slot];
        self.next_indices[slot] += 1;
        return .{
            .kind = kind,
            .index = index,
        };
    }
};
