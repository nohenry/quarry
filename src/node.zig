const std = @import("std");
const tokenize = @import("tokenize.zig");

pub const NodeId = packed struct {
    file: u32,
    index: u32,

    pub inline fn eql(self: NodeId, other: NodeId) bool {
        return self.file == other.file and self.index == other.index;
    }
};

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
            .string_literal => |value| std.debug.print("  {s}\n", .{value}),

            .binding => |cexpr| {
                std.debug.print("  {s}\n", .{cexpr.name});
                if (cexpr.ty) |ty| {
                    std.debug.print("  ty: {}-{}\n", .{ ty.file, ty.index });
                }
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
                std.debug.print("  body: {}-{}\n", .{ func.block.start, func.block.start + func.block.len });
            },
            .func_no_params => |func| {
                if (func.ret_ty) |ret| {
                    std.debug.print("  ret_ty: {}-{}\n", .{ ret.file, ret.index });
                }
                std.debug.print("  body: {}-{}\n", .{ func.block.start, func.block.start + func.block.len });
            },
            .invoke => |inv| {
                std.debug.print("  expr: {}-{}\n", .{ inv.expr.file, inv.expr.index });
                std.debug.print("  arguments: {}-{}\n", .{ inv.args.start, inv.args.start + inv.args.len });
                if (inv.trailing_block) |blk| {
                    std.debug.print("  trailing_block: {}-{}\n", .{ blk.start, blk.start + blk.len });
                }
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
                std.debug.print("  ty: {}-{}\n", .{ vari.ty.file, vari.ty.index });
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
            .type_ref => |tref| {
                std.debug.print("  ty: {}\n", .{tref.ty});
                std.debug.print("  mut: {}\n", .{tref.mut});
            },
            .type_opt => |_| {},

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
    string_literal: []const u8,

    binding: struct {
        ty: ?NodeId,
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

    parameter: struct {
        ty: NodeId,
        spread: bool,
        name: []const u8,
        default: ?NodeId,
    },

    func: struct {
        params: NodeRange,
        ret_ty: ?NodeId,
        block: NodeRange,
    },
    func_no_params: struct {
        ret_ty: ?NodeId,
        block: NodeRange,
    },
    invoke: struct {
        expr: NodeId,
        args: NodeRange,
        trailing_block: ?NodeRange,
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
        ty: NodeId,
        name: NodeId,
        index: ?NodeId,
    },

    type_alias: NodeId,

    type_ref: struct { ty: NodeId, mut: bool },
    type_opt: struct { ty: NodeId },

    type_int: usize,
    type_uint: usize,
    type_float: usize,
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
    ref,
    opt,

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
            .ampersand, .mut => .ref,
            .question => .opt,

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
    pub const Tag = std.bit_set.IntegerBitSet(2);

    pub const exported: usize = 0;
    pub const public: usize = 1;
};
