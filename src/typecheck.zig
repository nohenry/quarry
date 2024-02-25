const std = @import("std");
const node = @import("node.zig");
const analyze = @import("analyze.zig");

pub const BaseType = union(enum) {
    unit: void,
    int_literal: void,
    float_literal: void,
    int: usize,
    uint: usize,
    uptr: void,
    iptr: void,
    float: usize,
    boolean: void,
    str: void,

    array: struct { base: Type, size: usize },
    slice: struct { base: Type, mut: bool },
    optional: struct { base: Type },
    reference: struct { base: Type, mut: bool },

    record: struct {
        backing_field: ?Type,
        fields: Type,
    },
    @"union": struct {
        backing_field: ?Type,
        variants: Type,
    },
    alias: Type,
    named: node.NodeId,

    type: Type,

    multi_type: []const Type,
    multi_type_impl: MultiType,
    multi_type_keyed: std.StringHashMap(Type),
    multi_type_keyed_impl: usize,

    func: struct {
        params: Type,
        ret_ty: ?Type,
    },
};

pub const MultiType = struct { start: u32, len: u32 };
pub const MultiTypeKeyed = struct { name: []const u8, ty: Type };

pub const BaseTypeContext = struct {
    interner: *const TypeInterner,

    pub fn hash(ctx: @This(), key: BaseType) u64 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Shallow);
        return hasher.final();
    }

    pub fn eql(ctx: @This(), a: BaseType, b: BaseType) bool {
        switch (a) {
            .multi_type => |vals| {
                if (b != .multi_type_impl) return false;
                const ind = b.multi_type_impl;

                return std.mem.eql(Type, vals, ctx.interner.multi_types.items[ind.start .. ind.start + ind.len]);
            },
            .multi_type_keyed => |vals| {
                if (b != .multi_type_keyed_impl) return false;

                const bmap = &ctx.interner.multi_types_keyed.items[b.multi_type_keyed_impl];
                if (vals.count() != bmap.count()) return false;

                var ait = vals.iterator();
                var bit = bmap.iterator();
                var aval = ait.next();
                var bval = bit.next();
                while (aval != null and bval != null) {
                    if (aval.?.value_ptr.* != bval.?.value_ptr.*) return false;
                    if (!std.mem.eql(u8, aval.?.key_ptr.*, bval.?.key_ptr.*)) return false;

                    aval = ait.next();
                    bval = bit.next();
                }

                return true;
            },
            else => return std.meta.eql(a, b),
        }
    }
};

pub const TypeMap = std.HashMap(
    BaseType,
    Type,
    BaseTypeContext,
    std.hash_map.default_max_load_percentage,
);

pub const Type = *const BaseType;

pub const TypeInterner = struct {
    allocator: std.mem.Allocator,
    types: TypeMap,
    multi_types: std.ArrayList(Type),
    multi_types_keyed: std.ArrayList(std.StringHashMap(Type)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .types = undefined,
            .multi_types = std.ArrayList(Type).init(allocator),
            .multi_types_keyed = std.ArrayList(std.StringHashMap(Type)).init(allocator),
        };
    }

    pub fn setup(self: *Self) !void {
        const types = TypeMap.initContext(self.allocator, .{ .interner = self });
        // inline for (&.{ 8, 16, 32, 64, 128 }) |size| {
        //     const ity = try self.allocator.create(BaseType);
        //     ity.* = .{ .int = size };
        //     try types.put(.{ .int = size }, ity);

        //     const uty = try self.allocator.create(BaseType);
        //     uty.* = .{ .uint = size };
        //     try types.put(.{ .uint = size }, uty);

        //     const fty = try self.allocator.create(BaseType);
        //     fty.* = .{ .float = size };
        //     try types.put(.{ .float = size }, fty);
        // }

        // const unitty = try self.allocator.create(BaseType);
        // unitty.* = .unit;
        // try types.put(.unit, unitty);

        // const uty = try self.allocator.create(BaseType);
        // uty.* = .uptr;
        // try types.put(.uptr, uty);

        // const ity = try self.allocator.create(BaseType);
        // ity.* = .iptr;
        // try types.put(.iptr, ity);

        // const bty = try self.allocator.create(BaseType);
        // bty.* = .boolean;
        // try types.put(.boolean, bty);

        // const sty = try self.allocator.create(BaseType);
        // sty.* = .str;
        // try types.put(.str, bty);

        self.types = types;
    }

    pub fn unitTy(self: *Self) Type {
        return self.createOrGetTy(.unit);
    }

    pub fn intLiteralTy(self: *Self) Type {
        return self.createOrGetTy(.int_literal);
    }

    pub fn floatLiteralTy(self: *Self) Type {
        return self.createOrGetTy(.float_literal);
    }

    pub fn intTy(self: *Self, size: usize) Type {
        return self.createOrGetTy(.{ .int = size });
    }

    pub fn uintTy(self: *Self, size: usize) Type {
        return self.createOrGetTy(.{ .uint = size });
    }

    pub fn iptrTy(self: *Self) Type {
        return self.createOrGetTy(.iptr);
    }

    pub fn uptrTy(self: *Self) Type {
        return self.createOrGetTy(.uptr);
    }

    pub fn floatTy(self: *Self, size: usize) Type {
        return self.createOrGetTy(.{ .float = size });
    }

    pub fn boolTy(self: *Self) Type {
        return self.createOrGetTy(.boolean);
    }

    pub fn strTy(self: *Self) Type {
        return self.createOrGetTy(.str);
    }

    pub fn arrayTy(self: *Self, base: Type, size: usize) Type {
        return self.createOrGetTy(.{ .array = .{ .base = base, .size = size } });
    }

    pub fn sliceTy(self: *Self, base: Type, mut: bool) Type {
        return self.createOrGetTy(.{ .slice = .{ .base = base, .mut = mut } });
    }

    pub fn optionalTy(self: *Self, base: Type) Type {
        return self.createOrGetTy(.{ .optional = .{ .base = base } });
    }

    pub fn referenceTy(self: *Self, base: Type, mut: bool) Type {
        return self.createOrGetTy(.{ .reference = .{ .base = base, .mut = mut } });
    }

    pub fn recordTy(self: *Self, backing_field: ?Type, fields: std.StringHashMap(Type)) Type {
        const field_tys = self.multiTyKeyed(fields);
        return self.createOrGetTy(.{
            .record = .{
                .backing_field = backing_field,
                .fields = field_tys,
            },
        });
    }

    pub fn unionTy(self: *Self, backing_field: ?Type, variants: std.StringHashMap(Type)) Type {
        const variant_tys = self.multiTyKeyed(variants);
        return self.createOrGetTy(.{
            .@"union" = .{
                .backing_field = backing_field,
                .variants = variant_tys,
            },
        });
    }

    pub fn aliasTy(self: *Self, base: Type) Type {
        return self.createOrGetTy(.{ .alias = base });
    }

    pub fn namedTy(self: *Self, node_id: node.NodeId) Type {
        return self.createOrGetTy(.{ .named = node_id });
    }

    pub fn typeTy(self: *Self, base: Type) Type {
        return self.createOrGetTy(.{ .type = base });
    }

    pub fn multiTy(self: *Self, types: []const Type) Type {
        const ty = self.types.getOrPut(.{ .multi_type = types }) catch unreachable;
        if (ty.found_existing) {
            return ty.value_ptr.*;
        }

        const starti = self.multi_types.items.len;
        self.multi_types.appendSlice(types) catch unreachable;
        const endi = self.multi_types.items.len;

        const val = self.allocator.create(BaseType) catch unreachable;
        val.* = .{
            .multi_type_impl = .{
                .start = @truncate(starti),
                .len = @truncate(endi - starti),
            },
        };

        ty.value_ptr.* = val;
        return ty.value_ptr.*;
    }

    pub fn multiTyKeyed(self: *Self, values: std.StringHashMap(Type)) Type {
        const ty = self.types.getOrPut(.{ .multi_type_keyed = values }) catch unreachable;
        if (ty.found_existing) {
            return ty.value_ptr.*;
        }

        const index = self.multi_types_keyed.items.len;
        self.multi_types_keyed.append(values) catch unreachable;

        const val = self.allocator.create(BaseType) catch unreachable;
        val.* = .{
            .multi_type_keyed_impl = index,
        };

        ty.value_ptr.* = val;
        return ty.value_ptr.*;
    }

    /// Expects multi_type to be .multi_type_impl
    pub fn getMultiTypes(self: *Self, multi_type: Type) []const Type {
        return self.multi_types.items[multi_type.multi_type_impl.start .. multi_type.multi_type_impl.start + multi_type.multi_type_impl.len];
    }

    pub fn funcTyNoParams(self: *Self, ret_ty: ?Type) Type {
        return self.funcTy(&.{}, ret_ty);
    }
    pub fn funcTy(self: *Self, param_tys: []const Type, ret_ty: ?Type) Type {
        const param_multi_ty = self.multiTy(param_tys);

        return self.createOrGetTy(.{
            .func = .{
                .params = param_multi_ty,
                .ret_ty = ret_ty,
            },
        });
    }

    pub fn printTy(self: *const Self, ty: Type) void {
        switch (ty.*) {
            .unit => std.debug.print("unit", .{}),
            .int_literal => std.debug.print("int_literal", .{}),
            .float_literal => std.debug.print("float_literal", .{}),
            .int => |size| std.debug.print("int{}", .{size}),
            .uint => |size| std.debug.print("uint{}", .{size}),
            .uptr => std.debug.print("uint", .{}),
            .iptr => std.debug.print("int", .{}),
            .float => |size| std.debug.print("float{}", .{size}),
            .boolean => std.debug.print("boolean", .{}),
            .str => std.debug.print("str", .{}),

            .array => |val| {
                std.debug.print("[", .{});
                self.printTy(val.base);
                std.debug.print(": {}]", .{val.size});
            },
            .slice => |val| {
                std.debug.print("[", .{});
                if (val.mut)
                    std.debug.print("mut ", .{});
                self.printTy(val.base);
                std.debug.print("]", .{});
            },
            .optional => |val| {
                self.printTy(val.base);
                std.debug.print("?", .{});
            },
            .reference => |val| {
                self.printTy(val.base);
                if (val.mut)
                    std.debug.print("mut ", .{});
                std.debug.print("&", .{});
            },
            .record => |rec| {
                std.debug.print("type", .{});
                if (rec.backing_field) |field| {
                    std.debug.print("(", .{});
                    self.printTy(field);
                    std.debug.print(")", .{});
                }
                self.printTy(rec.fields);
            },
            .@"union" => |uni| {
                std.debug.print("union", .{});
                if (uni.backing_field) |field| {
                    std.debug.print("(", .{});
                    self.printTy(field);
                    std.debug.print(")", .{});
                }
                self.printTy(uni.variants);
            },
            .alias => |base| {
                std.debug.print("type", .{});
                // if (rec.backing_field) |field| {
                //     std.debug.print("(", .{});
                //     self.printTy(field);
                //     std.debug.print(")", .{});
                // }
                std.debug.print(" ", .{});
                self.printTy(base);
            },
            .named => |n| std.debug.print("{}", .{n}),
            .type => |base| {
                std.debug.print("type(", .{});
                self.printTy(base);
                std.debug.print(")", .{});
            },

            .multi_type => |tys| {
                std.debug.print("(", .{});
                if (tys.len > 0) {
                    self.printTy(tys[0]);
                }
                for (tys[1..]) |mty| {
                    std.debug.print(",", .{});
                    self.printTy(mty);
                }
                std.debug.print(")", .{});
            },
            .multi_type_impl => |mty| {
                self.printTy(&.{ .multi_type = self.multi_types.items[mty.start .. mty.start + mty.len] });
            },
            .multi_type_keyed => |kyd| {
                std.debug.print("[", .{});
                var it = kyd.iterator();

                if (it.next()) |val| {
                    self.printTy(val.value_ptr.*);
                    std.debug.print(" {s}", .{val.key_ptr.*});
                }
                while (it.next()) |val| {
                    std.debug.print(", ", .{});
                    self.printTy(val.value_ptr.*);
                    std.debug.print(" {s}", .{val.key_ptr.*});
                }
                std.debug.print("]", .{});
            },
            .multi_type_keyed_impl => |ind| {
                self.printTy(&.{ .multi_type_keyed = self.multi_types_keyed.items[ind] });
            },
            .func => |func| {
                self.printTy(func.params);
                std.debug.print(" ", .{});
                if (func.ret_ty) |ret| {
                    self.printTy(ret);
                } else {
                    std.debug.print("none", .{});
                }
            },
        }
    }

    inline fn createOrGetTy(self: *Self, value: BaseType) Type {
        const ty = self.types.getOrPut(value) catch unreachable;
        if (ty.found_existing) {
            return ty.value_ptr.*;
        }

        const val = self.allocator.create(BaseType) catch unreachable;
        val.* = value;

        ty.value_ptr.* = val;
        return ty.value_ptr.*;
    }
};

pub const TypeChecker = struct {
    arena: std.mem.Allocator,
    interner: *TypeInterner,

    nodes: []const node.Node,
    node_ranges: []const node.NodeId,
    node_refs: analyze.NodeRefMap,

    types: std.AutoHashMap(node.NodeId, Type),
    declared_types: std.AutoHashMap(node.NodeId, Type),

    const Self = @This();

    pub fn init(nodes: []const node.Node, node_ranges: []const node.NodeId, node_refs: analyze.NodeRefMap, allocator: std.mem.Allocator, arena: std.mem.Allocator) !Self {
        const interner = try allocator.create(TypeInterner);
        interner.* = TypeInterner.init(allocator);
        try interner.setup();

        return .{
            .arena = arena,
            .interner = interner,
            .nodes = nodes,
            .node_ranges = node_ranges,
            .node_refs = node_refs,
            .types = std.AutoHashMap(node.NodeId, Type).init(allocator),
            .declared_types = std.AutoHashMap(node.NodeId, Type).init(allocator),
        };
    }

    pub fn typeCheck(self: *Self, nodes: []const node.NodeId) !void {
        std.log.info("Start Typeechking", .{});
        for (nodes) |id| {
            _ = try self.typeCheckNode(id);
        }
        std.log.info("Done Typeechking", .{});

        {
            std.debug.print("Declared Types: \n", .{});
            var it = self.declared_types.iterator();
            while (it.next()) |ty| {
                std.debug.print("{} => ", .{ty.key_ptr.*});
                self.interner.printTy(ty.value_ptr.*);
                std.debug.print("\n", .{});
            }
        }

        {
            std.debug.print("Node Types: \n", .{});
            var it = self.types.iterator();
            while (it.next()) |ty| {
                std.debug.print("{} => ", .{ty.key_ptr.*});
                self.interner.printTy(ty.value_ptr.*);
                std.debug.print("\n", .{});
            }
        }
    }

    pub fn typeCheckNode(self: *Self, node_id: node.NodeId) !Type {
        const node_value = self.nodes[node_id.index];
        const ty = switch (node_value.kind) {
            .binding => |value| {
                var declared_ty = if (value.ty) |ty|
                    try self.typeCheckNode(ty)
                else
                    null;

                declared_ty = if (declared_ty != null and declared_ty.?.* == .type)
                    declared_ty.?.type
                else if (declared_ty == null)
                    null
                else {
                    std.log.err("Invalid Type", .{});
                    return self.interner.unitTy();
                };

                const ty = try self.typeCheckNode(value.value);

                if (declared_ty != null) {
                    if (!self.coerceNode(value.value, ty, declared_ty.?)) {
                        std.log.err("Type of initial value does not match variable type!", .{});
                    }
                    try self.declared_types.put(node_id, declared_ty.?);
                } else {
                    if (ty.* == .record or ty.* == .@"union" or ty.* == .alias) {
                        const named_ty = self.interner.namedTy(node_id);
                        try self.declared_types.put(node_id, named_ty);
                    } else {
                        try self.declared_types.put(node_id, ty);
                    }
                }

                return self.interner.unitTy();
            },

            .identifier => blk: {
                const ref_node = self.node_refs.get(node_id) orelse {
                    std.log.err("Node ref didn't exist!", .{});
                    break :blk self.interner.unitTy();
                };
                if (self.types.get(ref_node)) |ty| break :blk ty;
                if (self.declared_types.get(ref_node)) |ty| break :blk ty;

                std.log.info("Note: Identifier reference hasn't been checked yet. Doing this manually (Is this fine?)'", .{});
                _ = try self.typeCheckNode(ref_node);

                if (self.types.get(ref_node)) |ty| break :blk ty;
                if (self.declared_types.get(ref_node)) |ty| break :blk ty;
                std.log.err("Unable to resolve identifier type info!", .{});

                break :blk self.interner.unitTy();
            },
            .int_literal => |_| return self.interner.intLiteralTy(),
            .float_literal => |_| return self.interner.floatLiteralTy(),
            .string_literal => |_| return self.interner.strTy(),
            .binary_expr => |expr| blk: {
                const left_ty = try self.typeCheckNode(expr.left);
                const right_ty = try self.typeCheckNode(expr.right);

                if (left_ty != right_ty) {
                    std.log.err("Type mismatch!!! {}", .{node_id});
                }

                break :blk left_ty;
            },
            .unary_expr => |expr| blk: {
                const expr_ty = try self.typeCheckNode(expr.expr);
                break :blk expr_ty;
            },
            .func => |func| blk: {
                var param_tys = std.ArrayList(Type).init(self.arena);
                const nodes = self.nodesRange(func.params);

                for (nodes) |id| {
                    const param_ty = try self.typeCheckNode(id);
                    try param_tys.append(param_ty);
                }

                var ret_ty = if (func.ret_ty) |ret_ty|
                    try self.typeCheckNode(ret_ty)
                else
                    null;

                ret_ty = if (ret_ty != null and ret_ty.?.* == .type)
                    ret_ty.?.type
                else if (ret_ty == null) null else blk1: {
                    std.log.err("Invalid Type", .{});
                    break :blk1 self.interner.unitTy();
                };

                {
                    const block_nodes = self.nodesRange(func.block);
                    for (block_nodes) |id| {
                        _ = try self.typeCheckNode(id);
                    }
                }

                break :blk self.interner.funcTy(param_tys.items, ret_ty);
            },
            .func_no_params => |func| blk: {
                var ret_ty = if (func.ret_ty) |ret_ty|
                    try self.typeCheckNode(ret_ty)
                else
                    null;

                ret_ty = if (ret_ty != null and ret_ty.?.* == .type)
                    ret_ty.?.type
                else if (ret_ty == null) null else blk1: {
                    std.log.err("Invalid Type", .{});
                    break :blk1 self.interner.unitTy();
                };

                {
                    const block_nodes = self.nodesRange(func.block);
                    for (block_nodes) |id| {
                        _ = try self.typeCheckNode(id);
                    }
                }

                break :blk self.interner.funcTyNoParams(ret_ty);
            },
            .invoke => |expr| blk: {
                const call_ty = try self.typeCheckNode(expr.expr);
                if (call_ty.* != .func) {
                    std.log.err("Attempted to call a non function type!", .{});
                    break :blk self.interner.unitTy();
                }

                const expected_types = self.interner.getMultiTypes(call_ty.func.params);

                if (expr.args.len != expected_types.len) {
                    std.log.err("Expected {} arguments but got {}", .{ expected_types.len, expr.args.len });
                }

                const arg_nodes = self.nodesRange(expr.args);

                const len = @min(expected_types.len, arg_nodes.len);

                // @TODO: check trailing block arg
                for (arg_nodes[0..len], expected_types[0..len], 0..) |arg_id, exp_ty, i| {
                    const arg_ty = try self.typeCheckNode(arg_id);

                    if (!self.coerceNode(arg_id, arg_ty, exp_ty)) {
                        std.log.err("Function argument mismatch! For arg {}.", .{i}); // @TODO: print the types
                    }
                }

                break :blk if (call_ty.func.ret_ty) |ty|
                    ty
                else
                    self.interner.unitTy();
            },
            .if_expr => |expr| blk: {
                const cond_ty = try self.typeCheckNode(expr.cond);
                // @TODO: Handle captures
                if (cond_ty != self.interner.boolTy()) {
                    std.log.err("Expected if condition to be a bool!", .{});
                }

                const true_block_ty = blk1: {
                    const nodes = self.nodesRange(expr.true_block);
                    for (nodes[0..@max(nodes.len - 1, 0)]) |id| {
                        _ = try self.typeCheckNode(id);
                    }

                    if (nodes.len > 0) {
                        break :blk1 try self.typeCheckNode(nodes[nodes.len - 1]);
                    }

                    break :blk1 self.interner.unitTy();
                };

                const false_block_ty = if (expr.false_block) |block| blk1: {
                    const nodes = self.nodesRange(block);
                    for (nodes[0..@max(nodes.len - 1, 0)]) |id| {
                        _ = try self.typeCheckNode(id);
                    }

                    if (nodes.len > 0) {
                        break :blk1 try self.typeCheckNode(nodes[nodes.len - 1]);
                    }

                    break :blk1 self.interner.unitTy();
                } else null;

                if (false_block_ty) |ty| {
                    break :blk if (canCoerce(ty, true_block_ty))
                        true_block_ty
                    else if (canCoerce(true_block_ty, ty))
                        ty
                    else {
                        // @TODO: log error if they are used as value but dont match
                        break :blk self.interner.unitTy();
                    };
                } else {
                    break :blk self.interner.unitTy();
                }
            },
            .loop => |expr| blk: {
                if (expr.expr) |exp| {
                    // @TODO: check this type with captures
                    const expr_ty = try self.typeCheckNode(exp);
                    if (expr_ty != self.interner.boolTy()) {
                        std.log.err("Expected loop condition to be a bool!", .{});
                    }
                }

                // @TODO: hadle loop block return expressions
                {
                    const nodes = self.nodesRange(expr.loop_block);
                    for (nodes) |id| {
                        _ = try self.typeCheckNode(id);
                    }
                }

                if (expr.else_block) |block| {
                    const nodes = self.nodesRange(block);
                    for (nodes) |id| {
                        _ = try self.typeCheckNode(id);
                    }
                }

                if (expr.finally_block) |block| {
                    const nodes = self.nodesRange(block);
                    for (nodes) |id| {
                        _ = try self.typeCheckNode(id);
                    }
                }

                break :blk self.interner.unitTy();
            },
            .parameter => |param| blk: {
                const ty = try self.typeCheckNode(param.ty);
                const actual_ty = if (ty.* == .type) ty.type else blk1: {
                    std.log.err("Invalid Type", .{});
                    std.debug.dumpCurrentStackTrace(null);
                    break :blk1 self.interner.unitTy();
                };

                if (param.default) |def| {
                    const def_ty = try self.typeCheckNode(def);
                    if (!self.coerceNode(def, def_ty, actual_ty)) {
                        std.log.err("Type of default value does not match parameter type!", .{});
                    }
                }

                break :blk actual_ty;
            },

            .array_init_or_slice_one => |expr| blk: {
                const expr_ty = try self.typeCheckNode(expr.expr);
                const value_expr = if (expr.value) |val|
                    try self.typeCheckNode(val)
                else
                    null;

                if (expr_ty.* == .type) {
                    const ty = if (value_expr) |_|
                        self.interner.arrayTy(expr_ty.*.type, 0)
                    else
                        self.interner.sliceTy(expr_ty.*.type, expr.mut);

                    break :blk self.interner.typeTy(ty);
                } else {
                    break :blk self.interner.arrayTy(expr_ty, 1);
                }
            },

            .array_init => |expr| blk: {
                const nodes = self.nodesRange(expr.exprs);
                if (nodes.len < 2) @panic("whoops");

                // @TODO: do something smarter than just picking first element
                const first_ty = try self.typeCheckNode(nodes[0]);
                for (nodes[1..], 0..) |id, i| {
                    const this_ty = try self.typeCheckNode(id);
                    if (!self.coerceNode(id, this_ty, first_ty)) {
                        std.log.err("Array initializer values type mismatch (position {})", .{i});
                    }
                }

                break :blk self.interner.arrayTy(first_ty, nodes.len);
            },
            .type_record => |rec| blk: {
                const backing_field_ty = if (rec.backing_field) |f|
                    try self.typeCheckNode(f)
                else
                    null;
                var fields = std.StringHashMap(Type).init(self.arena);

                const field_nodes = self.nodesRange(rec.fields);
                for (field_nodes) |id| {
                    const field_node = self.nodes[id.index];
                    switch (field_node.kind) {
                        .record_field => |field_val| {
                            var actual_ty = try self.typeCheckNode(field_val.ty);

                            actual_ty = if (actual_ty.* == .type) actual_ty.type else blk1: {
                                std.log.err("Invalid Type", .{});
                                std.debug.dumpCurrentStackTrace(null);
                                break :blk1 self.interner.unitTy();
                            };

                            if (field_val.default) |def| {
                                const default_ty = try self.typeCheckNode(def);
                                if (!self.coerceNode(def, default_ty, actual_ty)) {
                                    std.log.err("Field default for '{s}' doesn't match field type!", .{field_val.name});
                                }
                            }

                            try fields.put(field_val.name, actual_ty);
                        },
                        else => {
                            _ = try self.typeCheckNode(id);
                        },
                    }
                }

                break :blk self.interner.recordTy(backing_field_ty, fields);
            },
            .type_union => |uni| blk: {
                const backing_field_ty = if (uni.backing_field) |f|
                    try self.typeCheckNode(f)
                else
                    null;
                var variants = std.StringHashMap(Type).init(self.arena);

                const variant_nodes = self.nodesRange(uni.variants);
                for (variant_nodes) |id| {
                    const variant_node = self.nodes[id.index];
                    switch (variant_node.kind) {
                        .union_variant => |var_val| {
                            const name_node = self.nodes[var_val.name.index];
                            const var_ty = if (var_val.ty.eql(var_val.name) and name_node.kind == .identifier)
                                self.interner.unitTy()
                            else blk1: {
                                const actual_ty = try self.typeCheckNode(var_val.ty);

                                break :blk1 if (actual_ty.* == .type) actual_ty.type else {
                                    std.log.err("Invalid Type", .{});
                                    std.debug.dumpCurrentStackTrace(null);
                                    break :blk1 self.interner.unitTy();
                                };
                            };

                            // @TODO: imlement indicies

                            // @TODO: implement type names
                            const name = if (name_node.kind == .identifier)
                                name_node.kind.identifier
                            else
                                @panic("Unimplemented");

                            try variants.put(name, var_ty);
                        },
                        else => {
                            _ = try self.typeCheckNode(id);
                        },
                    }
                }

                break :blk self.interner.unionTy(backing_field_ty, variants);
            },
            .type_ref => |ty| blk: {
                const base_ty = try self.typeCheckNode(ty.ty);
                break :blk self.interner.referenceTy(base_ty, ty.mut);
            },
            .type_opt => |ty| blk: {
                const base_ty = try self.typeCheckNode(ty.ty);
                break :blk self.interner.optionalTy(base_ty);
            },
            .type_alias => |id| blk: {
                const original_ty = try self.typeCheckNode(id);
                break :blk self.interner.aliasTy(original_ty);
            },
            .type_int => |size| blk: {
                if (size == 0) {
                    break :blk self.interner.typeTy(self.interner.iptrTy());
                } else {
                    break :blk self.interner.typeTy(self.interner.intTy(size));
                }
            },
            .type_uint => |size| blk: {
                if (size == 0) {
                    break :blk self.interner.typeTy(self.interner.uptrTy());
                } else {
                    break :blk self.interner.typeTy(self.interner.uintTy(size));
                }
            },
            .type_float => |size| self.interner.typeTy(self.interner.floatTy(size)),

            else => blk: {
                std.log.err("Unhandled case: {}", .{node_value});
                break :blk self.interner.unitTy();
            },
        };

        try self.types.put(node_id, ty);

        return ty;
    }

    pub fn coerceNode(self: *Self, node_id: node.NodeId, from: Type, to: Type) bool {
        if (from == to) return true;
        if (canCoerce(from, to)) {
            const entry = self.types.getOrPut(node_id) catch @panic("Unable to getOrPut");
            entry.value_ptr.* = to;
            return true;
        }

        return false;
    }

    pub fn canCoerce(from: Type, to: Type) bool {
        if (from == to) return true;
        return switch (from.*) {
            .int_literal => switch (to.*) {
                .int, .uint, .uptr, .iptr, .int_literal => true,
                else => false,
            },
            .float_literal => switch (to.*) {
                .float => true,
                else => false,
            },
            else => false,
        };
    }

    inline fn nodesRange(self: *const Self, range: node.NodeRange) []const node.NodeId {
        return self.node_ranges[range.start .. range.start + range.len];
    }
};
