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

pub const AccessPath = struct {
    span: source.Span,
    segments: []const source.Span,
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

pub const Argument = struct {
    span: source.Span,
    name: source.Span,
    value: *Expr,
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
    initializer: *Expr,
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

pub const Block = struct {
    span: source.Span,
    statements: []const Statement,
};

pub const Statement = union(enum) {
    let_stmt: LetStmt,
    const_stmt: ConstStmt,
    bind_stmt: BindStmt,
    if_stmt: IfStmt,
    match_stmt: MatchExpr,
    return_stmt: ReturnStmt,
    expr_stmt: ExprStmt,
};

pub const LetStmt = struct {
    span: source.Span,
    name: source.Span,
    type_ref: ?TypeRef,
    value: *Expr,
};

pub const ConstStmt = struct {
    span: source.Span,
    name: source.Span,
    type_ref: ?TypeRef,
    value: *Expr,
};

pub const BindElseBody = union(enum) {
    block: Block,
    expr: *Expr,
};

pub const BindStmt = struct {
    span: source.Span,
    name: source.Span,
    type_ref: ?TypeRef,
    value: *Expr,
    else_name: source.Span,
    else_body: BindElseBody,
};

pub const IfStmt = struct {
    span: source.Span,
    condition: *Expr,
    then_block: Block,
    else_block: ?Block,
};

pub const ReturnStmt = struct {
    span: source.Span,
    value: *Expr,
};

pub const ExprStmt = struct {
    span: source.Span,
    value: *Expr,
};

pub const ArmBody = union(enum) {
    block: Block,
    return_stmt: ReturnStmt,
    expr: *Expr,
};

pub const MatchArm = struct {
    span: source.Span,
    pattern: Pattern,
    body: ArmBody,
};

pub const MatchExpr = struct {
    span: source.Span,
    value: *Expr,
    arms: []const MatchArm,
};

pub const PatternField = struct {
    span: source.Span,
    name: source.Span,
    value: *Pattern,
};

pub const PatternPayload = union(enum) {
    positional: *Pattern,
    named: []const PatternField,
};

pub const BindingPattern = struct {
    span: source.Span,
};

pub const PathPattern = struct {
    span: source.Span,
    path: AccessPath,
    payload: ?PatternPayload,
};

pub const Pattern = union(enum) {
    binding: BindingPattern,
    path: PathPattern,

    pub fn span(self: Pattern) source.Span {
        return switch (self) {
            .binding => |value| value.span,
            .path => |value| value.span,
        };
    }
};

pub const VariantPayload = union(enum) {
    positional: *Expr,
    named: []const Argument,
};

pub const CallExpr = struct {
    span: source.Span,
    callee: *Expr,
    args: []const Argument,
};

pub const StructInitExpr = struct {
    span: source.Span,
    type_path: AccessPath,
    fields: []const Argument,
};

pub const VariantExpr = struct {
    span: source.Span,
    path: AccessPath,
    payload: VariantPayload,
};

pub const UnaryExpr = struct {
    span: source.Span,
    operator: token.Tag,
    value: *Expr,
};

pub const BinaryExpr = struct {
    span: source.Span,
    operator: token.Tag,
    left: *Expr,
    right: *Expr,
};

pub const Expr = union(enum) {
    access_path: AccessPath,
    bool_literal: source.Span,
    int_literal: source.Span,
    string_literal: source.Span,
    unary: UnaryExpr,
    binary: BinaryExpr,
    call: CallExpr,
    struct_init: StructInitExpr,
    variant: VariantExpr,
    match_expr: MatchExpr,

    pub fn span(self: Expr) source.Span {
        return switch (self) {
            .access_path => |value| value.span,
            .bool_literal => |value| value,
            .int_literal => |value| value,
            .string_literal => |value| value,
            .unary => |value| value.span,
            .binary => |value| value.span,
            .call => |value| value.span,
            .struct_init => |value| value.span,
            .variant => |value| value.span,
            .match_expr => |value| value.span,
        };
    }
};
