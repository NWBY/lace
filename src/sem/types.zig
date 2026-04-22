const std = @import("std");

const source = @import("../source.zig");
const tree = @import("../syntax/tree.zig");
const syntax = @import("../syntax/mod.zig");

pub const Primitive = enum {
    bool,
    int,
    float,
    string,
    bytes,
    void,
};

pub const GenericKind = enum {
    option,
    result,
    list,
    map,
    set,
};

pub const NamedKind = enum {
    struct_type,
    enum_type,
    error_type,
};

pub const Type = union(enum) {
    primitive: Primitive,
    generic: GenericInstance,
    named: NamedType,
    type_parameter: []const u8,

    pub fn eql(left: Type, right: Type) bool {
        switch (left) {
            .primitive => |value| return switch (right) {
                .primitive => |other| value == other,
                else => false,
            },
            .type_parameter => |value| return switch (right) {
                .type_parameter => |other| std.mem.eql(u8, value, other),
                else => false,
            },
            .named => |value| return switch (right) {
                .named => |other| std.mem.eql(u8, value.module_path, other.module_path) and
                    std.mem.eql(u8, value.name, other.name) and
                    value.kind == other.kind,
                else => false,
            },
            .generic => |value| return switch (right) {
                .generic => |other| {
                    if (value.kind != other.kind or value.args.len != other.args.len) {
                        return false;
                    }
                    for (value.args, other.args) |value_arg, other_arg| {
                        if (!value_arg.eql(other_arg)) {
                            return false;
                        }
                    }
                    return true;
                },
                else => false,
            },
        }
    }
};

pub const GenericInstance = struct {
    kind: GenericKind,
    args: []const Type,
};

pub const NamedType = struct {
    module_path: []const u8,
    name: []const u8,
    kind: NamedKind,
};

pub const Param = struct {
    name: []const u8,
    ty: Type,
};

pub const FieldSurface = struct {
    name: []const u8,
    ty: Type,
};

pub const VariantSurface = struct {
    name: []const u8,
    fields: []const FieldSurface,
};

pub const StructSurface = struct {
    module_path: []const u8,
    name: []const u8,
    fields: []const FieldSurface,
    visibility: tree.Visibility,
};

pub const EnumSurface = struct {
    module_path: []const u8,
    name: []const u8,
    variants: []const VariantSurface,
    visibility: tree.Visibility,
};

pub const ErrorSurface = struct {
    module_path: []const u8,
    name: []const u8,
    variants: []const VariantSurface,
    visibility: tree.Visibility,
};

pub const FunctionSignature = struct {
    module_path: []const u8,
    name: []const u8,
    params: []const Param,
    return_type: Type,
    visibility: tree.Visibility,
};

pub const ModuleSurface = struct {
    path: []const u8,
    types: []const NamedType,
    structs: []const StructSurface,
    enums: []const EnumSurface,
    errors: []const ErrorSurface,
    functions: []const FunctionSignature,
};

pub const PackageSurface = struct {
    modules: []const ModuleSurface,
};

pub const ResolveTypeError = error{
    OutOfMemory,
    UnknownType,
    WrongGenericArity,
};

pub fn renderTypeAlloc(
    allocator: std.mem.Allocator,
    current_module_path: []const u8,
    ty: Type,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeType(&out.writer, current_module_path, ty);
    return try out.toOwnedSlice();
}

pub fn writeType(writer: *std.Io.Writer, current_module_path: []const u8, ty: Type) !void {
    switch (ty) {
        .primitive => |value| try writer.writeAll(switch (value) {
            .bool => "Bool",
            .int => "Int",
            .float => "Float",
            .string => "String",
            .bytes => "Bytes",
            .void => "Void",
        }),
        .type_parameter => |name| try writer.writeAll(name),
        .named => |value| {
            if (std.mem.eql(u8, value.module_path, current_module_path)) {
                try writer.writeAll(value.name);
            } else {
                try writer.print("{s}.{s}", .{ value.module_path, value.name });
            }
        },
        .generic => |value| {
            try writer.writeAll(switch (value.kind) {
                .option => "Option",
                .result => "Result",
                .list => "List",
                .map => "Map",
                .set => "Set",
            });
            try writer.writeByte('<');
            for (value.args, 0..) |arg, index| {
                if (index > 0) {
                    try writer.writeAll(", ");
                }
                try writeType(writer, current_module_path, arg);
            }
            try writer.writeByte('>');
        },
    }
}

pub fn buildPackageSurface(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
) ResolveTypeError!PackageSurface {
    const modules = try allocator.alloc(ModuleSurface, documents.len);
    for (documents, 0..) |document, index| {
        modules[index] = try buildModuleSurface(allocator, sources, documents, document);
    }
    return .{ .modules = modules };
}

pub fn buildModuleSurface(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
) ResolveTypeError!ModuleSurface {
    var types: std.ArrayList(NamedType) = .empty;
    var structs: std.ArrayList(StructSurface) = .empty;
    var enums: std.ArrayList(EnumSurface) = .empty;
    var errors: std.ArrayList(ErrorSurface) = .empty;
    var functions: std.ArrayList(FunctionSignature) = .empty;
    const module_path = modulePathText(sources, document);

    for (document.items) |item| switch (item) {
        .struct_decl => |decl| {
            try types.append(allocator, .{
                .module_path = module_path,
                .name = textAt(sources, document.file_id, decl.name),
                .kind = .struct_type,
            });
            try structs.append(allocator, try buildStructSurface(allocator, sources, documents, document, decl));
        },
        .enum_decl => |decl| {
            try types.append(allocator, .{
                .module_path = module_path,
                .name = textAt(sources, document.file_id, decl.name),
                .kind = .enum_type,
            });
            try enums.append(allocator, try buildEnumSurface(allocator, sources, documents, document, decl));
        },
        .error_decl => |decl| {
            try types.append(allocator, .{
                .module_path = module_path,
                .name = textAt(sources, document.file_id, decl.name),
                .kind = .error_type,
            });
            try errors.append(allocator, try buildErrorSurface(allocator, sources, documents, document, decl));
        },
        .function_decl => |decl| try functions.append(allocator, try buildFunctionSignature(allocator, sources, documents, document, decl)),
        else => {},
    };

    return .{
        .path = module_path,
        .types = try types.toOwnedSlice(allocator),
        .structs = try structs.toOwnedSlice(allocator),
        .enums = try enums.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
        .functions = try functions.toOwnedSlice(allocator),
    };
}

pub fn resolveTypeRef(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
    type_ref: tree.TypeRef,
) ResolveTypeError!Type {
    const path_segments = type_ref.path.segments;
    const final_name = textAt(sources, document.file_id, path_segments[path_segments.len - 1].span);

    if (path_segments.len == 1) {
        if (std.mem.lastIndexOfScalar(u8, final_name, '.')) |dot_index| {
            const alias = final_name[0..dot_index];
            const imported_name = final_name[dot_index + 1 ..];
            if (findImportedModulePath(sources, document, alias)) |module_path| {
                if (findNamedType(sources, documents, module_path, imported_name, true)) |named_type| {
                    return .{ .named = named_type };
                }
            }
        }

        if (primitiveByName(final_name)) |primitive| {
            return .{ .primitive = primitive };
        }

        if (genericByName(final_name)) |generic_kind| {
            const expected_arity = genericArity(generic_kind);
            if (type_ref.arguments.len != expected_arity) {
                return error.WrongGenericArity;
            }

            const args = try allocator.alloc(Type, type_ref.arguments.len);
            for (type_ref.arguments, 0..) |arg, index| {
                args[index] = try resolveTypeRef(allocator, sources, documents, document, arg);
            }
            return .{ .generic = .{ .kind = generic_kind, .args = args } };
        }

        if (findNamedType(sources, documents, modulePathText(sources, document), final_name, false)) |named_type| {
            return .{ .named = named_type };
        }

        return error.UnknownType;
    }

    const module_path = try joinPathPrefix(allocator, sources, document.file_id, path_segments[0 .. path_segments.len - 1]);
    if (findNamedType(sources, documents, module_path, final_name, true)) |named_type| {
        return .{ .named = named_type };
    }

    return error.UnknownType;
}

pub fn lookupStdlibModule(path: []const u8) ?*const ModuleSurface {
    for (&stdlib_modules) |*module| {
        if (std.mem.eql(u8, module.path, path)) {
            return module;
        }
    }
    return null;
}

pub fn lookupModuleSurface(surface: PackageSurface, path: []const u8) ?*const ModuleSurface {
    for (surface.modules) |*module| {
        if (std.mem.eql(u8, module.path, path)) {
            return module;
        }
    }
    return lookupStdlibModule(path);
}

pub fn lookupFunction(surface: PackageSurface, module_path: []const u8, name: []const u8) ?*const FunctionSignature {
    const module = lookupModuleSurface(surface, module_path) orelse return null;
    for (module.functions) |*function| {
        if (std.mem.eql(u8, function.name, name)) {
            return function;
        }
    }
    return null;
}

pub fn lookupStruct(surface: PackageSurface, module_path: []const u8, name: []const u8) ?*const StructSurface {
    const module = lookupModuleSurface(surface, module_path) orelse return null;
    for (module.structs) |*struct_surface| {
        if (std.mem.eql(u8, struct_surface.name, name)) {
            return struct_surface;
        }
    }
    return null;
}

pub fn lookupEnum(surface: PackageSurface, module_path: []const u8, name: []const u8) ?*const EnumSurface {
    const module = lookupModuleSurface(surface, module_path) orelse return null;
    for (module.enums) |*enum_surface| {
        if (std.mem.eql(u8, enum_surface.name, name)) {
            return enum_surface;
        }
    }
    return null;
}

pub fn lookupError(surface: PackageSurface, module_path: []const u8, name: []const u8) ?*const ErrorSurface {
    const module = lookupModuleSurface(surface, module_path) orelse return null;
    for (module.errors) |*error_surface| {
        if (std.mem.eql(u8, error_surface.name, name)) {
            return error_surface;
        }
    }
    return null;
}

pub fn isBuiltinValueName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Ok") or
        std.mem.eql(u8, name, "Err") or
        std.mem.eql(u8, name, "Some") or
        std.mem.eql(u8, name, "None") or
        std.mem.eql(u8, name, "Void") or
        std.mem.eql(u8, name, "print");
}

fn buildFunctionSignature(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
    decl: tree.FunctionDecl,
) ResolveTypeError!FunctionSignature {
    const params = try allocator.alloc(Param, decl.params.len);
    for (decl.params, 0..) |param, index| {
        params[index] = .{
            .name = textAt(sources, document.file_id, param.name),
            .ty = try resolveTypeRef(allocator, sources, documents, document, param.type_ref),
        };
    }

    return .{
        .module_path = modulePathText(sources, document),
        .name = textAt(sources, document.file_id, decl.name),
        .params = params,
        .return_type = try resolveTypeRef(allocator, sources, documents, document, decl.return_type),
        .visibility = decl.visibility,
    };
}

fn buildStructSurface(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
    decl: tree.StructDecl,
) ResolveTypeError!StructSurface {
    return .{
        .module_path = modulePathText(sources, document),
        .name = textAt(sources, document.file_id, decl.name),
        .fields = try buildFieldSurfaces(allocator, sources, documents, document, decl.fields),
        .visibility = decl.visibility,
    };
}

fn buildEnumSurface(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
    decl: tree.EnumDecl,
) ResolveTypeError!EnumSurface {
    return .{
        .module_path = modulePathText(sources, document),
        .name = textAt(sources, document.file_id, decl.name),
        .variants = try buildVariantSurfaces(allocator, sources, documents, document, decl.variants),
        .visibility = decl.visibility,
    };
}

fn buildErrorSurface(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
    decl: tree.ErrorDecl,
) ResolveTypeError!ErrorSurface {
    return .{
        .module_path = modulePathText(sources, document),
        .name = textAt(sources, document.file_id, decl.name),
        .variants = try buildVariantSurfaces(allocator, sources, documents, document, decl.variants),
        .visibility = decl.visibility,
    };
}

fn buildFieldSurfaces(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
    fields: []const tree.Field,
) ResolveTypeError![]const FieldSurface {
    const result = try allocator.alloc(FieldSurface, fields.len);
    for (fields, 0..) |field, index| {
        result[index] = .{
            .name = textAt(sources, document.file_id, field.name),
            .ty = try resolveTypeRef(allocator, sources, documents, document, field.type_ref),
        };
    }
    return result;
}

fn buildVariantSurfaces(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    documents: []const tree.Document,
    document: tree.Document,
    variants: []const tree.Variant,
) ResolveTypeError![]const VariantSurface {
    const result = try allocator.alloc(VariantSurface, variants.len);
    for (variants, 0..) |variant, index| {
        result[index] = .{
            .name = textAt(sources, document.file_id, variant.name),
            .fields = try buildFieldSurfaces(allocator, sources, documents, document, variant.fields),
        };
    }
    return result;
}

fn primitiveByName(name: []const u8) ?Primitive {
    if (std.mem.eql(u8, name, "Bool")) return .bool;
    if (std.mem.eql(u8, name, "Int")) return .int;
    if (std.mem.eql(u8, name, "Float")) return .float;
    if (std.mem.eql(u8, name, "String")) return .string;
    if (std.mem.eql(u8, name, "Bytes")) return .bytes;
    if (std.mem.eql(u8, name, "Void")) return .void;
    return null;
}

fn genericByName(name: []const u8) ?GenericKind {
    if (std.mem.eql(u8, name, "Option")) return .option;
    if (std.mem.eql(u8, name, "Result")) return .result;
    if (std.mem.eql(u8, name, "List")) return .list;
    if (std.mem.eql(u8, name, "Map")) return .map;
    if (std.mem.eql(u8, name, "Set")) return .set;
    return null;
}

fn genericArity(kind: GenericKind) usize {
    return switch (kind) {
        .option => 1,
        .result => 2,
        .list => 1,
        .map => 2,
        .set => 1,
    };
}

fn findNamedType(
    sources: *const source.Manager,
    documents: []const tree.Document,
    module_path: []const u8,
    type_name: []const u8,
    require_public: bool,
) ?NamedType {
    for (documents) |document| {
        if (!std.mem.eql(u8, modulePathText(sources, document), module_path)) {
            continue;
        }

        for (document.items) |item| switch (item) {
            .struct_decl => |decl| {
                if (std.mem.eql(u8, textAt(sources, document.file_id, decl.name), type_name) and (!require_public or decl.visibility == .public)) {
                    return .{ .module_path = module_path, .name = type_name, .kind = .struct_type };
                }
            },
            .enum_decl => |decl| {
                if (std.mem.eql(u8, textAt(sources, document.file_id, decl.name), type_name) and (!require_public or decl.visibility == .public)) {
                    return .{ .module_path = module_path, .name = type_name, .kind = .enum_type };
                }
            },
            .error_decl => |decl| {
                if (std.mem.eql(u8, textAt(sources, document.file_id, decl.name), type_name) and (!require_public or decl.visibility == .public)) {
                    return .{ .module_path = module_path, .name = type_name, .kind = .error_type };
                }
            },
            else => {},
        };
    }

    if (lookupStdlibModule(module_path)) |module| {
        for (module.types) |named_type| {
            if (std.mem.eql(u8, named_type.name, type_name)) {
                return named_type;
            }
        }
    }

    return null;
}

fn findImportedModulePath(sources: *const source.Manager, document: tree.Document, alias: []const u8) ?[]const u8 {
    for (document.imports) |import_decl| {
        const last_segment = import_decl.path.segments[import_decl.path.segments.len - 1].span;
        if (std.mem.eql(u8, alias, textAt(sources, document.file_id, last_segment))) {
            return textAt(sources, document.file_id, import_decl.path.span);
        }
    }
    return null;
}

fn joinPathPrefix(
    allocator: std.mem.Allocator,
    sources: *const source.Manager,
    file_id: source.FileId,
    segments: []const tree.PathSegment,
) ResolveTypeError![]const u8 {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    for (segments, 0..) |segment, index| {
        if (index > 0) {
            buffer.writer.writeByte('/') catch unreachable;
        }
        buffer.writer.writeAll(textAt(sources, file_id, segment.span)) catch unreachable;
    }
    return try buffer.toOwnedSlice();
}

fn modulePathText(sources: *const source.Manager, document: tree.Document) []const u8 {
    return textAt(sources, document.file_id, document.module_decl.path.span);
}

fn textAt(sources: *const source.Manager, file_id: source.FileId, span: source.Span) []const u8 {
    return span.slice(sources.getFile(file_id).source);
}

const bool_type = Type{ .primitive = .bool };
const int_type = Type{ .primitive = .int };
const float_type = Type{ .primitive = .float };
const string_type = Type{ .primitive = .string };
const bytes_type = Type{ .primitive = .bytes };
const void_type = Type{ .primitive = .void };
const type_param_t = Type{ .type_parameter = "T" };

const option_t_args = [_]Type{type_param_t};
const result_string_json_args = [_]Type{ string_type, Type{ .named = .{ .module_path = "std/json", .name = "JsonError", .kind = .error_type } } };
const result_string_fs_args = [_]Type{ string_type, Type{ .named = .{ .module_path = "std/fs", .name = "FsError", .kind = .error_type } } };

const stdlib_modules = [_]ModuleSurface{
    .{
        .path = "std/result",
        .types = &.{},
        .structs = &.{},
        .enums = &.{},
        .errors = &.{},
        .functions = &.{},
    },
    .{
        .path = "std/option",
        .types = &.{},
        .structs = &.{},
        .enums = &.{},
        .errors = &.{},
        .functions = &.{},
    },
    .{
        .path = "std/string",
        .types = &.{},
        .structs = &.{},
        .enums = &.{},
        .errors = &.{},
        .functions = &.{
            .{
                .module_path = "std/string",
                .name = "contains",
                .params = &.{
                    .{ .name = "value", .ty = string_type },
                    .{ .name = "needle", .ty = string_type },
                },
                .return_type = bool_type,
                .visibility = .public,
            },
        },
    },
    .{
        .path = "std/int",
        .types = &.{},
        .structs = &.{},
        .enums = &.{},
        .errors = &.{},
        .functions = &.{
            .{
                .module_path = "std/int",
                .name = "parse",
                .params = &.{ .{ .name = "value", .ty = string_type } },
                .return_type = int_type,
                .visibility = .public,
            },
            .{
                .module_path = "std/int",
                .name = "is_valid",
                .params = &.{ .{ .name = "value", .ty = string_type } },
                .return_type = bool_type,
                .visibility = .public,
            },
            .{
                .module_path = "std/int",
                .name = "to_string",
                .params = &.{ .{ .name = "value", .ty = int_type } },
                .return_type = string_type,
                .visibility = .public,
            },
        },
    },
    .{
        .path = "std/assert",
        .types = &.{},
        .structs = &.{},
        .enums = &.{},
        .errors = &.{},
        .functions = &.{
            .{
                .module_path = "std/assert",
                .name = "equal",
                .params = &.{
                    .{ .name = "left", .ty = type_param_t },
                    .{ .name = "right", .ty = type_param_t },
                },
                .return_type = void_type,
                .visibility = .public,
            },
            .{
                .module_path = "std/assert",
                .name = "true",
                .params = &.{ .{ .name = "value", .ty = bool_type } },
                .return_type = void_type,
                .visibility = .public,
            },
            .{
                .module_path = "std/assert",
                .name = "false",
                .params = &.{ .{ .name = "value", .ty = bool_type } },
                .return_type = void_type,
                .visibility = .public,
            },
            .{
                .module_path = "std/assert",
                .name = "fail",
                .params = &.{ .{ .name = "message", .ty = string_type } },
                .return_type = void_type,
                .visibility = .public,
            },
        },
    },
    .{
        .path = "std/test",
        .types = &.{},
        .structs = &.{},
        .enums = &.{},
        .errors = &.{},
        .functions = &.{},
    },
    .{
        .path = "std/json",
        .types = &.{
            .{ .module_path = "std/json", .name = "JsonError", .kind = .error_type },
        },
        .structs = &.{},
        .enums = &.{},
        .errors = &.{
            .{ .module_path = "std/json", .name = "JsonError", .variants = &.{}, .visibility = .public },
        },
        .functions = &.{
            .{
                .module_path = "std/json",
                .name = "encode",
                .params = &.{ .{ .name = "value", .ty = type_param_t } },
                .return_type = .{ .generic = .{ .kind = .result, .args = &result_string_json_args } },
                .visibility = .public,
            },
        },
    },
    .{
        .path = "std/fs",
        .types = &.{
            .{ .module_path = "std/fs", .name = "FsError", .kind = .error_type },
        },
        .structs = &.{},
        .enums = &.{},
        .errors = &.{
            .{ .module_path = "std/fs", .name = "FsError", .variants = &.{}, .visibility = .public },
        },
        .functions = &.{
            .{
                .module_path = "std/fs",
                .name = "read_file",
                .params = &.{ .{ .name = "path", .ty = string_type } },
                .return_type = .{ .generic = .{ .kind = .result, .args = &result_string_fs_args } },
                .visibility = .public,
            },
        },
    },
};

test "type model resolves primitive and generic type refs" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics: @import("../diag/mod.zig").Store = .{};
    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/app/demo.lace",
        \\module app/demo;
        \\
        \\pub error DemoError {
        \\    bad_input,
        \\}
        \\
        \\pub struct User {
        \\    name: String,
        \\}
        \\
        \\pub fn main(
        \\    value: Option<Int>,
        \\) -> Result<User, DemoError> {
        \\    return Ok(User{
        \\        name: "sam",
        \\    });
        \\}
    );

    const document = try syntax.parseFile(arena, &diagnostics, sources.getFile(file_id));
    const function_decl = document.items[2].function_decl;

    const param_type = try resolveTypeRef(arena, &sources, &.{document}, document, function_decl.params[0].type_ref);
    try std.testing.expect(param_type.eql(.{ .generic = .{ .kind = .option, .args = &.{.{ .primitive = .int }} } }));

    const return_type = try resolveTypeRef(arena, &sources, &.{document}, document, function_decl.return_type);
    try std.testing.expect(return_type.eql(.{ .generic = .{ .kind = .result, .args = &.{
        .{ .named = .{ .module_path = "app/demo", .name = "User", .kind = .struct_type } },
        .{ .named = .{ .module_path = "app/demo", .name = "DemoError", .kind = .error_type } },
    } } }));
}

test "stdlib modules expose typed signatures" {
    const string_module = lookupStdlibModule("std/string").?;
    try std.testing.expectEqual(@as(usize, 1), string_module.functions.len);
    try std.testing.expect(string_module.functions[0].return_type.eql(.{ .primitive = .bool }));

    const int_module = lookupStdlibModule("std/int").?;
    try std.testing.expect(int_module.functions[0].return_type.eql(.{ .primitive = .int }));

    const fs_module = lookupStdlibModule("std/fs").?;
    try std.testing.expect(fs_module.functions[0].return_type.eql(.{ .generic = .{ .kind = .result, .args = &result_string_fs_args } }));
}

test "package surface models user defined types and functions" {
    var sources: source.Manager = .{};
    defer sources.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics: @import("../diag/mod.zig").Store = .{};
    const file_id = try sources.addSource(
        std.testing.allocator,
        "src/app/signup.lace",
        \\module app/signup;
        \\
        \\pub struct SignupInput {
        \\    email: String,
        \\}
        \\
        \\pub error SignupError {
        \\    duplicate_email,
        \\}
        \\
        \\pub fn signup(
        \\    input: SignupInput,
        \\) -> Result<SignupInput, SignupError> {
        \\    return Ok(input);
        \\}
    );

    const document = try syntax.parseFile(arena, &diagnostics, sources.getFile(file_id));
    const surface = try buildPackageSurface(arena, &sources, &.{document});

    try std.testing.expectEqual(@as(usize, 1), surface.modules.len);
    try std.testing.expectEqual(@as(usize, 2), surface.modules[0].types.len);
    try std.testing.expectEqual(@as(usize, 1), surface.modules[0].structs.len);
    try std.testing.expectEqual(@as(usize, 1), surface.modules[0].errors.len);
    try std.testing.expectEqual(@as(usize, 1), surface.modules[0].functions.len);
    try std.testing.expectEqualStrings("signup", surface.modules[0].functions[0].name);
    try std.testing.expect(surface.modules[0].functions[0].return_type.eql(.{ .generic = .{ .kind = .result, .args = &.{
        .{ .named = .{ .module_path = "app/signup", .name = "SignupInput", .kind = .struct_type } },
        .{ .named = .{ .module_path = "app/signup", .name = "SignupError", .kind = .error_type } },
    } } }));
    try std.testing.expectEqualStrings("email", surface.modules[0].structs[0].fields[0].name);
}

test "type strings are canonical and module-aware" {
    const allocator = std.testing.allocator;
    const local_named: Type = .{ .named = .{ .module_path = "app/signup", .name = "User", .kind = .struct_type } };
    const external_named: Type = .{ .named = .{ .module_path = "github.com/sam/user/model", .name = "User", .kind = .struct_type } };
    const composite: Type = .{ .generic = .{ .kind = .result, .args = &.{ local_named, external_named } } };

    const rendered = try renderTypeAlloc(allocator, "app/signup", composite);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Result<User, github.com/sam/user/model.User>", rendered);
}
