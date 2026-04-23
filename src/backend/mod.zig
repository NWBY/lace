pub const ExecutionError = @import("interpreter.zig").ExecutionError;
pub const Program = @import("interpreter.zig").Program;
pub const TestCase = @import("interpreter.zig").TestCase;
pub const TestResult = @import("interpreter.zig").TestResult;
pub const TestStatus = @import("interpreter.zig").TestStatus;
pub const discoverTests = @import("interpreter.zig").discoverTests;
pub const Value = @import("interpreter.zig").Value;
pub const prepareProgram = @import("interpreter.zig").prepareProgram;
pub const runEntry = @import("interpreter.zig").runEntry;
pub const runFunction = @import("interpreter.zig").runFunction;
pub const runMain = @import("interpreter.zig").runMain;
pub const runTestCase = @import("interpreter.zig").runTestCase;

test {
    _ = @import("interpreter.zig");
}
