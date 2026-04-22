const std = @import("std");

const types = @import("types.zig");

pub fn renderTypesJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    package_name: []const u8,
    surface: types.PackageSurface,
    module_paths: []const []const u8,
) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    var selected_modules = std.ArrayList(types.ModuleSurface).empty;
    defer selected_modules.deinit(allocator);

    for (surface.modules) |module| {
        if (!containsModule(module_paths, module.path)) continue;
        try selected_modules.append(allocator, module);
    }

    if (selected_modules.items.len == 1) {
        try writeModuleManifest(allocator, &json, package_name, selected_modules.items[0]);
        return;
    }

    try json.beginObject();
    try json.objectField("package");
    try json.write(package_name);
    try json.objectField("modules");
    try json.beginArray();
    for (selected_modules.items) |module| {
        try writeModuleEntry(allocator, &json, module);
    }
    try json.endArray();
    try json.endObject();
}

fn writeModuleManifest(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    package_name: []const u8,
    module: types.ModuleSurface,
) !void {
    try json.beginObject();
    try json.objectField("package");
    try json.write(package_name);
    try json.objectField("module");
    try json.write(module.path);
    try json.objectField("structs");
    try writeStructs(allocator, json, module);
    try json.objectField("enums");
    try writeEnums(allocator, json, module);
    try json.objectField("errors");
    try writeErrors(allocator, json, module);
    try json.objectField("functions");
    try writeFunctions(allocator, json, module);
    try json.endObject();
}

fn writeModuleEntry(allocator: std.mem.Allocator, json: *std.json.Stringify, module: types.ModuleSurface) !void {
    try json.beginObject();
    try json.objectField("module");
    try json.write(module.path);
    try json.objectField("structs");
    try writeStructs(allocator, json, module);
    try json.objectField("enums");
    try writeEnums(allocator, json, module);
    try json.objectField("errors");
    try writeErrors(allocator, json, module);
    try json.objectField("functions");
    try writeFunctions(allocator, json, module);
    try json.endObject();
}

fn writeStructs(allocator: std.mem.Allocator, json: *std.json.Stringify, module: types.ModuleSurface) !void {
    try json.beginArray();
    for (module.structs) |item| {
        if (item.visibility != .public) continue;
        try json.beginObject();
        try json.objectField("name");
        try json.write(item.name);
        try json.objectField("fields");
        try json.beginArray();
        for (item.fields) |field| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(field.name);
            try json.objectField("type");
            const ty = try types.renderTypeAlloc(allocator, module.path, field.ty);
            defer allocator.free(ty);
            try json.write(ty);
            try json.objectField("optional");
            try json.write(isOptionType(field.ty));
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
}

fn writeEnums(allocator: std.mem.Allocator, json: *std.json.Stringify, module: types.ModuleSurface) !void {
    try json.beginArray();
    for (module.enums) |item| {
        if (item.visibility != .public) continue;
        try json.beginObject();
        try json.objectField("name");
        try json.write(item.name);
        try json.objectField("variants");
    try json.beginArray();
    for (item.variants) |variant| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(variant.name);
        try json.objectField("fields");
        try json.beginArray();
        for (variant.fields) |field| {
            try writeFieldRecordWithAlloc(allocator, json, module.path, field);
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
        try json.endObject();
    }
    try json.endArray();
}

fn writeErrors(allocator: std.mem.Allocator, json: *std.json.Stringify, module: types.ModuleSurface) !void {
    try json.beginArray();
    for (module.errors) |item| {
        if (item.visibility != .public) continue;
        try json.beginObject();
        try json.objectField("name");
        try json.write(item.name);
        try json.objectField("variants");
        try json.beginArray();
        for (item.variants) |variant| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(variant.name);
            try json.objectField("fields");
            try json.beginArray();
            for (variant.fields) |field| {
                try writeFieldRecordWithAlloc(allocator, json, module.path, field);
            }
            try json.endArray();
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
}

fn writeFunctions(allocator: std.mem.Allocator, json: *std.json.Stringify, module: types.ModuleSurface) !void {
    try json.beginArray();
    for (module.functions) |function| {
        if (function.visibility != .public) continue;
        try json.beginObject();
        try json.objectField("name");
        try json.write(function.name);
        try json.objectField("params");
        try json.beginArray();
        for (function.params) |param| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(param.name);
            try json.objectField("type");
            const param_type = try types.renderTypeAlloc(allocator, module.path, param.ty);
            defer allocator.free(param_type);
            try json.write(param_type);
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("returns");
        const return_type = try types.renderTypeAlloc(allocator, module.path, function.return_type);
        defer allocator.free(return_type);
        try json.write(return_type);
        try json.endObject();
    }
    try json.endArray();
}

fn writeFieldRecordWithAlloc(allocator: std.mem.Allocator, json: *std.json.Stringify, current_module_path: []const u8, field: types.FieldSurface) !void {
    try json.beginObject();
    try json.objectField("name");
    try json.write(field.name);
    try json.objectField("type");
    const rendered = try types.renderTypeAlloc(allocator, current_module_path, field.ty);
    defer allocator.free(rendered);
    try json.write(rendered);
    try json.endObject();
}

fn containsModule(paths: []const []const u8, module_path: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, module_path)) return true;
    }
    return false;
}

fn isOptionType(ty: types.Type) bool {
    return switch (ty) {
        .generic => |value| value.kind == .option,
        else => false,
    };
}

test "types json is stable for a single module manifest" {
    const allocator = std.testing.allocator;
    const user_type: types.Type = .{ .named = .{ .module_path = "app/signup", .name = "User", .kind = .struct_type } };
    const error_type: types.Type = .{ .named = .{ .module_path = "app/signup", .name = "SignupError", .kind = .error_type } };
    const result_type: types.Type = .{ .generic = .{ .kind = .result, .args = &.{ user_type, error_type } } };

    const surface = types.PackageSurface{
        .modules = &.{.{
            .path = "app/signup",
            .types = &.{},
            .structs = &.{.{
                .module_path = "app/signup",
                .name = "User",
                .fields = &.{.{ .name = "email", .ty = .{ .primitive = .string } }},
                .visibility = .public,
            }},
            .enums = &.{},
            .errors = &.{.{
                .module_path = "app/signup",
                .name = "SignupError",
                .variants = &.{.{ .name = "duplicate_email", .fields = &.{.{ .name = "email", .ty = .{ .primitive = .string } }} }},
                .visibility = .public,
            }},
            .functions = &.{.{
                .module_path = "app/signup",
                .name = "signup",
                .params = &.{.{ .name = "input", .ty = user_type }},
                .return_type = result_type,
                .visibility = .public,
            }},
        }},
    };

    var first = std.Io.Writer.Allocating.init(allocator);
    defer first.deinit();
    try renderTypesJson(allocator, &first.writer, "github.com/sam/signup", surface, &.{"app/signup"});

    var second = std.Io.Writer.Allocating.init(allocator);
    defer second.deinit();
    try renderTypesJson(allocator, &second.writer, "github.com/sam/signup", surface, &.{"app/signup"});

    try std.testing.expectEqualStrings(first.written(), second.written());
    try std.testing.expectEqualStrings(
        "{\"package\":\"github.com/sam/signup\",\"module\":\"app/signup\",\"structs\":[{\"name\":\"User\",\"fields\":[{\"name\":\"email\",\"type\":\"String\",\"optional\":false}]}],\"enums\":[],\"errors\":[{\"name\":\"SignupError\",\"variants\":[{\"name\":\"duplicate_email\",\"fields\":[{\"name\":\"email\",\"type\":\"String\"}]}]}],\"functions\":[{\"name\":\"signup\",\"params\":[{\"name\":\"input\",\"type\":\"User\"}],\"returns\":\"Result<User, SignupError>\"}]}",
        first.written(),
    );
}
