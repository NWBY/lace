pub const ExecutionError = @import("interpreter.zig").ExecutionError;
pub const Program = @import("interpreter.zig").Program;
pub const Value = @import("interpreter.zig").Value;
pub const prepareProgram = @import("interpreter.zig").prepareProgram;
pub const runFunction = @import("interpreter.zig").runFunction;
pub const runMain = @import("interpreter.zig").runMain;

test {
    _ = @import("interpreter.zig");
}
