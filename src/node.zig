const std = @import("std");
const tokenize = @import("tokenize.zig");

pub const NodeId = packed struct {
    index: u32,
    file: u32,

    pub inline fn eql(self: NodeId, other: NodeId) bool {
        return self.file == other.file and self.index == other.index;
    }
};

pub const TokenIndex = tokenize.TokenId;

pub const NodeRange = packed struct {
    start: u32,
    len: u32,
};

pub const Node = struct {
    id: NodeId,
    kind: NodeKind,

    pub fn print(self: *const @This()) void {
        std.debug.print("Node {}-{}: {s}\n", .{ self.id.file, self.id.index, @tagName(self.kind) });
        switch (self.kind) {
            .identifier => |value| std.debug.print("  {s}\n", .{value}),
            .int_literal => |value| std.debug.print("  {}\n", .{value}),
            .float_literal => |value| std.debug.print("  {d}\n", .{value}),
            .bool_literal => |value| std.debug.print("  {}\n", .{value}),
            .string_literal => |value| std.debug.print("  {s}\n", .{value}),

            .binding => |cexpr| {
                std.debug.print("  {s}\n", .{cexpr.name});
                if (cexpr.ty) |ty| {
                    std.debug.print("  ty: {}-{}\n", .{ ty.file, ty.index });
                }
                std.debug.print("  mutable: {}\n", .{cexpr.mutable});
                std.debug.print("  value: {}-{}\n", .{ cexpr.value.file, cexpr.value.index });

                var it = cexpr.tags.iterator(.{});
                if (it.next()) |tag| {
                    std.debug.print("  {}", .{tag});
                } else {
                    return;
                }
                while (it.next()) |tag| {
                    std.debug.print(",{}", .{tag});
                }
                std.debug.print("\n", .{});
            },
            .binary_expr => |expr| {
                std.debug.print("  left: {}-{}\n", .{ expr.left.file, expr.left.index });
                std.debug.print("  op: {}\n", .{expr.op});
                std.debug.print("  right: {}-{}\n", .{ expr.right.file, expr.right.index });
            },
            .unary_expr => |expr| {
                std.debug.print("  op: {}\n", .{expr.op});
                std.debug.print("  expr: {}-{}\n", .{ expr.expr.file, expr.expr.index });
            },

            .key_value => |kv| {
                std.debug.print("  key: {}\n", .{kv.key});
                std.debug.print("  value: {}\n", .{kv.value});
            },
            .key_value_ident => |kv| {
                std.debug.print("  key: {s}\n", .{kv.key});
                std.debug.print("  value: {}\n", .{kv.value});
            },
            .argument => |arg| std.debug.print("  arg: {}-{}\n", .{ arg.file, arg.index }),
            .parameter => |param| {
                std.debug.print("  ty: {}-{}\n", .{ param.ty.file, param.ty.index });
                std.debug.print("  name: {s}\n", .{param.name});
                std.debug.print("  spread: {}\n", .{param.spread});
                if (param.default) |def| {
                    std.debug.print("  default: {}-{}\n", .{ def.file, def.index });
                }
            },
            .func => |func| {
                std.debug.print("  parameters: {}-{}\n", .{ func.params.start, func.params.start + func.params.len });
                if (func.ret_ty) |ret| {
                    std.debug.print("  ret_ty: {}-{}\n", .{ ret.file, ret.index });
                }
                if (func.block) |blk| {
                    std.debug.print("  body: {}-{}\n", .{ blk.start, blk.start + blk.len });
                }
            },
            .func_no_params => |func| {
                if (func.ret_ty) |ret| {
                    std.debug.print("  ret_ty: {}-{}\n", .{ ret.file, ret.index });
                }
                if (func.block) |blk| {
                    std.debug.print("  body: {}-{}\n", .{ blk.start, blk.start + blk.len });
                }
            },
            .invoke => |inv| {
                std.debug.print("  expr: {}-{}\n", .{ inv.expr.file, inv.expr.index });
                std.debug.print("  arguments: {}-{}\n", .{ inv.args.start, inv.args.start + inv.args.len });
                if (inv.trailing_block) |blk| {
                    std.debug.print("  trailing_block: {}-{}\n", .{ blk.start, blk.start + blk.len });
                }
            },
            .subscript => |sub| {
                std.debug.print("  expr: {}-{}\n", .{ sub.expr.file, sub.expr.index });
                std.debug.print("  sub: {}-{}\n", .{ sub.sub.file, sub.sub.index });
            },
            .if_expr => |expr| {
                std.debug.print("  cond: {}-{}\n", .{ expr.cond.file, expr.cond.index });
                if (expr.captures) |capt| {
                    std.debug.print("  captures: {}-{}\n", .{ capt.start, capt.start + capt.len });
                }
                std.debug.print("  true_block: {}-{}\n", .{ expr.true_block.start, expr.true_block.start + expr.true_block.len });
                if (expr.false_block) |blk| {
                    std.debug.print("  false_block: {}-{}\n", .{ blk.start, blk.start + blk.len });
                }
            },
            .loop => |loop| {
                if (loop.expr) |expr| {
                    std.debug.print("  expr: {}-{}\n", .{ expr.file, expr.index });
                }
                if (loop.captures) |capt| {
                    std.debug.print("  captures: {}-{}\n", .{ capt.start, capt.start + capt.len });
                }
                std.debug.print("  loop_block: {}-{}\n", .{ loop.loop_block.start, loop.loop_block.start + loop.loop_block.len });
                if (loop.else_block) |block| {
                    std.debug.print("  else_block: {}-{}\n", .{ block.start, block.start + block.len });
                }
                if (loop.finally_block) |block| {
                    std.debug.print("  finally_block: {}-{}\n", .{ block.start, block.start + block.len });
                }
            },
            .reference => |ref| {
                std.debug.print("  expr: {}-{}\n", .{ ref.expr.file, ref.expr.index });
            },
            .dereference => |ref| {
                std.debug.print("  expr: {}-{}\n", .{ ref.expr.file, ref.expr.index });
            },
            .const_expr => |cexpr| {
                std.debug.print("  expr: {}-{}\n", .{ cexpr.expr.file, cexpr.expr.index });
            },
            .const_block => |cexpr| {
                std.debug.print("  block: {}-{}\n", .{ cexpr.block.start, cexpr.block.start + cexpr.block.len });
            },

            .variant_init => |varin| {
                std.debug.print("  variant: {}-{}\n", .{ varin.variant.file, varin.variant.index });
                std.debug.print("  init: {}-{}\n", .{ varin.init.file, varin.init.index });
            },
            .implicit_variant => |iv| {
                std.debug.print("  value: {s}\n", .{iv.ident});
            },
            .array_init_or_slice_one => |value| {
                std.debug.print("  expr: {}-{}\n", .{ value.expr.file, value.expr.index });
                if (value.value) |val| {
                    std.debug.print("  value: {}-{}\n", .{ val.file, val.index });
                }
                std.debug.print("  mut: {}\n", .{value.mut});
            },
            .array_init => |value| {
                std.debug.print("  range: {}-{}\n", .{ value.exprs.start, value.exprs.start + value.exprs.len });
            },
            .record_field => |field| {
                std.debug.print("  ty: {}-{}\n", .{ field.ty.file, field.ty.index });
                std.debug.print("  name: {s}\n", .{field.name});

                if (field.default) |def| {
                    std.debug.print("  default: {}-{}\n", .{ def.file, def.index });
                }
            },
            .type_record => |rec| {
                if (rec.backing_field) |bfie| {
                    std.debug.print("  backing_field: {}-{}\n", .{ bfie.file, bfie.index });
                }
                std.debug.print("  fields: {}-{}\n", .{ rec.fields.start, rec.fields.start + rec.fields.len });
            },
            .union_variant => |vari| {
                if (vari.ty) |ty| {
                    std.debug.print("  ty: {}-{}\n", .{ ty.file, ty.index });
                }

                std.debug.print("  name: {}-{}\n", .{ vari.name.file, vari.name.index });
                if (vari.index) |ind| {
                    std.debug.print("  index: {}-{}\n", .{ ind.file, ind.index });
                }
            },
            .type_union => |uni| {
                if (uni.backing_field) |bfie| {
                    std.debug.print("  backing_field: {}-{}\n", .{ bfie.file, bfie.index });
                }

                std.debug.print("  variants: {}-{}\n", .{ uni.variants.start, uni.variants.start + uni.variants.len });
            },
            .type_alias => |ty| {
                std.debug.print("  ty: {}-{}\n", .{ ty.file, ty.index });
            },
            .type_wild => |ty| {
                std.debug.print("  ty: {s}\n", .{ty});
            },
            .type_ref => |tref| {
                std.debug.print("  ty: {}\n", .{tref.ty});
                std.debug.print("  mut: {}\n", .{tref.mut});
            },
            .type_opt => |_| {},

            .type_bool => {},
            .type_int => |size| {
                std.debug.print("  size: {}\n", .{size});
            },
            .type_float => |size| {
                std.debug.print("  size: {}\n", .{size});
            },
            .type_uint => |size| {
                std.debug.print("  size: {}\n", .{size});
            },
        }
    }
};

pub const NodeKind = union(enum) {
    identifier: []const u8,
    int_literal: u64,
    float_literal: f64,
    bool_literal: bool,
    string_literal: []const u8,

    binding: struct {
        ty: ?NodeId,
        // tok_index is let
        mutable: bool,
        name: []const u8,
        tags: SymbolTag.Tag,
        value: NodeId,
    },

    binary_expr: struct {
        left: NodeId,
        op: Operator,
        right: NodeId,
    },

    unary_expr: struct {
        op: Operator,
        expr: NodeId,
    },

    key_value: struct {
        key: NodeId,
        value: NodeId,
    },
    key_value_ident: struct {
        key: []const u8,
        value: NodeId,
    },

    argument: NodeId,

    parameter: struct {
        ty: NodeId,
        spread: bool,
        name: []const u8,
        default: ?NodeId,
    },

    func: struct {
        params: NodeRange,
        ret_ty: ?NodeId,
        block: ?NodeRange,
    },
    func_no_params: struct {
        ret_ty: ?NodeId,
        block: ?NodeRange,
    },
    invoke: struct {
        expr: NodeId,
        args: NodeRange,
        trailing_block: ?NodeRange,
    },
    subscript: struct {
        expr: NodeId,
        sub: NodeId,
    },

    if_expr: struct {
        cond: NodeId,
        captures: ?NodeRange,
        true_block: NodeRange,
        false_block: ?NodeRange,
    },

    loop: struct {
        expr: ?NodeId,
        captures: ?NodeRange,
        loop_block: NodeRange,
        else_block: ?NodeRange,
        finally_block: ?NodeRange,
    },
    reference: struct {
        expr: NodeId,
    },
    dereference: struct {
        expr: NodeId,
    },
    const_expr: struct {
        expr: NodeId,
    },
    const_block: struct {
        block: NodeRange,
    },

    variant_init: struct {
        variant: NodeId,
        init: NodeId,
    },
    implicit_variant: struct { ident: []const u8 },

    /// Either an array/record init epxression
    ///  - [1]
    ///  - [a: 1]
    /// Or a slice/array type
    ///  - [uint8]
    ///  - [uint8: 8]
    ///  - [mut uint8]
    array_init_or_slice_one: struct {
        expr: NodeId,
        value: ?NodeId,
        mut: bool,
    },
    array_init: struct {
        exprs: NodeRange,
    },

    type_record: struct {
        backing_field: ?NodeId,
        fields: NodeRange,
    },
    record_field: struct {
        ty: NodeId,
        name: []const u8,
        default: ?NodeId,
    },
    type_union: struct {
        backing_field: ?NodeId,
        variants: NodeRange,
    },
    union_variant: struct {
        ty: ?NodeId,
        name: NodeId,
        index: ?NodeId,
    },

    type_alias: NodeId,

    type_wild: []const u8,

    type_ref: struct {
        ty: NodeId,
        mut: bool,
    },
    type_opt: struct {
        ty: NodeId,
    },

    type_int: usize,
    type_uint: usize,
    type_float: usize,
    type_bool,
};

pub const NodeTokens = union(enum) {
    single: TokenIndex,
    binding: struct {
        public_tok: ?TokenIndex,
        export_tok: ?TokenIndex,
        extern_tok: ?TokenIndex,
        let_tok: ?TokenIndex,
        mut_tok: ?TokenIndex,
        name_tok: TokenIndex,
        eq_tok: TokenIndex,
    },
    parameter: struct {
        spread_tok: ?TokenIndex,
        name_tok: TokenIndex,
        eq_tok: ?TokenIndex,
    },
    key_value_ident: struct {
        name_tok: TokenIndex,
        colon_tok: TokenIndex,
    },
    func: struct {
        open_paren_tok: TokenIndex,
        close_paren_tok: TokenIndex,

        open_brace_tok: ?TokenIndex,
        close_brace_tok: ?TokenIndex,
    },
    invoke: struct {
        open_paren_tok: TokenIndex,
        close_paren_tok: TokenIndex,
    },
    subscript: struct {
        open_bracket_tok: TokenIndex,
        close_bracket_tok: TokenIndex,
    },
    if_expr: struct {
        if_tok: TokenIndex,

        open_brace_tok: TokenIndex,
        close_brace_tok: TokenIndex,

        else_tok: ?TokenIndex,
        else_open_brace_tok: ?TokenIndex,
        else_close_brace_tok: ?TokenIndex,
    },
    loop: struct {
        loop_tok: TokenIndex,

        open_brace_tok: TokenIndex,
        close_brace_tok: TokenIndex,

        else_tok: ?TokenIndex,
        else_open_brace_tok: ?TokenIndex,
        else_close_brace_tok: ?TokenIndex,

        finally_tok: ?TokenIndex,
        finally_open_brace_tok: ?TokenIndex,
        finally_close_brace_tok: ?TokenIndex,
    },
    const_block: struct {
        const_tok: TokenIndex,
        open_brace_tok: TokenIndex,
        close_brace_tok: TokenIndex,
    },
    implicit_variant: struct {
        dot_tok: TokenIndex,
        ident_tok: TokenIndex,
    },
    array_init_or_slice_one: struct {
        mut_tok: ?TokenIndex,
        open_bracket_tok: TokenIndex,
        close_bracket_tok: TokenIndex,
    },
    array_init: struct {
        open_bracket_tok: TokenIndex,
        close_bracket_tok: TokenIndex,
    },
    type_record: struct {
        ty_tok: TokenIndex,
        open_paren_tok: ?TokenIndex,
        close_paren_tok: ?TokenIndex,

        open_bracket_tok: TokenIndex,
        close_bracket_tok: TokenIndex,
    },
    record_field: struct {
        name_tok: TokenIndex,
        eq_tok: ?TokenIndex,
    },
    type_union: struct {
        ty_tok: TokenIndex,
        open_paren_tok: ?TokenIndex,
        close_paren_tok: ?TokenIndex,
    },
    union_variant: struct {
        pipe_tok: ?TokenIndex,
        eq_tok: ?TokenIndex,
    },
    type_ref: struct {
        ref_tok: TokenIndex,
        mut_tok: ?TokenIndex,
    },
    type_wild: struct {
        dot_tok: TokenIndex,
        ident_tok: TokenIndex,
    },

    // pub fn beginEnd(self: *const NodeTokens) struct { TokenIndex, ?TokenIndex } {
    //     return switch (self.*) {
    //         .single => |s| .{ s, null },
    //         .binding => |v| .{ v.mut_tok orelse v.name_tok, v.eq_tok },
    //         .parameter => |v| .{ v.spread_tok orelse v.name_tok, v.eq_tok orelse v.name_tok },
    //         .key_value_ident => |v| .{ v.name_tok, v.colon_tok },
    //         .func => |v| .{ v.open_paren_tok, v.close_brace_tok },
    //         .invoke => |v| .{ v.open_paren_tok, v.close_paren_tok },
    //         .subscript => |v| .{ v.open_bracket_tok, v.close_bracket_tok },
    //         .if_expr => |v| .{ v.if_tok, v.else_close_brace_tok orelse v.close_brace_tok },
    //         .loop => |v| .{ v.loop_tok, v.finally_close_brace_tok orelse v.else_close_brace_tok orelse v.close_brace_tok },
    //         .const_block => |v| .{ v.const_tok, v.close_brace_tok },
    //         .array_init_or_slice_one => |v| .{ v.open_bracket_tok, v.close_bracket_tok },
    //         .array_init => |v| .{ v.open_bracket_tok, v.close_bracket_tok },
    //         .type_record => |v| .{ v.ty_tok, v.close_bracket_tok },
    //         .record_field => |v| .{ v.name_tok, v.eq_tok },
    //         .type_union => |v| .{ v.ty_tok, v.close_paren_tok },
    //         .union_variant => |v| .{ v.pipe_tok orelse @panic("foo"), v.eq_tok },
    //         .type_ref => |v| .{ v.ref_tok, v.mut_tok },
    //     };
    // }
};

pub const Operator = enum {
    plus,
    minus,
    times,
    divide,

    bitand,
    bitor,
    bitxor,
    bitnot,

    shiftleft,
    shiftright,

    invoke,
    subscript,
    ref,
    opt,
    member_access,

    deref,
    take_ref,

    assign,
    plus_eq,
    minus_eq,
    times_eq,
    divide_eq,
    bitand_eq,
    bitor_eq,
    bitxor_eq,
    bitnot_eq,

    equal,
    not_equal,
    gt,
    gte,
    lt,
    lte,

    bang,
    colon,

    pub fn fromTokenKind(kind: tokenize.TokenKind) ?Operator {
        return switch (kind) {
            .plus => .plus,
            .minus => .minus,
            .star => .times,
            .slash => .divide,

            // .ampersand => .bitand,
            .pipe => .bitor,
            .carot => .bitxor,
            .tilde => .bitnot,

            .double_right => .shiftleft,
            .double_left => .shiftright,

            .open_paren => .invoke,
            .open_bracket => .subscript,
            .ampersand, .mut => .ref,
            .question => .opt,

            .dot => .member_access,
            .dot_ampersand => .take_ref,
            .dot_star => .deref,

            .assign => .assign,
            .plus_eq => .plus_eq,
            .minus_eq => .minus_eq,
            .star_eq => .times_eq,
            .slash_eq => .divide_eq,
            .pipe_eq => .bitor_eq,
            .carot_eq => .bitxor_eq,

            .equal => .equal,
            .not_equal => .not_equal,
            .gt => .gt,
            .gte => .gte,
            .lt => .lt,
            .lte => .lte,

            .bang => .bang,
            .coloncolon => .colon,

            else => null,
        };
    }
};

pub const SectionTag = struct {
    pub const Tag = std.bit_set.IntegerBitSet(3);

    pub const read: usize = 0;
    pub const write: usize = 1;
    pub const execute: usize = 2;
};

pub const SymbolTag = struct {
    pub const Tag = std.bit_set.IntegerBitSet(3);

    pub const exported: usize = 0;
    pub const external: usize = 1;
    pub const public: usize = 2;
};
