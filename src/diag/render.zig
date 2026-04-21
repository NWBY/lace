const std = @import("std");
const source = @import("../source.zig");

const diagnostic = @import("diagnostic.zig");

pub fn renderText(
    writer: *std.Io.Writer,
    sources: *const source.Manager,
    value: diagnostic.Diagnostic,
) !void {
    try writer.print("{s}[{s}]: {s}\n", .{
        value.level.label(),
        value.code,
        value.message,
    });

    if (value.span) |span| {
        const resolved = sources.resolveSpan(span);
        try writer.print("  --> {s}:{d}:{d}\n", .{
            resolved.path,
            resolved.start.line,
            resolved.start.column,
        });
    }

    if (value.symbol) |symbol| {
        try writer.print("  = symbol: {s}\n", .{symbol});
    }

    for (value.details) |detail| {
        try writer.print("  = {s}: {s}\n", .{ detail.key, detail.value });
    }

    for (value.suggested_fixes) |fix| {
        try writer.print("  = fix ({s}): {s}\n", .{ fix.kind, fix.text });
    }
}

pub fn renderJson(
    writer: *std.Io.Writer,
    sources: *const source.Manager,
    value: diagnostic.Diagnostic,
) !void {
    const span_json = if (value.span) |span|
        toSpanJson(sources.resolveSpan(span))
    else
        null;

    const file_path = if (value.span) |span|
        sources.getFile(span.file_id).path
    else
        null;

    const payload = .{
        .code = value.code,
        .level = value.level.label(),
        .message = value.message,
        .file = file_path,
        .span = span_json,
        .symbol = value.symbol,
        .details = value.details,
        .suggested_fixes = value.suggested_fixes,
    };

    try std.json.Stringify.value(payload, .{}, writer);
}

fn toSpanJson(resolved: source.ResolvedSpan) struct {
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
} {
    return .{
        .start_line = resolved.start.line,
        .start_col = resolved.start.column,
        .end_line = resolved.end.line,
        .end_col = resolved.end.column,
    };
}

test "diagnostics render as text and json" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/app/signup.lace",
        "module app/signup;\nlet user = User{};\n",
    );

    const value: diagnostic.Diagnostic = .{
        .code = "E1042",
        .message = "Missing required struct field",
        .span = source.Span.init(file_id, 29, 35),
        .symbol = "User",
        .details = &.{
            .{ .key = "missing_field", .value = "email: String" },
        },
        .suggested_fixes = &.{
            .{ .kind = "insert_struct_field", .text = "email: <value>," },
        },
    };

    var text_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text_output.deinit();
    try renderText(&text_output.writer, &sources, value);

    const expected_text =
        "error[E1042]: Missing required struct field\n" ++
        "  --> src/app/signup.lace:2:11\n" ++
        "  = symbol: User\n" ++
        "  = missing_field: email: String\n" ++
        "  = fix (insert_struct_field): email: <value>,\n";
    try std.testing.expectEqualStrings(expected_text, text_output.written());

    var json_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json_output.deinit();
    try renderJson(&json_output.writer, &sources, value);

    const expected_json =
        "{" ++
        "\"code\":\"E1042\"," ++
        "\"level\":\"error\"," ++
        "\"message\":\"Missing required struct field\"," ++
        "\"file\":\"src/app/signup.lace\"," ++
        "\"span\":{" ++
        "\"start_line\":2," ++
        "\"start_col\":11," ++
        "\"end_line\":2," ++
        "\"end_col\":17}," ++
        "\"symbol\":\"User\"," ++
        "\"details\":[{" ++
        "\"key\":\"missing_field\"," ++
        "\"value\":\"email: String\"}]," ++
        "\"suggested_fixes\":[{" ++
        "\"kind\":\"insert_struct_field\"," ++
        "\"text\":\"email: <value>,\"}]" ++
        "}";
    try std.testing.expectEqualStrings(expected_json, json_output.written());
}
