const std = @import("std");
const node = @import("node.zig");
const analyze = @import("analyze.zig");
const typecheck = @import("typecheck.zig");
const diags = @import("diagnostics.zig");

pub const EvalError = error{} || std.mem.Allocator.Error;

/// Represents a compile time value
pub const Value = struct {
    kind: ValueKind,

    pub fn print(self: *const @This()) void {
        switch (self.kind) {
            .int => |ivalue| std.debug.print("{}", .{ivalue}),
            .float => |fvalue| std.debug.print("{}", .{fvalue}),
            .bool => |bvalue| std.debug.print("{}", .{bvalue}),
            .str => |svalue| std.debug.print("{s}", .{svalue}),
            .func => |func| std.debug.print("Func {}-{} and {}-{}", .{ func.node_id.file, func.node_id.index, if (func.instructions) |fi| fi.start else 0, if (func.instructions) |fi| fi.len else 0 }),
            .ref => |ref| std.debug.print("Ref mut:{} {}-{}", .{ ref.mutable, ref.node_id.file, ref.node_id.index }),
            .undef => std.debug.print("undef", .{}),
        }
    }
};
pub const ValueKind = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    str: []const u8,
    func: FunctionValue,
    ref: struct {
        node_id: node.NodeId,
        mutable: bool,
    },
    undef,
};

pub const Instruction = struct {
    id: InstructionId,
    kind: InstructionKind,
    value: ?Value,

    pub fn print(self: *const @This()) void {
        std.debug.print("Instruction {}-{}: {s}\n", .{ self.id.file, self.id.index, @tagName(self.kind) });
        switch (self.kind) {
            .constant => {
                std.debug.print("  ", .{});
                self.value.?.print();
                std.debug.print("\n", .{});
            },
            .identifier => |value| std.debug.print("  {}-{}\n", .{ value.file, value.index }),
            .argument => |value| std.debug.print("  {}-{}\n", .{ value.file, value.index }),

            .binding => |cexpr| {
                std.debug.print("  node: {}-{}\n", .{ cexpr.node.file, cexpr.node.index });
                // if (cexpr.ty) |ty| {
                //     std.debug.print("  ty: {}-{}\n", .{ ty.file, ty.index });
                // }
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
            .assign => |expr| {
                std.debug.print("  left: {}-{}\n", .{ expr.left.file, expr.left.index });
                std.debug.print("  right: {}-{}\n", .{ expr.right.file, expr.right.index });
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
            .invoke => |inv| {
                std.debug.print("  expr: {}-{}\n", .{ inv.expr.file, inv.expr.index });
                std.debug.print("  arguments: {}-{}\n", .{ inv.args.start, inv.args.start + inv.args.len });
            },
            .subscript => |sub| {
                std.debug.print("  expr: {}-{}\n", .{ sub.expr.file, sub.expr.index });
                std.debug.print("  sub: {}-{}\n", .{ sub.sub.file, sub.sub.index });
            },
            .reference => |expr| {
                std.debug.print("  expr: {}-{}\n", .{ expr.expr.file, expr.expr.index });
            },
            .dereference => |expr| {
                std.debug.print("  expr: {}-{}\n", .{ expr.expr.file, expr.expr.index });
            },
            .direct_ref => |expr| {
                std.debug.print("  to: {}-{}\n", .{ expr.file, expr.index });
            },
            .if_expr => |expr| {
                std.debug.print("  cond: {}-{}\n", .{ expr.cond.file, expr.cond.index });
                // if (expr.captures) |capt| {
                //     std.debug.print("  captures: {}-{}\n", .{ capt.start, capt.start + capt.len });
                // }
                std.debug.print("  true_block: {}-{}\n", .{ expr.true_block.start, expr.true_block.start + expr.true_block.len });
                if (expr.false_block) |blk| {
                    std.debug.print("  false_block: {}-{}\n", .{ blk.start, blk.start + blk.len });
                }
            },
            .record_init => |value| {
                std.debug.print("  range: {}-{}\n", .{ value.exprs.start, value.exprs.start + value.exprs.len });
            },
            .array_init => |value| {
                std.debug.print("  range: {}-{}\n", .{ value.exprs.start, value.exprs.start + value.exprs.len });
            },

            .loop => |loop| {
                std.debug.print("  loop_block: {}-{}\n", .{ loop.loop_block.start, loop.loop_block.start + loop.loop_block.len });
            },
            .member_access => |acc| {
                std.debug.print("  expr: {}-{}\n", .{ acc.expr.file, acc.expr.index });
                std.debug.print("  index: {}\n", .{acc.index});
            },
            .variant => |varn| {
                std.debug.print("  expr: {}-{}\n", .{ varn.ty_node.file, varn.ty_node.index });
                std.debug.print("  declared index: {}\n", .{varn.declared_index});
                std.debug.print("  index: {}\n", .{varn.index});
                std.debug.print("  partial: {}\n", .{varn.partial});

                if (varn.init) |init| {
                    std.debug.print("  init: {}\n", .{init});
                }
            },
            .@"break" => |brk| {
                if (brk.expr) |expr| {
                    std.debug.print("  expr: {}-{}\n", .{ expr.file, expr.index });
                }
            },
            .ret => |ret| {
                if (ret.expr) |expr| {
                    std.debug.print("  expr: {}-{}\n", .{ expr.file, expr.index });
                }
            },
        }
    }
};

pub const InstructionKind = union(enum) {
    constant,
    identifier: node.NodeId,
    argument: InstructionId,

    binding: struct {
        node: node.NodeId,
        tags: node.SymbolTag.Tag,
        value: InstructionId,
    },

    assign: struct {
        left: InstructionId,
        right: InstructionId,
    },

    binary_expr: struct {
        left: InstructionId,
        op: node.Operator,
        right: InstructionId,
    },

    unary_expr: struct {
        op: node.Operator,
        expr: InstructionId,
    },
    invoke: struct {
        expr: InstructionId,
        args: InstructionRange,
    },
    subscript: struct {
        expr: InstructionId,
        sub: InstructionId,
    },
    reference: struct {
        expr: InstructionId,
    },
    dereference: struct {
        expr: InstructionId,
    },

    if_expr: struct {
        cond: InstructionId,
        // captures: ?NodeRange,
        true_block: InstructionRange,
        false_block: ?InstructionRange,
    },

    record_init: struct {
        exprs: InstructionRange,
    },
    array_init: struct {
        exprs: InstructionRange,
    },

    loop: struct {
        // captures: ?NodeRange,
        loop_block: InstructionRange,
    },
    member_access: struct {
        expr: InstructionId,
        index: usize,
    },
    variant: struct {
        ty_node: node.NodeId,
        declared_index: usize,
        index: usize,
        partial: bool,
        init: ?InstructionId,
    },
    direct_ref: node.NodeId,
    @"break": struct {
        expr: ?InstructionId,
    },

    ret: struct {
        expr: ?InstructionId,
    },
};

pub const InstructionId = struct {
    file: u32,
    index: u32,
};

pub const InstructionRange = struct {
    start: u32,
    len: u32,
};

pub const FunctionValue = struct {
    node_id: node.NodeId,
    instructions: ?InstructionRange,
};

pub const TypeValue = struct {
    node_id: node.NodeId,
    // ty: typecheck.Type,
    // instructions: InstructionRange,
};

pub const SavePoint = struct {
    instruction_length: usize,
    instruction_range_length: usize,
};

pub const BoundValue = struct {
    value: Value,
    mutable: bool,
};

pub const Evaluator = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    d: *diags.Diagnostics,

    nodes: []const node.Node,
    node_ranges: []const node.NodeId,

    analyzer: *const analyze.Analyzer,

    instructions: std.ArrayList(Instruction),
    instruction_ranges: std.ArrayList(InstructionId),
    functions: std.AutoHashMap(node.NodeId, FunctionValue),
    types: std.AutoHashMap(node.NodeId, TypeValue),

    types_map: std.AutoHashMap(InstructionId, typecheck.Type),
    declared_types_map: std.AutoHashMap(InstructionId, typecheck.Type),

    typechecker: *const typecheck.TypeChecker,

    bound_values: std.ArrayList(std.AutoHashMap(node.NodeId, BoundValue)),
    eval_const: bool,
    instr_to_node: std.AutoHashMap(InstructionId, node.NodeId),

    variant_instr: ?InstructionId = null,
    greedy: bool = true,
    make_ref: bool = false,
    generic_ctx: ?node.NodeId = null,

    const Self = @This();

    pub fn init(
        d: *diags.Diagnostics,
        nodes: []const node.Node,
        node_ranges: []const node.NodeId,
        analyzer: *const analyze.Analyzer,
        typechecker: *const typecheck.TypeChecker,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
    ) Self {
        return .{
            .d = d,
            .gpa = gpa,
            .arena = arena,
            .nodes = nodes,
            .node_ranges = node_ranges,
            .analyzer = analyzer,
            .typechecker = typechecker,
            .instructions = std.ArrayList(Instruction).init(gpa),
            .instruction_ranges = std.ArrayList(InstructionId).init(gpa),
            .functions = std.AutoHashMap(node.NodeId, FunctionValue).init(gpa),
            .types = std.AutoHashMap(node.NodeId, TypeValue).init(gpa),
            .bound_values = std.ArrayList(std.AutoHashMap(node.NodeId, BoundValue)).init(gpa),
            .eval_const = false,
            .instr_to_node = std.AutoHashMap(InstructionId, node.NodeId).init(gpa),

            .types_map = std.AutoHashMap(InstructionId, typecheck.Type).init(gpa),
            .declared_types_map = std.AutoHashMap(InstructionId, typecheck.Type).init(gpa),
        };
    }

    pub fn setup(self: *Self) !void {
        try self.pushScope();
    }

    pub fn eval(self: *Self, ids: []const node.NodeId) ![]const InstructionId {
        var these_instrs = std.ArrayList(InstructionId).init(self.arena);

        for (ids) |id| {
            const instr = try self.evalNode(id);

            if (instr) |i| {
                try these_instrs.append(i);
            }
        }

        {
            std.debug.print("Declared Types: \n", .{});
            var it = self.declared_types_map.iterator();
            while (it.next()) |ty| {
                self.printTypeMap(ty.key_ptr.*, ty.value_ptr.*);
                std.debug.print("\n", .{});
            }
        }

        {
            std.debug.print("Node Types: \n", .{});
            var it = self.types_map.iterator();
            while (it.next()) |ty| {
                self.printTypeMap(ty.key_ptr.*, ty.value_ptr.*);
                std.debug.print("\n", .{});
            }
        }

        const starti = self.instruction_ranges.items.len;
        try self.instruction_ranges.appendSlice(these_instrs.items);
        return self.instruction_ranges.items[starti..];
    }

    fn printTypeMap(self: *const Self, instr_id: InstructionId, ty: typecheck.Type) void {
        std.debug.print("Instr: ", .{});
        typecheck.TypeChecker.printIntCol(instr_id.index);
        std.debug.print(" => ", .{});
        self.typechecker.interner.printTy(ty);
    }

    pub fn evalNode(self: *Self, id: node.NodeId) EvalError!?InstructionId {
        const node_value = self.nodes[id.index];
        const result = switch (node_value.kind) {
            .int_literal => |value| try self.createConst(.{ .int = @bitCast(value) }),
            .float_literal => |value| try self.createConst(.{ .float = value }),
            .bool_literal => |value| try self.createConst(.{ .bool = value }),
            .string_literal => |value| try self.createConst(.{ .str = value }),
            .identifier => |_| blk: {
                const ref_node = self.analyzer.node_ref.getEntry(id) orelse @panic("No noderef entry");
                if (self.eval_const) {
                    var resolved_value = self.resolveValueUp(ref_node.value_ptr.*);
                    if (self.greedy and resolved_value == null) {
                        _ = try self.evalNode(ref_node.value_ptr.*);
                        resolved_value = self.resolveValueUp(ref_node.value_ptr.*);
                    }

                    if (resolved_value) |value| {
                        if (self.make_ref) {
                            break :blk try self.createConst(.{
                                .ref = .{
                                    .node_id = ref_node.value_ptr.*,
                                    .mutable = value.mutable,
                                },
                            });
                        } else {
                            break :blk try self.createConst(value.value.kind);
                        }
                    } else if (self.functions.get(ref_node.value_ptr.*)) |func| {
                        break :blk try self.createConst(.{ .func = func });
                    } else if (self.types.get(ref_node.value_ptr.*)) |ty| {
                        _ = ty;
                        @panic("ty not bound!");
                    } else {
                        @panic("value not bound!");
                    }
                } else {
                    break :blk try self.createInstruction(.{ .identifier = ref_node.value_ptr.* }, id);
                }
            },
            .binary_expr => |expr| blk: {
                const save_point = self.save();

                if (self.eval_const) {
                    const rvalid = try self.evalNode(expr.right) orelse @panic("Invalid operand");
                    switch (expr.op) {
                        .assign,
                        .plus_eq,
                        .minus_eq,
                        .times_eq,
                        .divide_eq,
                        .bitor_eq,
                        .bitxor_eq,
                        => {
                            const actual_op: ?node.Operator = switch (expr.op) {
                                .assign => null,
                                .plus_eq => .plus,
                                .minus_eq => .minus,
                                .times_eq => .times,
                                .divide_eq => .divide,
                                .bitor_eq => .bitor,
                                .bitxor_eq => .bitxor,
                                else => unreachable,
                            };

                            self.make_ref = true;
                            errdefer self.make_ref = false;
                            const lval_ref_id = try self.evalNode(expr.left) orelse @panic("Invalid operand");
                            self.make_ref = false;
                            const lval_ref = self.instructions.items[lval_ref_id.index];

                            if (lval_ref.kind != .constant or lval_ref.value.?.kind != .ref) {
                                std.log.err("Expecteds left hand side to be a reference (lvalue)", .{});
                                break :blk try self.createConst(.undef);
                            }

                            if (self.resolveValueUpPtr(lval_ref.value.?.kind.ref.node_id)) |value| {
                                if (!value.mutable) {
                                    std.log.err("Left hand side is immutable!", .{});
                                    break :blk try self.createConst(.undef);
                                }

                                if (self.getConst(rvalid)) |rval| {
                                    const new_val = if (actual_op) |op|
                                        evalBin(value.value, rval.*, op)
                                    else
                                        rval.kind;

                                    if (new_val) |val| {
                                        value.value = .{ .kind = val };
                                    }

                                    break :blk try self.createConst(.undef);
                                }

                                std.log.err("Right hand side is not const!", .{});
                                break :blk try self.createConst(.undef);
                            } else {
                                std.log.err("Expecteds left hand side to be a reference (lvalue)", .{});
                            }
                        },
                        else => {},
                    }

                    const lvalid = try self.evalNode(expr.left) orelse @panic("Invalid operand");

                    if (self.getConst(lvalid)) |lval| {
                        if (self.getConst(rvalid)) |rval| {
                            const sync_point = self.save();
                            self.reset(save_point);
                            if (std.meta.activeTag(lval.kind) != std.meta.activeTag(rval.kind)) {
                                std.log.err("Values are not the same for binaary expression!", .{});
                            }

                            if (evalBin(lval.*, rval.*, expr.op)) |val| {
                                break :blk try self.createConst(val);
                            }
                            self.reset(sync_point);

                            break :blk try self.createConst(.undef);
                        }
                    }
                }

                const lvalid = try self.evalNode(expr.left) orelse @panic("Invalid operand");

                switch (expr.op) {
                    .member_access => {
                        var ref_ns_type = false;
                        var orig_ty = self.getType(expr.left).?;
                        const rhs = self.nodes[expr.right.index].kind.identifier;

                        var left_ty = orig_ty.unwrapToRefBase();

                        while (left_ty.* == .named or left_ty.* == .owned_type) {
                            switch (left_ty.*) {
                                .named => left_ty = self.getDeclaredType(left_ty.named).?.owned_type.base,
                                .owned_type => {
                                    orig_ty = self.typechecker.interner.namedTy(left_ty.owned_type.binding);
                                    left_ty = left_ty.owned_type.base;
                                    ref_ns_type = true;
                                },
                                else => unreachable,
                            }
                        }

                        left_ty = left_ty.unwrapToRefBase();

                        if (ref_ns_type) {
                            switch (left_ty.*) {
                                .@"union" => |un| {
                                    const variant_index = un.variants.multi_type_keyed_impl;
                                    const variants = &self.typechecker.interner.multi_types_keyed.items[variant_index];
                                    const variant_indicies = self.typechecker.interner.multi_types.items[un.indicies.multi_type_impl.start .. un.indicies.multi_type_impl.start + un.indicies.multi_type_impl.len];
                                    const var_index = variants.getIndex(rhs).?;

                                    const partial = variants.values()[var_index].* != .unit and self.variant_instr != null;

                                    break :blk try self.createInstruction(.{
                                        .variant = .{
                                            .ty_node = orig_ty.named,
                                            .declared_index = var_index,
                                            .index = variant_indicies[var_index].simple_int_value,
                                            .init = self.variant_instr,
                                            .partial = partial,
                                        },
                                    }, id);
                                },
                                else => {
                                    const left_ty_str = self.typechecker.interner.printTyToStr(left_ty, self.arena);
                                    std.log.err("Type: {s}", .{left_ty_str});
                                    // self.d.addErr(node_id, "LHS does not support field access!", .{}, .{});
                                    break :blk try self.createConst(.undef);
                                },
                            }
                        } else {
                            switch (left_ty.*) {
                                .record => |rec| {
                                    const fields_index = rec.fields.multi_type_keyed_impl;
                                    const fields = &self.typechecker.interner.multi_types_keyed.items[fields_index];

                                    break :blk try self.createInstruction(.{
                                        .member_access = .{
                                            .expr = lvalid,
                                            .index = fields.getIndex(rhs).?,
                                        },
                                    }, id);
                                },
                                .@"union" => |un| {
                                    const variant_index = un.variants.multi_type_keyed_impl;
                                    const variants = &self.typechecker.interner.multi_types_keyed.items[variant_index];
                                    // const variant_indicies = self.typechecker.interner.multi_types.items[un.indicies.multi_type_impl.start .. un.indicies.multi_type_impl.start + un.indicies.multi_type_impl.len];
                                    const var_index = variants.getIndex(rhs).?;

                                    break :blk try self.createInstruction(.{
                                        .member_access = .{
                                            .expr = lvalid,
                                            .index = var_index,
                                        },
                                    }, id);
                                },
                                else => {
                                    const left_ty_str = self.typechecker.interner.printTyToStr(left_ty, self.arena);
                                    std.log.err("Type: {s}", .{left_ty_str});
                                    // self.d.addErr(node_id, "LHS does not support field access!", .{}, .{});
                                    break :blk try self.createConst(.undef);
                                },
                            }
                        }
                    },
                    else => {},
                }

                const rvalid = try self.evalNode(expr.right) orelse @panic("Invalid operand");

                switch (expr.op) {
                    .assign,
                    .plus_eq,
                    .minus_eq,
                    .times_eq,
                    .divide_eq,
                    .bitor_eq,
                    .bitxor_eq,
                    => {
                        const actual_op: ?node.Operator = switch (expr.op) {
                            .assign => null,
                            .plus_eq => .plus,
                            .minus_eq => .minus,
                            .times_eq => .times,
                            .divide_eq => .divide,
                            .bitor_eq => .bitor,
                            .bitxor_eq => .bitxor,
                            else => unreachable,
                        };

                        const new_value = if (actual_op) |op| blk1: {
                            break :blk1 try self.createInstruction(.{
                                .binary_expr = .{
                                    .left = lvalid,
                                    .op = op,
                                    .right = rvalid,
                                },
                            }, id);
                        } else rvalid;

                        break :blk try self.createInstruction(.{
                            .assign = .{
                                .left = lvalid,
                                .right = new_value,
                            },
                        }, id);
                    },
                    else => {},
                }

                break :blk try self.createInstruction(.{
                    .binary_expr = .{
                        .left = lvalid,
                        .op = expr.op,
                        .right = rvalid,
                    },
                }, id);
            },
            .unary_expr => |expr| blk: {
                const expr_id = try self.evalNode(expr.expr) orelse @panic("Invalid operand");

                if (self.eval_const) {
                    if (self.getConst(expr_id)) |exp_val| {
                        switch (exp_val.kind) {
                            .int => |ivalue| {
                                switch (expr.op) {
                                    .minus => break :blk try self.createConst(.{ .int = -@as(i64, @bitCast(ivalue)) }),
                                    else => std.log.err("Unsupported unary operator for value!", .{}),
                                }
                            },
                            .float => |fvalue| {
                                switch (expr.op) {
                                    .minus => break :blk try self.createConst(.{ .float = -fvalue }),
                                    else => std.log.err("Unsupported unary operator for value!", .{}),
                                }
                            },
                            else => std.log.err("Unsupported value for binary expression!", .{}),
                        }

                        break :blk try self.createConst(.undef);
                    }
                }

                break :blk try self.createInstruction(.{
                    .unary_expr = .{
                        .op = expr.op,
                        .expr = expr_id,
                    },
                }, id);
            },
            .if_expr => |expr| blk: {
                const save_point = self.save();
                const cond_id = try self.evalNode(expr.cond) orelse @panic("invalid condition");

                if (self.eval_const) {
                    if (self.getConst(cond_id)) |cond_val| {
                        switch (cond_val.kind) {
                            .bool => |bvalue| {
                                self.reset(save_point);

                                var result: ?InstructionId = null;
                                if (bvalue) {
                                    const item_nodes = self.nodesRange(expr.true_block);
                                    for (item_nodes[0 .. item_nodes.len - 1]) |item| {
                                        _ = try self.evalNode(item);
                                    }
                                    if (item_nodes.len > 0) {
                                        result = try self.evalNode(item_nodes[item_nodes.len - 1]);
                                    }
                                } else if (expr.false_block) |block| {
                                    const item_nodes = self.nodesRange(block);
                                    for (item_nodes[0 .. item_nodes.len - 1]) |item| {
                                        _ = try self.evalNode(item);
                                    }
                                    if (item_nodes.len > 0) {
                                        result = try self.evalNode(item_nodes[item_nodes.len - 1]);
                                    }
                                }

                                break :blk result;
                            },
                            else => @panic("Expected boolean expresion in if condition!"),
                        }
                    }
                }

                const true_block = try self.evalRange(expr.true_block);
                const false_block = if (expr.false_block) |block| try self.evalRange(block) else null;

                break :blk try self.createInstruction(.{
                    .if_expr = .{
                        .cond = cond_id,
                        .true_block = true_block,
                        .false_block = false_block,
                    },
                }, id);
            },
            .loop => |expr| blk: {
                const save_point = self.save();

                if (self.eval_const) {
                    const item_nodes = self.nodesRange(expr.loop_block);
                    var once = false;
                    if (expr.expr != null) {
                        while (true) {
                            self.reset(save_point);
                            const cond_id = try self.evalNode(expr.expr.?) orelse @panic("invalid condition");

                            if (self.getConst(cond_id)) |cond_val| {
                                switch (cond_val.kind) {
                                    .bool => |bvalue| {
                                        if (!bvalue) break;
                                    },
                                    else => std.debug.panic("Expected boolean expresion in if condition! {}", .{cond_val}),
                                }
                            }

                            once = true;

                            for (item_nodes) |item| {
                                _ = try self.evalNode(item);
                            }
                        }

                        if (!once and expr.else_block != null) {
                            const else_item_nodes = self.nodesRange(expr.else_block.?);
                            for (else_item_nodes) |item| {
                                _ = try self.evalNode(item);
                            }
                        }

                        // @TODO: check breaks before executing this
                        if (once and expr.finally_block != null) {
                            const finally_item_nodes = self.nodesRange(expr.finally_block.?);
                            for (finally_item_nodes) |item| {
                                _ = try self.evalNode(item);
                            }
                        }

                        break :blk try self.createConst(.undef);
                    } else {
                        while (true) {
                            for (item_nodes) |item| {
                                _ = try self.evalNode(item);
                            }
                        }

                        break :blk try self.createConst(.undef);
                    }
                }

                var starti = self.instruction_ranges.items.len;
                var add_len: u32 = 0;
                if (expr.expr) |cond| {
                    const cond_id = try self.evalNode(cond) orelse @panic("invalid condition");

                    const starti_true = self.instruction_ranges.items.len;
                    if (expr.finally_block) |block| {
                        _ = try self.evalRange(block);
                    }

                    try self.instruction_ranges.append(try self.createInstruction(.{
                        .@"break" = .{
                            .expr = null,
                        },
                    }, id));

                    starti = self.instruction_ranges.items.len;
                    try self.instruction_ranges.append(try self.createInstruction(.{
                        .if_expr = .{
                            .cond = cond_id,
                            .false_block = .{
                                .start = @truncate(starti_true),
                                .len = @truncate(starti - starti_true),
                            },
                            .true_block = .{
                                .start = @truncate(starti_true),
                                .len = 0,
                            },
                        },
                    }, id));
                    add_len = 1;
                }

                var loop_block = try self.evalRange(expr.loop_block);
                loop_block.start = @truncate(starti);
                loop_block.len += add_len;

                const loop = try self.createInstruction(.{
                    .loop = .{
                        .loop_block = loop_block,
                    },
                }, id);

                if (expr.else_block) |eblock| {
                    if (expr.expr) |cond| {
                        const cond_id = try self.evalNode(cond) orelse @panic("invalid condition");
                        starti = self.instruction_ranges.items.len;
                        try self.instruction_ranges.append(loop);
                        const leni = self.instruction_ranges.items.len - starti;

                        const else_block = try self.evalRange(eblock);

                        break :blk try self.createInstruction(.{
                            .if_expr = .{
                                .cond = cond_id,
                                .true_block = .{
                                    .start = @truncate(starti),
                                    .len = @truncate(leni),
                                },
                                .false_block = else_block,
                            },
                        }, id);
                    } else {
                        break :blk loop;
                    }
                } else {
                    break :blk loop;
                }
            },
            .array_init_or_slice_one => |ai| blk: {
                if (self.eval_const) {
                    @panic("Unimplemetned");
                }

                var ty = self.getType(id) orelse @panic("Unable to get node type");
                if (ty.* == .named) {
                    ty = self.getDeclaredType(ty.named).?.owned_type.base;
                }
                switch (ty.*) {
                    .record => |record_ty| {
                        // Record initilizer

                        const ref_node_id = self.analyzer.node_ref.get(id) orelse @panic("uanble to get node ref");
                        const bind_record_node = &self.nodes[ref_node_id.index].kind.binding;
                        const record_node = &self.nodes[bind_record_node.value.index];
                        const record_scope = blk1: {
                            const path = self.analyzer.node_to_path.get(ref_node_id) orelse @panic("unable to get node path");
                            const scope = self.analyzer.getScopeFromPath(path) orelse @panic("unable to get scope form apth");
                            break :blk1 scope;
                        };

                        var rec_ty: ?typecheck.Type = null;

                        if (self.typechecker.generic_types.contains(id)) {
                            const gen_cache_key = self.typechecker.generic_cache.node_to_key_map.get(id).?;
                            const gen_cache_val = self.typechecker.generic_cache.map.getPtr(gen_cache_key).?;

                            rec_ty = self.typechecker.declared_types.get(id).?;

                            if (gen_cache_val.func_node == null) {
                                try self.evalTypeOrFunc(id, rec_ty.?, record_node.id);
                                gen_cache_val.func_node = id;
                            }
                        }

                        const fields_index = record_ty.fields.multi_type_keyed_impl;
                        const fields = &self.typechecker.interner.multi_types_keyed.items[fields_index];

                        var ordered_fields = std.ArrayList(InstructionId).init(self.arena);
                        try ordered_fields.ensureTotalCapacity(fields.count());
                        ordered_fields.items.len = fields.count();

                        var unchecked_fields = std.bit_set.IntegerBitSet(256).initEmpty();
                        unchecked_fields.setRangeValue(.{ .start = 0, .end = fields.count() }, true);

                        const field_node_id = self.analyzer.node_ref.get(ai.expr) orelse @panic("unable to get node ref");

                        const field_node = self.nodes[field_node_id.index].kind.record_field;
                        const field_name = try self.analyzer.getSegment(field_node.name) orelse @panic("Unable to get field name");
                        const field_scope = record_scope.children.get(field_name) orelse @panic("Unable to get field in funciton scope");
                        const field_index = field_scope.kind.field.index;

                        ordered_fields.items[field_index] = try self.evalNode(ai.value.?) orelse @panic("Invalid argument");

                        unchecked_fields.unset(field_index);

                        if (record_node.kind == .type_record) {
                            const field_nodes = self.nodesRange(record_node.kind.type_record.fields);

                            for (0..fields.count()) |i| {
                                if (unchecked_fields.isSet(i)) {
                                    const decl_field_node_id = field_nodes[i];
                                    const decl_field = self.nodes[decl_field_node_id.index].kind.record_field;

                                    ordered_fields.items[i] = try self.evalNode(decl_field.default.?) orelse @panic("Unable to get default value");
                                }
                            }
                        }

                        const starti = self.instruction_ranges.items.len;
                        try self.instruction_ranges.appendSlice(ordered_fields.items);

                        const instr = try self.createInstruction(.{
                            .record_init = .{
                                .exprs = .{
                                    .start = @truncate(starti),
                                    .len = @truncate(self.instruction_ranges.items.len - starti),
                                },
                            },
                        }, id);

                        if (rec_ty != null) {
                            try self.instr_to_node.put(instr, id);
                            return instr;
                        } else {
                            break :blk instr;
                        }
                    },
                    else => {
                        const starti = self.instruction_ranges.items.len;
                        const expr_id = try self.evalNode(ai.expr) orelse @panic("unable to eval array init node");
                        try self.instruction_ranges.append(expr_id);
                        break :blk try self.createInstruction(.{
                            .array_init = .{
                                .exprs = .{
                                    .start = @truncate(starti),
                                    .len = 1,
                                },
                            },
                        }, id);
                    },
                }
            },
            .array_init => |ai| blk: {
                if (self.eval_const) {
                    @panic("Unimplemetned");
                }

                const range = try self.evalRange(ai.exprs);
                break :blk try self.createInstruction(.{
                    .array_init = .{ .exprs = range },
                }, id);
            },
            .binding => |bind| blk: {
                if (self.getDeclaredType(id)) |ty| {
                    if (ty.* == .owned_type or ty.* == .func) {
                        try self.evalTypeOrFunc(id, ty, bind.value);
                        break :blk null;
                    }
                }
                if (self.getType(bind.value) == null)
                    break :blk null; // Should be generic. @TODO: Maybe do better checking

                const instruction = try self.evalNode(bind.value) orelse @panic("Invalid operand");

                if (self.eval_const or self.instructions.items[instruction.index].kind == .constant) {
                    try self.bound_values.items[self.bound_values.items.len - 1].put(
                        id,
                        .{
                            .value = self.instructions.items[instruction.index].value.?,
                            .mutable = bind.mutable,
                        },
                    );
                }

                break :blk try self.createInstruction(.{
                    .binding = .{
                        .node = id,
                        .tags = bind.tags,
                        .value = instruction,
                    },
                }, id);
            },
            .reference => |expr| blk: {
                if (self.eval_const) {
                    @panic("Unimplemented");
                }

                const value = try self.evalNode(expr.expr) orelse @panic("Invalid operand");
                break :blk try self.createInstruction(.{
                    .reference = .{
                        .expr = value,
                    },
                }, id);
            },
            .dereference => |expr| blk: {
                if (self.eval_const) {
                    @panic("Unimplemented");
                }

                const value = try self.evalNode(expr.expr) orelse @panic("Invalid operand");
                break :blk try self.createInstruction(.{
                    .dereference = .{
                        .expr = value,
                    },
                }, id);
            },
            .const_expr => |expr| blk: {
                const old_eval = self.eval_const;
                self.eval_const = true;

                const instr = try self.evalNode(expr.expr) orelse @panic("Invalid operand");

                self.eval_const = old_eval;

                break :blk instr;
            },
            .const_block => |block| blk: {
                const old_eval = self.eval_const;
                self.eval_const = true;

                const item_nodes = self.nodesRange(block.block);
                for (item_nodes) |item| {
                    _ = try self.evalNode(item);
                }

                self.eval_const = old_eval;

                // @TODO: return value here
                break :blk null;
            },
            .variant_init => |vi| blk: {
                const old_val_instr = self.variant_instr;
                defer self.variant_instr = old_val_instr;

                self.variant_instr = try self.evalNode(vi.init);
                break :blk try self.evalNode(vi.variant);
            },
            .implicit_variant => |iv| blk: {
                const union_named_ty = self.getType(id).?.named;
                const union_ty = self.getDeclaredType(union_named_ty).?.owned_type.base.@"union";

                const variant_index = union_ty.variants.multi_type_keyed_impl;
                const variants = &self.typechecker.interner.multi_types_keyed.items[variant_index];
                const variant_indicies = self.typechecker.interner.multi_types.items[union_ty.indicies.multi_type_impl.start .. union_ty.indicies.multi_type_impl.start + union_ty.indicies.multi_type_impl.len];
                const var_index = variants.getIndex(iv.ident).?;

                // @TODO: maybe we should check if unit type
                const partial = self.variant_instr == null;

                break :blk try self.createInstruction(.{
                    .variant = .{
                        .ty_node = union_named_ty,
                        .declared_index = var_index,
                        .index = variant_indicies[var_index].simple_int_value,
                        .init = self.variant_instr,
                        .partial = partial,
                    },
                }, id);
            },
            // @TODO: Maybe do something with key here?
            .key_value => |kv| try self.evalNode(kv.value),
            .key_value_ident => |kv| try self.evalNode(kv.value),
            .argument => |expr| try self.createInstruction(.{
                .argument = try self.evalNode(expr) orelse @panic("invalid arg"),
            }, id),
            .invoke => |inv| blk: {
                const saved = self.save();

                // Get referenced function info
                const ref_node_id = self.analyzer.node_ref.get(id) orelse @panic("uanble to get node ref");
                const bind_func_node = &self.nodes[ref_node_id.index].kind.binding;
                const func_node = &self.nodes[bind_func_node.value.index];
                const func_scope = blk1: {
                    const path = self.analyzer.node_to_path.get(ref_node_id) orelse @panic("unable to get node path");
                    const scope = self.analyzer.getScopeFromPath(path) orelse @panic("unable to get scope form apth");
                    break :blk1 scope;
                };

                var expr_id: InstructionId = undefined;
                var fn_ty: typecheck.Type = undefined;

                if (self.typechecker.generic_types.contains(id)) {
                    const old_gen = self.generic_ctx;
                    defer self.generic_ctx = old_gen;

                    const gen_cache_key = self.typechecker.generic_cache.node_to_key_map.get(id).?;
                    const gen_cache_val = self.typechecker.generic_cache.map.getPtr(gen_cache_key).?;

                    self.generic_ctx = self.typechecker.generic_cache.node_map.get(id).?;
                    fn_ty = self.typechecker.declared_types.get(id).?;

                    // If we've evaluated the instructions before, don't re evaluate.
                    // We just reference the previous functions node (fid)
                    if (gen_cache_val.func_node) |fid| {
                        expr_id = try self.createInstructionWithType(.{ .direct_ref = fid }, fn_ty);
                        try self.instr_to_node.put(expr_id, fid);
                    } else {
                        try self.evalTypeOrFunc(id, fn_ty, func_node.id);
                        gen_cache_val.func_node = id;

                        expr_id = try self.createInstructionWithType(.{ .direct_ref = id }, fn_ty);
                        try self.instr_to_node.put(expr_id, id);
                    }
                } else {
                    expr_id = try self.evalNode(inv.expr) orelse @panic("Invalid function");
                    fn_ty = self.typechecker.types.get(inv.expr) orelse @panic("No type info for callee");
                }

                const expected_types = self.typechecker.interner.getMultiTypes(fn_ty.func.params);

                var ordered_args = std.ArrayList(InstructionId).init(self.arena);
                try ordered_args.ensureTotalCapacity(expected_types.len);
                ordered_args.items.len = expected_types.len;

                var unused_args = std.bit_set.IntegerBitSet(256).initEmpty();
                unused_args.setRangeValue(.{ .start = 0, .end = expected_types.len }, true);

                // @TODO: work in trailing block
                const arg_nodes = self.nodesRange(inv.args);
                for (arg_nodes) |arg_id| {
                    const param_node_id = self.analyzer.node_ref.get(arg_id) orelse @panic("unable to get node ref");
                    const param_node = &self.nodes[param_node_id.index];
                    const param = &param_node.kind.parameter;

                    const param_name = try self.analyzer.getSegment(param.name) orelse @panic("Unable to get param segment");
                    const param_scope = func_scope.children.get(param_name) orelse @panic("Couldn't get parameter in function");
                    const param_index = param_scope.kind.local.parameter.?;

                    ordered_args.items[param_index] = try self.evalNode(arg_id) orelse @panic("Invalid argument");
                    unused_args.unset(param_index);
                }

                if (func_node.kind == .func) {
                    const param_nodes = self.nodesRange(func_node.kind.func.params);
                    for (0..expected_types.len) |i| {
                        // check if remaining args have a default. error if they dont
                        if (unused_args.isSet(i)) {
                            const param_node_id = param_nodes[i];
                            const param_node = &self.nodes[param_node_id.index];
                            const param = &param_node.kind.parameter;

                            ordered_args.items[i] = try self.evalNode(param.default.?) orelse @panic("Invalid default value");
                        }
                    }
                }

                if (self.eval_const) {
                    const expr_value = self.instructions.items[expr_id.index];

                    if (expr_value.kind == .constant and expr_value.value.?.kind == .func) {
                        try self.pushScope();
                        defer self.popScope();

                        const block = switch (func_node.kind) {
                            .func => |f| blk1: {
                                const param_nodes = self.nodesRange(f.params);
                                std.debug.assert(f.params.len == inv.args.len); // this should be handled in typecheck

                                for (ordered_args.items, 0..) |arg, i| {
                                    const param_node_id = param_nodes[i];
                                    const arg_value = self.instructions.items[arg.index].kind.argument;
                                    const constant_value = self.instructions.items[arg_value.index];
                                    if (constant_value.kind != .constant) {
                                        std.log.err("Attempted to call constant function with runtime arguments!", .{});
                                    }

                                    try self.bound_values.items[self.bound_values.items.len - 1].put(
                                        param_node_id,
                                        .{
                                            .value = self.instructions.items[arg_value.index].value.?,
                                            .mutable = false,
                                        },
                                    );
                                }

                                break :blk1 f.block;
                            },
                            .func_no_params => |f| f.block,
                            else => @panic("Expected function"),
                        };

                        if (block == null) {
                            self.d.addErr(id, "Calling external functions is not allowed at comptime", .{}, .{});
                            return try self.createConst(.undef);
                        }

                        const block_range = try self.evalRange(block.?);
                        const ret_instr = self.instructions.items[self.instruction_ranges.items[block_range.start].index];

                        if (ret_instr.kind == .constant) {
                            self.reset(saved);
                            return try self.createConst(ret_instr.value.?.kind);
                        } else {
                            std.log.err("Unable to evaluate const function!", .{});
                        }
                    } else {
                        std.log.err("Unable to evaluate const function!", .{});
                    }
                }

                const starti = self.instruction_ranges.items.len;
                try self.instruction_ranges.appendSlice(ordered_args.items);

                break :blk try self.createInstruction(.{
                    .invoke = .{
                        .expr = expr_id,
                        .args = .{
                            .start = @truncate(starti),
                            .len = @truncate(self.instruction_ranges.items.len - starti),
                        },
                    },
                }, id);
            },
            .subscript => |sub| blk: {
                if (self.eval_const) {
                    @panic("TODO");
                }

                const expr_id = try self.evalNode(sub.expr) orelse @panic("Unable to get subscript expression");
                const sub_id = try self.evalNode(sub.sub) orelse @panic("Unable to get subscript sub expression");

                break :blk try self.createInstruction(.{
                    .subscript = .{
                        .expr = expr_id,
                        .sub = sub_id,
                    },
                }, id);
            },
            else => blk: {
                std.log.err("Unhandled node: {}", .{node_value});
                std.debug.dumpCurrentStackTrace(null);
                // break :blk try self.createConst(.undef);
                break :blk null;
            },
        };

        if (result) |res| {
            try self.instr_to_node.put(res, id);
        }

        // if (result) |res| {
        //     std.log.info("{} {}", .{ res.index, id.index });
        // }

        return result;
    }

    fn evalTypeOrFunc(self: *Self, bind_id: node.NodeId, ty: typecheck.Type, id: node.NodeId) !void {
        const value_node = self.nodes[id.index];
        switch (value_node.kind) {
            .func => |func| {
                const instrs = if (func.block) |body| blk1: {
                    var instructions = try self.evalRange(body);
                    if (instructions.len > 0) {
                        const last_instr = self.instruction_ranges.items[instructions.start + instructions.len - 1];
                        const last_node = self.node_ranges[body.start + body.len - 1];
                        std.log.info("fsdf {}", .{last_node});
                        const last_instr_ty = self.getType(last_node) orelse @panic("Unable to get type entry for last instructino!");
                        const fn_ret_ty = ty.func.ret_ty;
                        //
                        // TODO: check if return instruction
                        std.debug.assert((last_instr_ty.* == .unit and fn_ret_ty == null) or last_instr_ty == (fn_ret_ty.?));

                        const instr = try self.createInstruction(.{ .ret = .{ .expr = last_instr } }, id);
                        // try self.instruction_ranges.append(instr);
                        self.instruction_ranges.items[self.instruction_ranges.items.len - 1] = instr;
                    } else {
                        const instr = try self.createInstruction(.{ .ret = .{ .expr = null } }, id);
                        try self.instruction_ranges.append(instr);
                        // self.instruction_ranges.items[self.instruction_ranges.items.len - 1] = instr;
                        instructions.len += 1;
                    }
                    break :blk1 instructions;
                } else null;

                try self.functions.put(bind_id, .{
                    .node_id = id,
                    .instructions = instrs,
                });
            },
            .func_no_params => |func| {
                const instrs = if (func.block) |body| blk1: {
                    var instructions = try self.evalRange(body);
                    if (instructions.len > 0) {
                        const last_instr = self.instruction_ranges.items[instructions.start + instructions.len - 1];
                        const last_node = self.node_ranges[body.start + body.len - 1];
                        const last_instr_ty = self.getType(last_node) orelse @panic("Unable to get type entry for last instructino!");
                        const fn_ret_ty = ty.func.ret_ty;
                        //
                        // TODO: check if return instruction
                        std.debug.assert((last_instr_ty.* == .unit and fn_ret_ty == null) or last_instr_ty == (fn_ret_ty.?));

                        const instr = try self.createInstruction(.{ .ret = .{ .expr = last_instr } }, id);
                        // try self.instruction_ranges.append(instr);
                        self.instruction_ranges.items[self.instruction_ranges.items.len - 1] = instr;
                    } else {
                        const instr = try self.createInstruction(.{ .ret = .{ .expr = null } }, id);
                        try self.instruction_ranges.append(instr);
                        // self.instruction_ranges.items[self.instruction_ranges.items.len - 1] = instr;
                        instructions.len += 1;
                    }
                    break :blk1 instructions;
                } else null;

                // instructions.len += 1;
                try self.functions.put(bind_id, .{
                    .node_id = id,
                    .instructions = instrs,
                });
            },
            .type_record,
            .type_union,
            .type_alias,
            .type_ref,
            .type_opt,
            .type_int,
            .type_uint,
            .type_float,
            .identifier,
            => {
                try self.types.put(bind_id, .{
                    .node_id = id,
                    // .ty = ty.named,
                });
            },
            else => std.debug.panic("Unimplemented {}", .{value_node}),
        }
    }

    fn evalBin(lval: Value, rval: Value, op: node.Operator) ?ValueKind {
        return switch (lval.kind) {
            .int => |ivalue| switch (op) {
                // @TODO: see if bitcast is fine here
                .plus => ValueKind{ .int = @bitCast(ivalue + rval.kind.int) },
                .minus => ValueKind{ .int = @bitCast(ivalue - rval.kind.int) },
                .times => ValueKind{ .int = @bitCast(ivalue * rval.kind.int) },
                .divide => ValueKind{ .int = @bitCast(@divFloor(ivalue, rval.kind.int)) },
                .bitand => ValueKind{ .int = @bitCast(ivalue & rval.kind.int) },
                .bitor => ValueKind{ .int = @bitCast(ivalue | rval.kind.int) },
                .bitxor => ValueKind{ .int = @bitCast(ivalue ^ rval.kind.int) },
                .shiftleft => ValueKind{ .int = @bitCast(ivalue >> @as(u6, @intCast(rval.kind.int))) },
                .shiftright => ValueKind{ .int = @bitCast(ivalue << @as(u6, @intCast(rval.kind.int))) },

                .equal => ValueKind{ .bool = ivalue == rval.kind.int },
                .not_equal => ValueKind{ .bool = ivalue != rval.kind.int },
                .gt => ValueKind{ .bool = ivalue > rval.kind.int },
                .gte => ValueKind{ .bool = ivalue >= rval.kind.int },
                .lt => ValueKind{ .bool = ivalue < rval.kind.int },
                .lte => ValueKind{ .bool = ivalue <= rval.kind.int },
                else => {
                    std.log.err("Unsupported value for binary expression!", .{});
                    return null;
                },
            },
            .float => |fvalue| switch (op) {
                .plus => ValueKind{ .float = fvalue + rval.kind.float },
                .minus => ValueKind{ .float = fvalue - rval.kind.float },
                .times => ValueKind{ .float = fvalue * rval.kind.float },
                .divide => ValueKind{ .float = fvalue / rval.kind.float },

                .equal => ValueKind{ .bool = fvalue == rval.kind.float },
                .not_equal => ValueKind{ .bool = fvalue != rval.kind.float },
                .gt => ValueKind{ .bool = fvalue > rval.kind.float },
                .gte => ValueKind{ .bool = fvalue >= rval.kind.float },
                .lt => ValueKind{ .bool = fvalue < rval.kind.float },
                .lte => ValueKind{ .bool = fvalue <= rval.kind.float },
                else => {
                    std.log.err("Unsupported value for binary expression!", .{});
                    return null;
                },
            },
            .bool => |bvalue| switch (op) {
                .equal => ValueKind{ .bool = bvalue == rval.kind.bool },
                .not_equal => ValueKind{ .bool = bvalue != rval.kind.bool },
                else => {
                    std.log.err("Unsupported value for binary expression!", .{});
                    return null;
                },
            },
            else => {
                std.log.err("Unsupported value for binary expression!", .{});
                return null;
            },
        };
    }

    // fn evalFunction()
    // fn evalRange(self: *Self, range: node.NodeRange) !InstructionRange {
    //     self.evalRangeRetLast(range, false);
    // }

    // fn evalRangeRetLast(self: *Self, range: node.NodeRange, ret_last: bool) !InstructionRange {
    fn evalRange(self: *Self, range: node.NodeRange) !InstructionRange {
        if (range.len == 0) return .{
            .start = @truncate(self.instruction_ranges.items.len),
            .len = 0,
        };

        if (self.eval_const) {
            const item_nodes = self.nodesRange(range);
            for (item_nodes[0 .. item_nodes.len - 1]) |item| {
                _ = try self.evalNode(item);
            }

            const starti = self.instruction_ranges.items.len;
            const instr = try self.evalNode(item_nodes[item_nodes.len - 1]);
            if (instr) |i| {
                try self.instruction_ranges.append(i);
            }

            return .{
                .start = @truncate(starti),
                .len = if (instr == null) 0 else 1,
            };
        } else {
            var these_instrs = std.ArrayList(InstructionId).init(self.arena);

            const item_nodes = self.nodesRange(range);
            for (item_nodes) |item| {
                const instr = try self.evalNode(item);
                if (instr) |i| {
                    try these_instrs.append(i);
                }
            }

            const starti = self.instruction_ranges.items.len;
            try self.instruction_ranges.appendSlice(these_instrs.items);
            return .{
                .start = @truncate(starti),
                .len = @truncate(self.instruction_ranges.items.len - starti),
            };
        }
    }

    inline fn pushScope(self: *Self) !void {
        try self.bound_values.append(std.AutoHashMap(node.NodeId, BoundValue).init(self.arena));
    }

    inline fn popScope(self: *Self) void {
        self.bound_values.items.len -= 1;
    }

    fn resolveValueUp(self: *Self, id: node.NodeId) ?BoundValue {
        var current = self.bound_values.items;
        while (current.len > 0) : (current = current[0 .. current.len - 1]) {
            if (current[current.len - 1].get(id)) |val| return val;
        }

        return null;
    }

    fn resolveValueUpPtr(self: *Self, id: node.NodeId) ?*BoundValue {
        var current = self.bound_values.items;
        while (current.len > 0) : (current = current[0 .. current.len - 1]) {
            if (current[current.len - 1].getEntry(id)) |val| return val.value_ptr;
        }

        return null;
    }

    fn getType(self: *const Self, node_id: node.NodeId) ?typecheck.Type {
        if (self.generic_ctx) |gtx| {
            std.log.debug("generic ctx {}", .{gtx});
            const entry = self.typechecker.generic_types.getEntry(gtx) orelse return null;
            return entry.value_ptr.get(node_id);
        } else {
            return self.typechecker.types.get(node_id);
        }
    }

    fn getDeclaredType(self: *const Self, node_id: node.NodeId) ?typecheck.Type {
        if (self.generic_ctx) |gtx| {
            const entry = self.typechecker.generic_declared_types.getEntry(gtx) orelse return null;
            return entry.value_ptr.get(node_id);
        } else {
            return self.typechecker.declared_types.get(node_id);
        }
    }

    inline fn isConst(self: *Self, id: InstructionId) bool {
        return self.instructions.items[id.index].kind == .constant;
    }

    inline fn getConst(self: *Self, id: InstructionId) ?*Value {
        if (!self.isConst(id)) return null;
        return &self.instructions.items[id.index].value.?;
    }

    pub inline fn save(self: *const Self) SavePoint {
        return .{
            .instruction_length = self.instructions.items.len,
            .instruction_range_length = self.instruction_ranges.items.len,
        };
    }

    pub inline fn reset(self: *Self, save_point: SavePoint) void {
        self.instructions.items.len = save_point.instruction_length;
        self.instruction_ranges.items.len = save_point.instruction_range_length;
    }

    fn createInstruction(self: *Self, kind: InstructionKind, original_node: node.NodeId) !InstructionId {
        const index: u32 = @truncate(self.instructions.items.len);

        try self.instructions.append(.{
            .id = .{
                .file = 0,
                .index = index,
            },
            .kind = kind,
            .value = null,
        });

        if (self.getType(original_node)) |ty| {
            try self.types_map.put(.{
                .file = 0,
                .index = index,
            }, ty);
        }
        if (self.getDeclaredType(original_node)) |ty| {
            try self.declared_types_map.put(.{
                .file = 0,
                .index = index,
            }, ty);
        }

        return .{
            .file = 0,
            .index = index,
        };
    }

    fn createInstructionWithDeclaredType(self: *Self, kind: InstructionKind, decl_ty: typecheck.Type) !InstructionId {
        const index: u32 = @truncate(self.instructions.items.len);

        try self.instructions.append(.{
            .id = .{
                .file = 0,
                .index = index,
            },
            .kind = kind,
            .value = null,
        });

        try self.declared_types_map.put(.{
            .file = 0,
            .index = index,
        }, decl_ty);

        return .{
            .file = 0,
            .index = index,
        };
    }

    fn createInstructionWithType(self: *Self, kind: InstructionKind, ty: typecheck.Type) !InstructionId {
        const index: u32 = @truncate(self.instructions.items.len);

        try self.instructions.append(.{
            .id = .{
                .file = 0,
                .index = index,
            },
            .kind = kind,
            .value = null,
        });

        try self.types_map.put(.{
            .file = 0,
            .index = index,
        }, ty);

        return .{
            .file = 0,
            .index = index,
        };
    }

    fn createConst(self: *Self, value: ValueKind) !InstructionId {
        const index: u32 = @truncate(self.instructions.items.len);

        try self.instructions.append(.{
            .id = .{
                .file = 0,
                .index = index,
            },
            .kind = .constant,
            .value = .{ .kind = value },
        });

        return .{
            .file = 0,
            .index = index,
        };
    }

    inline fn nodesRange(self: *const Self, range: node.NodeRange) []const node.NodeId {
        return self.node_ranges[range.start .. range.start + range.len];
    }
};
