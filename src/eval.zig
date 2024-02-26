const std = @import("std");
const node = @import("node.zig");
const analyze = @import("analyze.zig");
const typecheck = @import("typecheck.zig");

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
            .func => |func| std.debug.print("Func {}-{} and {}-{}", .{ func.node_id.file, func.node_id.index, func.instructions.start, func.instructions.len }),
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
        }
    }
};

pub const InstructionKind = union(enum) {
    constant,
    identifier: node.NodeId,

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

    if_expr: struct {
        cond: InstructionId,
        // captures: ?NodeRange,
        true_block: InstructionRange,
        false_block: ?InstructionRange,
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
    instructions: InstructionRange,
};

pub const TypeValue = struct {
    node_id: node.NodeId,
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

    nodes: []const node.Node,
    node_ranges: []const node.NodeId,

    node_refs: analyze.NodeRefMap,

    instructions: std.ArrayList(Instruction),
    instruction_ranges: std.ArrayList(InstructionId),
    functions: std.AutoHashMap(node.NodeId, FunctionValue),
    types: std.AutoHashMap(node.NodeId, TypeValue),

    type_info: typecheck.TypeInfo,

    bound_values: std.ArrayList(std.AutoHashMap(node.NodeId, BoundValue)),
    eval_const: bool,

    make_ref: bool = false,

    const Self = @This();

    pub fn init(
        nodes: []const node.Node,
        node_ranges: []const node.NodeId,
        node_refs: analyze.NodeRefMap,
        type_info: typecheck.TypeInfo,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
    ) Self {
        return .{
            .gpa = gpa,
            .arena = arena,
            .nodes = nodes,
            .node_ranges = node_ranges,
            .node_refs = node_refs,
            .instructions = std.ArrayList(Instruction).init(gpa),
            .instruction_ranges = std.ArrayList(InstructionId).init(gpa),
            .type_info = type_info,
            .functions = std.AutoHashMap(node.NodeId, FunctionValue).init(gpa),
            .types = std.AutoHashMap(node.NodeId, TypeValue).init(gpa),
            .bound_values = std.ArrayList(std.AutoHashMap(node.NodeId, BoundValue)).init(gpa),
            .eval_const = false,
        };
    }

    pub fn eval(self: *Self, ids: []const node.NodeId) ![]const InstructionId {
        var these_instrs = std.ArrayList(InstructionId).init(self.arena);
        try self.pushScope();

        for (ids) |id| {
            const instr = try self.evalNode(id);

            if (instr) |i| {
                try these_instrs.append(i);
            }
        }

        const starti = self.instruction_ranges.items.len;
        try self.instruction_ranges.appendSlice(these_instrs.items);
        return self.instruction_ranges.items[starti..];
    }

    pub fn evalNode(self: *Self, id: node.NodeId) EvalError!?InstructionId {
        const node_value = self.nodes[id.index];
        const result = switch (node_value.kind) {
            .int_literal => |value| try self.createConst(.{ .int = @bitCast(value) }),
            .float_literal => |value| try self.createConst(.{ .float = value }),
            .bool_literal => |value| try self.createConst(.{ .bool = value }),
            .string_literal => |value| try self.createConst(.{ .str = value }),
            .identifier => |_| blk: {
                const ref_node = self.node_refs.getEntry(id) orelse @panic("No noderef entry");
                if (self.eval_const) {
                    if (self.resolveValueUp(ref_node.value_ptr.*)) |value| {
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
                    break :blk try self.createInstruction(.{ .identifier = ref_node.value_ptr.* });
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
                            });
                        } else rvalid;

                        break :blk try self.createInstruction(.{
                            .assign = .{
                                .left = lvalid,
                                .right = new_value,
                            },
                        });
                    },
                    else => {},
                }

                break :blk try self.createInstruction(.{
                    .binary_expr = .{
                        .left = lvalid,
                        .op = expr.op,
                        .right = rvalid,
                    },
                });
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
                });
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
                });
            },
            .binding => |bind| blk: {
                if (self.type_info.declared_types.get(id)) |ty| {
                    if (ty.* == .named or ty.* == .func) {
                        const value_node = self.nodes[bind.value.index];
                        switch (value_node.kind) {
                            .func => |func| {
                                const instructions = try self.evalRange(func.block);
                                try self.functions.put(id, .{
                                    .node_id = bind.value,
                                    .instructions = instructions,
                                });
                            },
                            .func_no_params => |func| {
                                const instructions = try self.evalRange(func.block);
                                try self.functions.put(id, .{
                                    .node_id = bind.value,
                                    .instructions = instructions,
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
                            .array_init_or_slice_one,
                            .identifier,
                            => {
                                try self.types.put(id, .{ .node_id = bind.value });
                            },
                            else => std.debug.panic("Unimplemented {}", .{value_node}),
                        }
                        // @TODO: put these into global defs
                        break :blk null;
                    }
                }
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
                });
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
            // @TODO: Maybe do something with key here?
            .key_value => |kv| try self.evalNode(kv.value),
            .key_value_ident => |kv| try self.evalNode(kv.value),
            .argument => |expr| try self.evalNode(expr),
            .invoke => |inv| blk: {
                const saved = self.save();
                const expr_id = try self.evalNode(inv.expr) orelse @panic("Invalid function");
                if (self.eval_const) {
                    const expr_value = self.instructions.items[expr_id.index];

                    if (expr_value.kind == .constant and expr_value.value.?.kind == .func) {
                        try self.pushScope();
                        defer self.popScope();

                        const args = self.nodesRange(inv.args);
                        const func_node = self.nodes[expr_value.value.?.kind.func.node_id.index];
                        const block = switch (func_node.kind) {
                            .func => |f| blk1: {
                                std.debug.assert(f.params.len == inv.args.len); // this should be handled in typecheck

                                for (args) |arg| {
                                    const arg_instr = try self.evalNode(arg) orelse @panic("Invalid argument");
                                    const ref_node = self.node_refs.getEntry(arg) orelse {
                                        std.log.err("Unable to get node ref entry for argument! {}", .{arg});
                                        continue;
                                    };

                                    try self.bound_values.items[self.bound_values.items.len - 1].put(
                                        ref_node.value_ptr.*,
                                        .{
                                            .value = self.instructions.items[arg_instr.index].value.?,
                                            .mutable = false,
                                        },
                                    );
                                }

                                break :blk1 f.block;
                            },
                            .func_no_params => |f| f.block,
                            else => @panic("Expected function"),
                        };

                        const block_range = try self.evalRange(block);
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

                // @TODO: work in trailing block
                const args = try self.evalRange(inv.args);
                break :blk try self.createInstruction(.{
                    .invoke = .{
                        .expr = expr_id,
                        .args = args,
                    },
                });
            },
            else => blk: {
                std.log.err("Unhandled node: {}", .{node_value});
                // break :blk try self.createConst(.undef);
                break :blk null;
            },
        };

        // if (result) |res| {
        //     std.log.info("{} {}", .{ res.index, id.index });
        // }
        // std.debug.dumpCurrentStackTrace(null);

        return result;
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

    inline fn isConst(self: *Self, id: InstructionId) bool {
        return self.instructions.items[id.index].kind == .constant;
    }

    inline fn getConst(self: *Self, id: InstructionId) ?*Value {
        if (!self.isConst(id)) return null;
        return &self.instructions.items[id.index].value.?;
    }

    inline fn save(self: *const Self) SavePoint {
        return .{
            .instruction_length = self.instructions.items.len,
            .instruction_range_length = self.instruction_ranges.items.len,
        };
    }

    inline fn reset(self: *Self, save_point: SavePoint) void {
        self.instructions.items.len = save_point.instruction_length;
        self.instruction_ranges.items.len = save_point.instruction_range_length;
    }

    fn createInstruction(self: *Self, kind: InstructionKind) !InstructionId {
        const index: u32 = @truncate(self.instructions.items.len);

        try self.instructions.append(.{
            .id = .{
                .file = 0,
                .index = index,
            },
            .kind = kind,
            .value = null,
        });

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
