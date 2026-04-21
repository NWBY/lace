const source = @import("../source.zig");
const token = @import("token.zig");

pub const Visibility = enum {
    private,
    public,
};

pub const Document = struct {
    file_id: source.FileId,
    tokens: []const token.Token,
    module_decl: ModuleDecl,
    imports: []const ImportDecl,
    items: []const Item,
};

pub const ModuleDecl = struct {
    span: source.Span,
    path: Path,
};

pub const ImportDecl = struct {
    span: source.Span,
    path: Path,
};

pub const Path = struct {
    span: source.Span,
    segments: []const PathSegment,
};

pub const PathSegment = struct {
    span: source.Span,
};

pub const TypeRef = struct {
    span: source.Span,
    path: Path,
    arguments: []const TypeRef,
};

pub const Field = struct {
    span: source.Span,
    name: source.Span,
    type_ref: TypeRef,
};

pub const Variant = struct {
    span: source.Span,
    name: source.Span,
    fields: []const Field,
};

pub const OpaqueRange = struct {
    span: source.Span,
    token_start: usize,
    token_end: usize,
};

pub const Block = struct {
    span: source.Span,
    body: OpaqueRange,
};

pub const StructDecl = struct {
    span: source.Span,
    visibility: Visibility,
    name: source.Span,
    fields: []const Field,
};

pub const EnumDecl = struct {
    span: source.Span,
    visibility: Visibility,
    name: source.Span,
    variants: []const Variant,
};

pub const ErrorDecl = struct {
    span: source.Span,
    visibility: Visibility,
    name: source.Span,
    variants: []const Variant,
};

pub const FunctionDecl = struct {
    span: source.Span,
    visibility: Visibility,
    name: source.Span,
    params: []const Field,
    return_type: TypeRef,
    body: Block,
};

pub const ConstDecl = struct {
    span: source.Span,
    visibility: Visibility,
    name: source.Span,
    type_ref: TypeRef,
    initializer: OpaqueRange,
};

pub const TestDecl = struct {
    span: source.Span,
    name: source.Span,
    body: Block,
};

pub const Item = union(enum) {
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    error_decl: ErrorDecl,
    function_decl: FunctionDecl,
    const_decl: ConstDecl,
    test_decl: TestDecl,
};
