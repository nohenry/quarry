const std = @import("std");
const node = @import("node.zig");
const parse = @import("parser.zig");
const activeTag = std.meta.activeTag;

pub const Symbol = struct { kind: SymbolKind };

pub const SymbolKind = union(enum) {
    const_expr: struct {
        ty: Type,
    },
    label: usize,
};

pub const Type = union(enum(u32)) {
    int: u32,
    uint: u32,
    float: u32,
    ascii: void,
};

pub const AssembleError = error{
    DuplicateLabel,
    UnexpectedNode,
    InvalidInstruction,
    InvalidOperands,
};

const InstructionConfig = struct {
    /// kinds
    []const AArch64.OperandKind,
    /// opcode
    u32,
};

const Instruction = struct {
    kind_op1: u4,
    kind1: InstructionKind1,
    kind2: InstructionKind2,
    operand_configs: []const InstructionConfig = &[0]InstructionConfig{},
};

const InstructionKind1 = union {
    op0: u3,
    op0123: packed struct(u12) {
        op0: u1 = 0,
        op1: u1 = 0,
        op2: u4 = 0,
        op3: u6 = 0,
    },
};

const InstructionKind2 = union {
    opc: u2,
    opS: packed struct { op: u1, S: u1 },
    opcN: packed struct { opc: u2, N: u1 },
};

const KV = struct { []const u8, Instruction };
const arm_instructions = std.ComptimeStringMap(Instruction, [_]KV{
    // Move wide (immediate)
    .{ "movn", .{ .kind_op1 = 0b1000, .kind1 = .{ .op0 = 0b101 }, .kind2 = .{ .opc = 0b00 } } },
    .{ "movz", .{ .kind_op1 = 0b1000, .kind1 = .{ .op0 = 0b101 }, .kind2 = .{ .opc = 0b10 } } },
    .{ "movk", .{ .kind_op1 = 0b1000, .kind1 = .{ .op0 = 0b101 }, .kind2 = .{ .opc = 0b11 } } },

    // Add/subtract (immediate)
    .{ "add", .{ .kind_op1 = 0b1000, .kind1 = .{ .op0 = 0b010 }, .kind2 = .{ .opS = .{ .op = 0, .S = 0 } } } },
    .{ "adds", .{ .kind_op1 = 0b1000, .kind1 = .{ .op0 = 0b010 }, .kind2 = .{ .opS = .{ .op = 0, .S = 1 } } } },
    .{ "sub", .{ .kind_op1 = 0b1000, .kind1 = .{ .op0 = 0b010 }, .kind2 = .{ .opS = .{ .op = 1, .S = 0 } } } },
    .{ "subs", .{ .kind_op1 = 0b1000, .kind1 = .{ .op0 = 0b010 }, .kind2 = .{ .opS = .{ .op = 1, .S = 1 } } } },

    // Logical (shifted register)
    .{ "and", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b00, .N = 0 } } } },
    .{ "bic", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b00, .N = 1 } } } },
    .{ "orr", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b01, .N = 0 } } } },
    .{ "orn", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b00, .N = 1 } } } },
    .{ "eor", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b10, .N = 0 } } } },
    .{ "eon", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b10, .N = 1 } } } },
    .{ "ands", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b11, .N = 0 } } } },
    .{ "bics", .{ .kind_op1 = 0b0101, .kind1 = .{ .op0123 = .{} }, .kind2 = .{ .opcN = .{ .opc = 0b11, .N = 1 } } } },
});

// const Operands = struct {
//     dest: ?
// };

pub const Assembler = struct {
    symbols: std.StringHashMap(Symbol),
    parser: *const parse.Parser,

    instructions: std.ArrayList(u32),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, parser: *const parse.Parser) Self {
        return .{
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .parser = parser,
            .instructions = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn assemble(self: *Self, ids: []const node.NodeId) !void {
        for (ids) |id| {
            try self.assembleItem(id);
        }
    }

    pub fn assembleItem(self: *Self, id: node.NodeId) !void {
        const anode = &self.parser.nodes.items[@as(usize, id.index)];

        switch (anode.kind) {
            .label => |value| {
                const entry = try self.symbols.getOrPut(value.name);
                if (entry.found_existing) {
                    return error.DuplicateLabel;
                }

                entry.value_ptr.* = .{ .kind = .{ .label = self.instructions.items.len } };
            },
            .instruction => |value| {
                try self.assembleInstruction(value);
            },
            else => std.log.warn("Unhandled item:\n    {}", .{anode}),
        }
    }

    pub fn assembleInstruction(self: *Self, inst: std.meta.FieldType(node.NodeKind, .instruction)) !void {
        // const inst_value = arm_instructions.get(inst.op) orelse return error.InvalidInstruction;

        const opcode = try AArch64.encode(self, inst.op, self.parser.nodeRange(inst.operands));

        try self.instructions.append(opcode);
    }
};

pub const AArch64 = struct {
    pub const Operand = union(enum) {
        registerw: u8,
        registerx: u8,
        immediate: u16,
        shift_type: std.meta.FieldType(node.NodeKind, .shift_type),

        pub fn isReg(self: *const @This()) bool {
            return self.* == .registerw or self.* == .registerx;
        }

        pub fn reg(self: *const @This()) u5 {
            return switch (self.*) {
                .registerx => |x| @truncate(x),
                .registerw => |w| @truncate(w),
                else => std.debug.panic("Expected register", .{}),
            };
        }
    };

    pub const OperandKind = std.meta.FieldEnum(Operand);

    const KVOp = struct { []const u8, Operand };

    pub const register_count: usize = 32;
    fn createXRegisters() [register_count]KVOp {
        comptime {
            var value: [register_count]KVOp = undefined;
            for (0..register_count) |i| {
                value[i] = .{ std.fmt.comptimePrint("x{}", .{i}), .{ .registerx = i } };
            }

            return value;
        }
    }

    fn createWRegisters() [register_count]KVOp {
        comptime {
            var value: [register_count]KVOp = undefined;
            for (0..register_count) |i| {
                value[i] = .{ std.fmt.comptimePrint("w{}", .{i}), .{ .registerw = i } };
            }

            return value;
        }
    }

    pub const registers = std.ComptimeStringMap(Operand, createXRegisters() ++ createWRegisters());

    pub inline fn withPos(value: anytype, start_position: usize) u32 {
        return @as(u32, value) << start_position;
    }

    pub fn encode(asmb: *const Assembler, op: []const u8, operands: []const node.NodeId) !u32 {
        const inst_info = arm_instructions.get(op) orelse return error.InvalidInstruction;

        switch (inst_info.kind_op1) {
            0b1000 => {

                // Data Processing -- Immediate

                switch (inst_info.kind1.op0) {
                    0b010 => { // Add/subtract (immediate)
                        const aop = try encodeOperand(asmb, operands[0]);
                        const bop = try encodeOperand(asmb, operands[1]);
                        const cop = try encodeOperand(asmb, operands[2]);

                        const sf: u1 = if (aop == .registerw) 0 else if (aop == .registerx) 1 else std.debug.panic("Expected register as first arg!", .{});

                        const result: u32 = withPos(sf, 31) | withPos(inst_info.kind2.opS.op, 30) | withPos(inst_info.kind2.opS.S, 29) | withPos(inst_info.kind_op1, 25) | withPos(cop.immediate, 10) | withPos(bop.reg(), 5) | withPos(aop.reg(), 0);

                        return result;
                    },
                    0b101 => { // Move wide (immediate)
                        const aop = try encodeOperand(asmb, operands[0]);
                        const bop = try encodeOperand(asmb, operands[1]);

                        const sf: u1 = if (aop == .registerw) 0 else if (aop == .registerx) 1 else std.debug.panic("Expected register as first arg!", .{});

                        const result: u32 = withPos(sf, 31) | withPos(inst_info.kind2.opc, 29) | withPos(inst_info.kind_op1, 25) | withPos(inst_info.kind1.op0, 23) | withPos(bop.immediate, 5) | @as(u32, aop.reg() & 0b11111);

                        return result;
                    },
                    else => {},
                }
            },
            0b0101, 0b1101 => {
                // Data Processing -- Register

                const rd = try encodeOperand(asmb, operands[0]);
                const rn = try encodeOperand(asmb, operands[1]);
                const rm = try encodeOperand(asmb, operands[2]);
                const sf: u32 = if (rd == .registerw) 0 else if (rd == .registerx) 1 else std.debug.panic("Expected register as first arg!", .{});

                if (inst_info.kind1.op0123.op1 == 1 and inst_info.kind1.op0123.op2 == 0b0010) {} else {
                    if (activeTag(rd) != activeTag(rn) or activeTag(rd) != activeTag(rm)) {
                        std.debug.panic("Expected all registers to be of the same size!", .{});
                    }
                }

                var result: u32 = withPos(sf, 31) | withPos(inst_info.kind_op1, 25);

                if (inst_info.kind1.op0123.op1 == 0 and inst_info.kind1.op0123.op2 & 0b1000 == 0) {
                    // Logical (shifted register)

                    result |= withPos(inst_info.kind2.opcN.opc, 29) | withPos(inst_info.kind2.opcN.N, 21) | withPos(@as(u5, rm.reg()), 16) | withPos(@as(u5, rn.reg()), 5) | withPos(@as(u5, rd.reg()), 0);

                    if (operands.len == 4) {
                        const shift = try encodeOperand(asmb, operands[3]);
                        if (shift != .shift_type) std.debug.panic("Expecting shift type!!", .{});

                        result |= withPos(@intFromEnum(shift.shift_type.ty), 22) | withPos(@as(u6, @truncate(shift.shift_type.amount)), 10);
                    }

                    return result;
                }
            },
            else => {},
        }

        return error.InvalidInstruction;
    }

    pub fn encodeOperand(asmb: *const Assembler, operand: node.NodeId) !Operand {
        const anode = asmb.parser.nodes.items[operand.index];

        switch (anode.kind) {
            .identifier => |value| {
                if (registers.get(value)) |o| {
                    return o;
                } else {
                    std.debug.panic("Symbols not implemented yet!", .{});
                }
            },
            .int_literal => |value| {
                return .{ .immediate = @truncate(value) };
            },
            .shift_type => |value| return .{ .shift_type = value },
            else => return error.UnexpectedNode,
        }
    }
};
