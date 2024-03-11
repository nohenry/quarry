const std = @import("std");
const node = @import("node.zig");
const analyze = @import("analyze.zig");
const eval = @import("eval.zig");
const diags = @import("diagnostics.zig");

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
        indicies: Type,
    },
    alias: Type,
    named: node.NodeId,

    type: Type,
    owned_type: struct {
        binding: node.NodeId,
        base: Type,
    },

    multi_type: []const Type,
    multi_type_impl: MultiType,
    multi_type_keyed: std.StringArrayHashMap(Type),
    multi_type_keyed_impl: usize,

    func: struct {
        params: Type,
        ret_ty: ?Type,
    },

    simple_int_value: usize,

    pub fn unwrapType(self: Type) Type {
        if (self.* != .type) {
            std.log.err("Expected type but found value!", .{});
        }
        return self.*.type;
    }

    pub fn unwrapToRefBase(self: Type) Type {
        return switch (self.*) {
            .reference => |rf| rf.base.unwrapToRefBase(),
            else => self,
        };
    }
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

pub const TypeInfo = struct {
    types: std.AutoHashMap(node.NodeId, Type),
    declared_types: std.AutoHashMap(node.NodeId, Type),
};

pub const TypeInterner = struct {
    allocator: std.mem.Allocator,
    types: TypeMap,
    multi_types: std.ArrayList(Type),
    multi_types_keyed: std.ArrayList(std.StringArrayHashMap(Type)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .types = undefined,
            .multi_types = std.ArrayList(Type).init(allocator),
            .multi_types_keyed = std.ArrayList(std.StringArrayHashMap(Type)).init(allocator),
        };
    }

    pub fn setup(self: *Self) !void {
        const types = TypeMap.initContext(self.allocator, .{ .interner = self });
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

    pub fn recordTy(self: *Self, backing_field: ?Type, fields: std.StringArrayHashMap(Type)) Type {
        const field_tys = self.multiTyKeyed(fields);
        return self.createOrGetTy(.{
            .record = .{
                .backing_field = backing_field,
                .fields = field_tys,
            },
        });
    }

    pub fn unionTy(self: *Self, backing_field: ?Type, variants: std.StringArrayHashMap(Type), indicies: []const Type) Type {
        const variant_tys = self.multiTyKeyed(variants);
        const index_tys = self.multiTy(indicies);
        return self.createOrGetTy(.{
            .@"union" = .{
                .backing_field = backing_field,
                .variants = variant_tys,
                .indicies = index_tys,
            },
        });
    }

    pub fn aliasTy(self: *Self, base: Type) Type {
        return self.createOrGetTy(.{ .alias = base });
    }

    pub fn namedTy(self: *Self, node_id: node.NodeId) Type {
        return self.createOrGetTy(.{ .named = node_id });
    }

    pub fn ownedTypeTy(self: *Self, node_id: node.NodeId, base: Type) Type {
        return self.createOrGetTy(.{ .owned_type = .{
            .binding = node_id,
            .base = base,
        } });
    }

    pub fn typeTy(self: *Self, base: Type) Type {
        return self.createOrGetTy(.{ .type = base });
    }

    pub fn multiTy(self: *Self, types: []const Type) Type {
        const ty = self.types.get(.{ .multi_type = types });
        if (ty) |val| {
            return val;
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

        self.types.put(val.*, val) catch unreachable;

        return val;
    }

    pub fn multiTyKeyed(self: *Self, values: std.StringArrayHashMap(Type)) Type {
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

    pub fn printTyToStr(self: *const Self, ty: Type, allocator: std.mem.Allocator) []const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const buf_writer = buf.writer();
        self.printTyWriter(ty, buf_writer) catch @panic("Printing type failed");
        return buf.items;
    }

    pub fn printTyWriter(self: *const Self, ty: Type, writer: anytype) !void {
        switch (ty.*) {
            .unit => try writer.print("unit", .{}),
            .int_literal => try writer.print("int_literal", .{}),
            .float_literal => try writer.print("float_literal", .{}),
            .int => |size| try writer.print("int{}", .{size}),
            .uint => |size| try writer.print("uint{}", .{size}),
            .uptr => try writer.print("uint", .{}),
            .iptr => try writer.print("int", .{}),
            .float => |size| try writer.print("float{}", .{size}),
            .boolean => try writer.print("boolean", .{}),
            .str => try writer.print("str", .{}),

            .array => |val| {
                try writer.print("[", .{});
                try self.printTyWriter(val.base, writer);
                try writer.print(": {}]", .{val.size});
            },
            .slice => |val| {
                try writer.print("[", .{});
                if (val.mut)
                    try writer.print("mut ", .{});
                try self.printTyWriter(val.base, writer);
                try writer.print("]", .{});
            },
            .optional => |val| {
                try self.printTyWriter(val.base, writer);
                try writer.print("?", .{});
            },
            .reference => |val| {
                try self.printTyWriter(val.base, writer);
                if (val.mut)
                    try writer.print(" mut", .{});
                try writer.print("&", .{});
            },
            .record => |rec| {
                try writer.print("type", .{});
                if (rec.backing_field) |field| {
                    try writer.print("(", .{});
                    try self.printTyWriter(field, writer);
                    try writer.print(")", .{});
                }
                try self.printTyWriter(rec.fields, writer);
            },
            .@"union" => |uni| {
                try writer.print("union", .{});
                if (uni.backing_field) |field| {
                    try writer.print("(", .{});
                    try self.printTyWriter(field, writer);
                    try writer.print(")", .{});
                }
                try self.printTyWriter(uni.variants, writer);
            },
            .alias => |base| {
                try writer.print("alias", .{});
                // if (rec.backing_field) |field| {
                //     try writer.print("(", .{});
                //     try self.printTyWriter(field, writer);
                //     try writer.print(")", .{});
                // }
                try writer.print(" ", .{});
                try self.printTyWriter(base, writer);
            },
            .named => |n| try writer.print("{}", .{n}),
            .type => |base| {
                try writer.print("type(", .{});
                try self.printTyWriter(base, writer);
                try writer.print(")", .{});
            },
            .owned_type => |base| {
                try writer.print("{} - ", .{base.binding});
                try writer.print("type(", .{});
                try self.printTyWriter(base.base, writer);
                try writer.print(")", .{});
            },

            .multi_type => |tys| {
                try writer.print("(", .{});
                if (tys.len > 0) {
                    try self.printTyWriter(tys[0], writer);

                    for (tys[1..]) |mty| {
                        try writer.print(",", .{});
                        try self.printTyWriter(mty, writer);
                    }
                }
                try writer.print(")", .{});
            },
            .multi_type_impl => |mty| {
                try self.printTyWriter(&.{ .multi_type = self.multi_types.items[mty.start .. mty.start + mty.len] }, writer);
            },
            .multi_type_keyed => |kyd| {
                try writer.print("[", .{});
                var it = kyd.iterator();

                if (it.next()) |val| {
                    try self.printTyWriter(val.value_ptr.*, writer);
                    try writer.print(" {s}", .{val.key_ptr.*});
                }
                while (it.next()) |val| {
                    try writer.print(", ", .{});
                    try self.printTyWriter(val.value_ptr.*, writer);
                    try writer.print(" {s}", .{val.key_ptr.*});
                }
                try writer.print("]", .{});
            },
            .multi_type_keyed_impl => |ind| {
                try self.printTyWriter(&.{ .multi_type_keyed = self.multi_types_keyed.items[ind] }, writer);
            },
            .func => |func| {
                try self.printTyWriter(func.params, writer);
                try writer.print(" ", .{});
                if (func.ret_ty) |ret| {
                    try self.printTyWriter(ret, writer);
                } else {
                    try writer.print("none", .{});
                }
            },
            .simple_int_value => |val| {
                try writer.print("{}", .{val});
            },
        }
    }

    pub fn printTy(self: *const Self, ty: Type) void {
        const writer = std.io.getStdOut();
        self.printTyWriter(ty, writer.writer()) catch @panic("Error while printing");
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

pub const GenericCacheItem = union(enum) {
    type: Type,
};

pub const GenericCacheContext = struct {
    cache: *const GenericCache,

    pub fn hash(ctx: @This(), key: GenericCacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        if (key == .impl) {
            const vals = ctx.cache.items.items[key.impl.start .. key.impl.start + key.impl.len];
            std.hash.autoHashStrat(&hasher, vals, .Deep);
        } else {
            std.hash.autoHashStrat(&hasher, key.items, .Deep);
        }

        return hasher.final();
    }

    pub fn eql(ctx: @This(), a: GenericCacheKey, b: GenericCacheKey) bool {
        switch (a) {
            .items => |vals| {
                if (b != .impl) return false;
                const ind = b.impl;
                const other_vals = ctx.cache.items.items[ind.start .. ind.start + ind.len];

                if (vals.len != other_vals.len) return false;

                for (vals, ctx.cache.items.items[ind.start .. ind.start + ind.len]) |a1, b1| {
                    if (!std.meta.eql(a1, b1)) return false;
                }

                return true;
            },
            else => return std.meta.eql(a, b),
        }
    }
};

pub const GenericCacheKey = union(enum) {
    items: []const GenericCacheItem,
    impl: struct { start: u32, len: u32 },
};

pub const GenericCacheValue = struct {
    id: node.NodeId,
    fn_ty: Type,
    func_node: ?node.NodeId = null,
};

pub const GenericCacheMap = std.HashMap(
    GenericCacheKey,
    GenericCacheValue,
    GenericCacheContext,
    std.hash_map.default_max_load_percentage,
);

pub const GenericCache = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList(GenericCacheItem),
    map: GenericCacheMap,
    node_map: std.AutoHashMap(node.NodeId, node.NodeId),
    node_to_key_map: std.AutoHashMap(node.NodeId, GenericCacheKey),

    const Self = @This();

    pub fn init(arena: std.mem.Allocator) Self {
        return .{
            .arena = arena,
            .items = std.ArrayList(GenericCacheItem).init(arena),
            .map = undefined,
            .node_map = std.AutoHashMap(node.NodeId, node.NodeId).init(arena),
            .node_to_key_map = std.AutoHashMap(node.NodeId, GenericCacheKey).init(arena),
        };
    }

    pub fn setup(self: *Self) void {
        self.map = GenericCacheMap.initContext(self.arena, .{ .cache = self });
    }

    pub fn print(self: *const Self) void {
        var it = self.map.iterator();
        while (it.next()) |f| {
            std.debug.print("Cache {} => {}\n", .{ f.key_ptr.*, f.value_ptr.* });
        }
    }

    pub fn put(self: *Self, node_id: node.NodeId, items: []const GenericCacheItem, ty: Type) !void {
        const value = self.map.getEntry(.{ .items = items });

        if (value == null) {
            const starti = self.items.items.len;
            try self.items.appendSlice(items);
            const endi = self.items.items.len;

            const key = GenericCacheKey{
                .impl = .{
                    .start = @truncate(starti),
                    .len = @truncate(endi - starti),
                },
            };

            try self.map.put(key, .{
                .id = node_id,
                .fn_ty = ty,
            });

            try self.node_map.put(node_id, node_id);
            try self.node_to_key_map.put(node_id, key);
        } else {
            try self.node_map.put(node_id, value.?.value_ptr.id);
            try self.node_to_key_map.put(node_id, value.?.key_ptr.*);
        }
    }

    pub inline fn get(self: *Self, items: []const GenericCacheItem) ?*GenericCacheValue {
        const ptr = self.map.getPtr(.{ .items = items });
        return ptr;
    }

    pub inline fn getEntry(self: *Self, items: []const GenericCacheItem) ?GenericCacheMap.Entry {
        const ptr = self.map.getEntry(.{ .items = items });
        return ptr;
    }
};

pub const TypeChecker = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    interner: *TypeInterner,
    d: *diags.Diagnostics,

    nodes: []const node.Node,
    node_ranges: []const node.NodeId,
    analyzer: *analyze.Analyzer,

    types: std.AutoHashMap(node.NodeId, Type),
    declared_types: std.AutoHashMap(node.NodeId, Type),

    generic_cache: GenericCache,
    generic_types: std.AutoHashMap(node.NodeId, std.AutoHashMap(node.NodeId, Type)),
    generic_declared_types: std.AutoHashMap(node.NodeId, std.AutoHashMap(node.NodeId, Type)),

    ty_hint: ?Type = null,
    last_ref: ?node.NodeId = null,
    evaluator: *eval.Evaluator = undefined,
    make_sym_ref: bool = false,
    make_ref: bool = false,
    greedy_symbols: bool = false,
    variant_node: ?node.NodeId = null,
    binding_node: ?node.NodeId = null,
    generic_ctx: ?node.NodeId = null,

    const Self = @This();

    pub fn init(
        nodes: []const node.Node,
        node_ranges: []const node.NodeId,
        analyzer: *analyze.Analyzer,
        diag: *diags.Diagnostics,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
    ) !Self {
        const interner = try allocator.create(TypeInterner);
        interner.* = TypeInterner.init(allocator);
        try interner.setup();

        return .{
            .gpa = allocator,
            .arena = arena,
            .interner = interner,
            .d = diag,
            .nodes = nodes,
            .node_ranges = node_ranges,
            .analyzer = analyzer,
            .types = std.AutoHashMap(node.NodeId, Type).init(allocator),
            .declared_types = std.AutoHashMap(node.NodeId, Type).init(allocator),
            .generic_cache = GenericCache.init(allocator),
            .generic_types = std.AutoHashMap(node.NodeId, std.AutoHashMap(node.NodeId, Type)).init(allocator),
            .generic_declared_types = std.AutoHashMap(node.NodeId, std.AutoHashMap(node.NodeId, Type)).init(allocator),
        };
    }

    pub fn setup(self: *Self, evaluator: *eval.Evaluator) void {
        self.evaluator = evaluator;
        self.generic_cache.setup();
    }

    pub fn typeCheck(self: *Self, nodes: []const node.NodeId) !TypeInfo {
        std.log.info("Start Typeechking", .{});
        for (nodes) |id| {
            _ = try self.typeCheckNode(id);
        }
        std.log.info("Done Typeechking", .{});

        {
            std.debug.print("Declared Types: \n", .{});
            var it = self.declared_types.iterator();
            while (it.next()) |ty| {
                self.printTypeMap(ty.key_ptr.*, ty.value_ptr.*);
                std.debug.print("\n", .{});
            }
        }

        {
            std.debug.print("Node Types: \n", .{});
            var it = self.types.iterator();
            while (it.next()) |ty| {
                self.printTypeMap(ty.key_ptr.*, ty.value_ptr.*);
                std.debug.print("\n", .{});
            }
        }

        {
            std.debug.print("Generic Declared Types: \n", .{});
            var git = self.generic_declared_types.iterator();
            while (git.next()) |gmap| {
                std.debug.print("Instance Node: {}\n", .{gmap.key_ptr.*});
                var it = gmap.value_ptr.iterator();
                while (it.next()) |ty| {
                    std.debug.print("  ", .{});
                    self.printTypeMap(ty.key_ptr.*, ty.value_ptr.*);
                    std.debug.print("\n", .{});
                }
            }
        }

        {
            std.debug.print("Generic Node Types: \n", .{});
            var git = self.generic_types.iterator();
            while (git.next()) |gmap| {
                std.debug.print("Instance Node: {}\n", .{gmap.key_ptr.*});
                var it = gmap.value_ptr.iterator();
                while (it.next()) |ty| {
                    std.debug.print("  ", .{});
                    self.printTypeMap(ty.key_ptr.*, ty.value_ptr.*);
                    std.debug.print("\n", .{});
                }
            }
        }

        return .{
            .types = self.types,
            .declared_types = self.declared_types,
        };
    }

    fn printTypeMap(self: *const Self, node_id: node.NodeId, ty: Type) void {
        std.debug.print("Node: ", .{});
        printIntCol(node_id.index);
        std.debug.print(" => ", .{});
        self.interner.printTy(ty);
    }

    pub fn printIntCol(i: u32) void {
        const alignment: u32 = 4;
        const count = countDigits(i);
        for (0..alignment - count) |_| {
            std.debug.print(" ", .{});
        }

        if (i == 0)
            std.debug.print("\x1b[41m0", .{})
        else
            printIntColImpl(i);

        std.debug.print("\x1b[0m", .{});
    }

    fn countDigits(i: u32) u32 {
        if (i == 0) return 1;
        return countDigitsImpl(i);
    }

    fn countDigitsImpl(i: u32) u32 {
        if (i == 0) return 0;
        return 1 + countDigitsImpl(i / 10);
    }

    fn printIntColImpl(i: u32) void {
        if (i == 0) return;
        const ival = i % 10;
        const bval = if (ival < 7) ival else ival + 60 - 7;
        const fval: u32 = switch (bval + 41) {
            47, 42, 41, 43, 101, 102, 103, 104, 105, 106, 107 => 30,
            else => 37,
        };

        printIntColImpl(i / 10);
        std.debug.print("\x1b[{};{}m{}", .{ fval, bval + 41, ival });
    }

    pub fn typeCheckNode(self: *Self, node_id: node.NodeId) !Type {
        const node_value = self.nodes[node_id.index];
        const ty = switch (node_value.kind) {
            .binding => |value| {
                const old_bind = self.binding_node;
                defer self.binding_node = old_bind;
                self.binding_node = node_id;

                var declared_ty = if (value.ty) |ty|
                    try self.typeCheckNode(ty)
                else
                    null;

                declared_ty = if (declared_ty != null and declared_ty.?.* == .type)
                    declared_ty.?.type
                else
                    declared_ty;

                // declared_ty = if (declared_ty) |dty| switch (dty.*) {
                //     .owned_type => |base| self.interner.namedTy(base.binding),
                //     else => declared_ty,
                // } else declared_ty;

                // else if (declared_ty == null)
                //     null
                // else {
                //     std.log.err("Invalid Type", .{});
                //     return self.interner.unitTy();
                // };

                const old_hint = self.ty_hint;
                defer self.ty_hint = old_hint;
                self.ty_hint = declared_ty;
                const ty = try self.typeCheckNode(value.value);

                if (declared_ty != null) {
                    if (!self.coerceNode(value.value, ty, declared_ty.?) and !canConvert(ty, declared_ty.?)) {
                        const declared_ty_str = self.interner.printTyToStr(declared_ty.?, self.arena);
                        const ty_str = self.interner.printTyToStr(ty, self.arena);

                        self.d.addErr(node_id, "Type of initial value does not match variable type! \nDeclared type:\n  {s}\nInitial value type:\n  {s}\n", .{ declared_ty_str, ty_str }, .{});
                    }
                    try self.putDeclaredType(node_id, declared_ty.?);
                } else {
                    if (ty.* == .type and (ty.type.* == .record or ty.type.* == .@"union" or ty.type.* == .alias)) {
                        const named_ty = self.interner.ownedTypeTy(node_id, ty.type);
                        try self.putDeclaredType(node_id, named_ty);
                    } else {
                        try self.putDeclaredType(node_id, ty);
                    }
                }

                return self.interner.unitTy();
            },

            .identifier => blk: {
                const ref_node = self.analyzer.node_ref.get(node_id) orelse {
                    std.log.err("Node ref didn't exist!", .{});
                    break :blk self.interner.unitTy();
                };
                self.last_ref = ref_node;
                if (self.getType(ref_node)) |ty| break :blk ty;
                if (self.getDeclaredType(ref_node)) |ty| {
                    break :blk if (!self.make_sym_ref) switch (ty.*) {
                        .owned_type => |base| self.interner.namedTy(base.binding),
                        .alias => |_| ty,
                        else => ty,
                    } else ty;
                }

                std.log.info("Note: Identifier reference hasn't been checked yet. Doing this manually (Is this fine?)'", .{});
                _ = try self.typeCheckNode(ref_node);
                self.last_ref = ref_node;

                if (self.getType(ref_node)) |ty| break :blk ty;
                if (self.getDeclaredType(ref_node)) |ty| {
                    break :blk if (!self.make_sym_ref) switch (ty.*) {
                        .owned_type => |base| self.interner.namedTy(base.binding),
                        .alias => |_| ty,
                        else => ty,
                    } else ty;
                }
                std.log.err("Unable to resolve identifier type info!", .{});

                break :blk self.interner.unitTy();
            },
            .int_literal => |_| return self.interner.intLiteralTy(),
            .float_literal => |_| return self.interner.floatLiteralTy(),
            .bool_literal => |_| return self.interner.boolTy(),
            .string_literal => |_| return self.interner.strTy(),
            .binary_expr => |expr| blk: {
                switch (expr.op) {
                    .member_access => {
                        const old_make_sym_ref = self.make_sym_ref;
                        defer self.make_sym_ref = old_make_sym_ref;
                        self.make_sym_ref = true;

                        var orig_ty = try self.typeCheckNode(expr.left);
                        var ref_ns_type = false;
                        const rhs = self.nodes[expr.right.index].kind.identifier;

                        var left_ty = orig_ty.unwrapToRefBase();

                        while (left_ty.* == .named or left_ty.* == .owned_type) {
                            switch (left_ty.*) {
                                .named => left_ty = self.getDeclaredType(left_ty.named).?.owned_type.base,
                                .owned_type => {
                                    orig_ty = self.interner.namedTy(left_ty.owned_type.binding);
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
                                    const variants = &self.interner.multi_types_keyed.items[variant_index];

                                    const this_var = variants.get(rhs).?;
                                    if (this_var.* == .unit) {
                                        break :blk orig_ty;
                                    } else if (self.variant_node) |var_val_node| {
                                        const old_hint = self.ty_hint;
                                        defer self.ty_hint = old_hint;
                                        self.ty_hint = this_var;

                                        const val_ty = try self.typeCheckNode(var_val_node);

                                        if (!self.coerceNode(var_val_node, val_ty, this_var)) {
                                            const declared_ty_str = self.interner.printTyToStr(this_var, self.arena);
                                            const ty_str = self.interner.printTyToStr(val_ty, self.arena);

                                            self.d.addErr(node_id, "Type of union initializer does not match variant type! \nDeclared type:\n  {s}\nInitial value type:\n  {s}\n", .{ declared_ty_str, ty_str }, .{});
                                        }
                                    }

                                    break :blk orig_ty;
                                },
                                else => {
                                    const ty_str = self.interner.printTyToStr(left_ty, self.arena);
                                    self.d.addErr(node_id, "LHS does not support field access! Type: {s}", .{ty_str}, .{});
                                    return self.interner.unitTy();
                                },
                            }
                        } else {
                            switch (left_ty.*) {
                                .record => |rec| {
                                    const fields_index = rec.fields.multi_type_keyed_impl;
                                    const fields = &self.interner.multi_types_keyed.items[fields_index];

                                    break :blk fields.get(rhs).?;
                                },
                                .@"union" => |un| {
                                    const variant_index = un.variants.multi_type_keyed_impl;
                                    const variants = &self.interner.multi_types_keyed.items[variant_index];

                                    const this_var = variants.get(rhs).?;
                                    break :blk this_var;
                                },
                                else => {
                                    const ty_str = self.interner.printTyToStr(left_ty, self.arena);
                                    self.d.addErr(node_id, "LHS does not support field access! Type: {s}", .{ty_str}, .{});
                                    return self.interner.unitTy();
                                },
                            }
                        }
                    },
                    else => {},
                }

                const old_ref = self.make_ref;
                defer self.make_ref = old_ref;

                switch (expr.op) {
                    .assign,
                    .plus_eq,
                    .minus_eq,
                    .times_eq,
                    .divide_eq,
                    .bitor_eq,
                    .bitxor_eq,
                    => {
                        self.make_ref = true;
                    },
                    else => {},
                }

                const left_ty = try self.typeCheckNode(expr.left);

                const old_hint = self.ty_hint;
                defer self.ty_hint = old_hint;

                self.ty_hint = left_ty;

                const right_ty = try self.typeCheckNode(expr.right);

                if (canCoerce(left_ty, right_ty)) {
                    std.debug.assert(self.coerceNode(expr.left, left_ty, right_ty));
                } else if (canCoerce(right_ty, left_ty)) {
                    std.debug.assert(self.coerceNode(expr.right, right_ty, left_ty));
                } else if (left_ty != right_ty) {
                    const lty_str = self.interner.printTyToStr(left_ty, self.arena);
                    const rty_str = self.interner.printTyToStr(right_ty, self.arena);
                    self.d.addErr(node_id, "Binary expression operand types do not match! LHS: {s}, RHS: {s}", .{ lty_str, rty_str }, .{});
                }

                break :blk switch (expr.op) {
                    .assign,
                    .plus_eq,
                    .minus_eq,
                    .times_eq,
                    .divide_eq,
                    .bitor_eq,
                    .bitxor_eq,
                    => self.interner.unitTy(),
                    .equal,
                    .not_equal,
                    .gt,
                    .gte,
                    .lt,
                    .lte,
                    => self.interner.boolTy(),
                    else => left_ty,
                };
            },
            .unary_expr => |expr| blk: {
                const expr_ty = try self.typeCheckNode(expr.expr);
                break :blk expr_ty;
            },
            .argument => |expr| try self.typeCheckNode(expr),
            .key_value_ident => |kv| try self.typeCheckNode(kv.value),
            .key_value => |kv| try self.typeCheckNode(kv.value),
            .func => |func| blk: {
                if (self.generic_ctx == null) {
                    const func_path = self.analyzer.node_to_path.get(self.binding_node.?).?;
                    const func_scope = self.analyzer.getScopeFromPath(func_path).?;

                    if (func_scope.kind.func.generic) {
                        return self.interner.unitTy();
                    }
                }

                var param_tys = std.ArrayList(Type).init(self.arena);
                const nodes = self.nodesRange(func.params);

                for (nodes) |id| {
                    const param_ty = try self.typeCheckNode(id);

                    //                     param_ty = if (param_ty) |dty| switch (dty.*) {
                    //                         .owned_type => |base| self.interner.namedTy(base.binding),
                    //                         else => param_ty,
                    //                     } else param_ty;

                    try param_tys.append(param_ty);
                }

                var ret_ty = if (func.ret_ty) |ret_ty|
                    try self.typeCheckNode(ret_ty)
                else
                    null;

                ret_ty = if (ret_ty != null and ret_ty.?.* == .type)
                    ret_ty.?.type
                else if (ret_ty != null and ret_ty.?.* == .alias)
                    ret_ty.?.alias
                else if (ret_ty == null) null else blk1: {
                    self.d.addErr(func.ret_ty orelse node_id, "Invalid return type! Found null", .{}, .{});
                    break :blk1 self.interner.unitTy();
                };

                if (func.block) |body| {
                    const block_nodes = self.nodesRange(body);
                    if (block_nodes.len > 0) {
                        for (block_nodes[0 .. block_nodes.len - 1]) |id| {
                            _ = try self.typeCheckNode(id);
                        }

                        const last_ty = try self.typeCheckNode(block_nodes[block_nodes.len - 1]);
                        if (last_ty != self.interner.unitTy() and ret_ty != null) {
                            if (!self.coerceNode(block_nodes[block_nodes.len - 1], last_ty, ret_ty.?)) {
                                const exp_str = self.interner.printTyToStr(ret_ty.?, self.arena);
                                const got_str = self.interner.printTyToStr(last_ty, self.arena);

                                self.d.addErr(
                                    block_nodes[block_nodes.len - 1],
                                    "Returned value does not match declared function return type! Expected {s} but found {s}",
                                    .{ exp_str, got_str },
                                    .{},
                                );
                            }
                        }
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

                if (func.block) |body| {
                    const block_nodes = self.nodesRange(body);
                    if (block_nodes.len > 0) {
                        for (block_nodes[0 .. block_nodes.len - 1]) |id| {
                            _ = try self.typeCheckNode(id);
                        }

                        const last_ty = try self.typeCheckNode(block_nodes[block_nodes.len - 1]);
                        if (last_ty != self.interner.unitTy() and ret_ty != null) {
                            if (!self.coerceNode(block_nodes[block_nodes.len - 1], last_ty, ret_ty.?)) {
                                std.log.err("Return value does not match function return type!", .{});
                            }
                        }
                    }
                }

                break :blk self.interner.funcTyNoParams(ret_ty);
            },
            .invoke => |expr| blk: {

                // keep track of typechecked arguments. used for default args
                var unchecked_args = std.bit_set.IntegerBitSet(256).initEmpty();

                const ref_node_id = self.analyzer.node_ref.get(node_id) orelse @panic("uanble to get node ref");
                const bind_func_node = &self.nodes[ref_node_id.index].kind.binding;
                const func_node = &self.nodes[bind_func_node.value.index];
                const func_scope = blk1: {
                    const path = self.analyzer.node_to_path.get(ref_node_id) orelse @panic("unable to get node path");
                    const scope = self.analyzer.getScopeFromPath(path) orelse @panic("unable to get scope form apth");
                    break :blk1 scope;
                };

                const arg_nodes = self.nodesRange(expr.args);

                var call_ty = if (func_scope.kind.func.generic) blk1: {
                    const old_bind = self.binding_node;
                    const old_gen = self.generic_ctx;
                    defer self.binding_node = old_bind;
                    defer self.generic_ctx = old_gen;

                    self.generic_ctx = node_id;
                    self.binding_node = node_id;

                    try self.generic_types.put(node_id, std.AutoHashMap(node.NodeId, Type).init(self.gpa));
                    try self.generic_declared_types.put(node_id, std.AutoHashMap(node.NodeId, Type).init(self.gpa));

                    var generic_items = std.ArrayList(GenericCacheItem).init(self.arena);

                    {
                        // @TODO: check trailing block arg
                        for (arg_nodes) |arg_id| {
                            // For the args passed in, we get the actual parameter index and compare the type
                            // of the arg with the type of the function's paramater at that index.
                            const param_node_id = self.analyzer.node_ref.get(arg_id) orelse @panic("unable to get node ref");
                            const param_node = &self.nodes[param_node_id.index];
                            const param = &param_node.kind.parameter;

                            const param_name = try self.analyzer.getSegment(param.name) orelse @panic("Unable to get param segment");
                            const param_scope = func_scope.children.get(param_name) orelse @panic("Couldn't get parameter in function");

                            if (param_scope.kind.local.generic == null) {
                                continue;
                            }

                            const arg_ty = try self.typeCheckNode(arg_id);
                            const wild_ty = self.matchWildType(param.ty, arg_ty);

                            try generic_items.append(.{ .type = wild_ty });

                            try self.putDeclaredType(param_scope.kind.local.generic.?, self.interner.typeTy(wild_ty));
                        }
                    }

                    // Use previous cached value
                    if (self.generic_cache.getEntry(generic_items.items)) |val| {
                        try self.generic_cache.node_map.put(node_id, val.value_ptr.id);
                        try self.generic_cache.node_to_key_map.put(node_id, val.key_ptr.*);
                        try self.declared_types.put(node_id, val.value_ptr.fn_ty);
                        break :blk1 val.value_ptr.fn_ty;
                    }

                    const fn_ty = try self.typeCheckNode(func_node.id);
                    try self.declared_types.put(node_id, fn_ty);

                    try self.generic_cache.put(node_id, generic_items.items, fn_ty);

                    break :blk1 fn_ty;
                } else null;

                if (call_ty == null) {
                    call_ty = try self.typeCheckNode(expr.expr);
                }

                if (call_ty.?.* != .func) {
                    self.d.addErr(node_id, "Attempted to call a non function type!", .{}, .{});
                    break :blk self.interner.unitTy();
                }

                const expected_types = self.interner.getMultiTypes(call_ty.?.func.params);
                unchecked_args.setRangeValue(.{ .start = 0, .end = expected_types.len }, true);

                const len = @min(expected_types.len, arg_nodes.len);

                {
                    const old_hint = self.ty_hint;
                    defer self.ty_hint = old_hint;
                    // @TODO: check trailing block arg
                    for (arg_nodes[0..len], 0..) |arg_id, i| {
                        // For the args passed in, we get the actual parameter index and compare the type
                        // of the arg with the type of the function's paramater at that index.
                        const param_node_id = self.analyzer.node_ref.get(arg_id) orelse @panic("unable to get node ref");
                        const param_node = &self.nodes[param_node_id.index];
                        const param = &param_node.kind.parameter;

                        const param_name = try self.analyzer.getSegment(param.name) orelse @panic("Unable to get param segment");
                        const param_scope = func_scope.children.get(param_name) orelse @panic("Couldn't get parameter in function");
                        const param_index = param_scope.kind.local.parameter.?;

                        const exp_ty = expected_types[param_index];
                        self.ty_hint = exp_ty;
                        const arg_ty = try self.typeCheckNode(arg_id);

                        unchecked_args.unset(param_index);

                        if (!self.coerceNode(arg_id, arg_ty, exp_ty)) {
                            const arg_ty_str = self.interner.printTyToStr(arg_ty, self.arena);
                            const exp_ty_str = self.interner.printTyToStr(exp_ty, self.arena);

                            self.d.addErr(arg_id, "Function argument does not match parameter type! Expected {s} but found {s} (position {}).", .{ exp_ty_str, arg_ty_str, i }, .{});
                        }
                    }
                }

                if (func_node.kind == .func) {
                    const param_nodes = self.nodesRange(func_node.kind.func.params);
                    for (0..expected_types.len) |i| {
                        // check if remaining args have a default. error if they dont
                        if (unchecked_args.isSet(i)) {
                            const param_node_id = param_nodes[i];
                            const param_node = &self.nodes[param_node_id.index];
                            const param = &param_node.kind.parameter;

                            if (param.default == null) {
                                std.log.err("Missing value for parameter `{s}`", .{param.name}); // @TODO: print the types
                            }
                        }
                    }
                }

                break :blk if (call_ty.?.func.ret_ty) |ty|
                    ty
                else
                    self.interner.unitTy();
            },
            .subscript => |sub| blk: {
                const expr_ty = try self.typeCheckNode(sub.expr);
                const sub_ty = try self.typeCheckNode(sub.sub);
                switch (sub_ty.*) {
                    .int, .uint, .iptr, .uptr, .int_literal => {},
                    else => {
                        std.log.err("Expected integer type for subscript!", .{});
                    },
                }

                // expr_ty = expr_ty.unwrapToRefBase();

                break :blk switch (expr_ty.*) {
                    .array => |arr| arr.base,
                    .reference => |ref| ref.base,
                    .slice => |slice| slice.base,
                    else => {
                        const ty_str = self.interner.printTyToStr(expr_ty, self.arena);
                        self.d.addErr(sub.expr, "Tried to subscript non subsciptable type! Expected array, slice, or indexable reference. Found {s}", .{ty_str}, .{});
                        break :blk self.interner.unitTy();
                    },
                };
            },
            .if_expr => |expr| blk: {
                const cond_ty = try self.typeCheckNode(expr.cond);
                // @TODO: Handle captures
                if (cond_ty != self.interner.boolTy()) {
                    std.log.err("Expected if condition to be a bool!", .{});
                }

                const true_block_ty = blk1: {
                    const nodes = self.nodesRange(expr.true_block);
                    if (nodes.len > 0) {
                        for (nodes[0 .. nodes.len - 1]) |id| {
                            _ = try self.typeCheckNode(id);
                        }

                        break :blk1 try self.typeCheckNode(nodes[nodes.len - 1]);
                    }

                    break :blk1 self.interner.unitTy();
                };

                const false_block_ty = if (expr.false_block) |block| blk1: {
                    const nodes = self.nodesRange(block);

                    if (nodes.len > 0) {
                        for (nodes[0 .. nodes.len - 1]) |id| {
                            _ = try self.typeCheckNode(id);
                        }

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
            .reference => |expr| blk: {
                const old_ty_hint = self.ty_hint;
                defer self.ty_hint = old_ty_hint;

                if (self.ty_hint != null and self.ty_hint.?.* == .reference) {
                    self.ty_hint = self.ty_hint.?.reference.base;
                }

                const base = try self.typeCheckNode(expr.expr);
                const ref_ty = self.getDeclaredType(self.last_ref.?) orelse @panic("Unable to get declared type");

                const mutable = if (ref_ty.* == .reference) ref_ty.reference.mut else blk1: {
                    // Case when taking reference of actual variable
                    const ref_path = self.analyzer.node_to_path.getEntry(self.last_ref.?) orelse @panic("Unable to get ref path");
                    const ref_scope = self.analyzer.getScopeFromPath(ref_path.value_ptr.*) orelse @panic("Uanble to get ref scope");

                    break :blk1 if (ref_scope.kind == .local)
                        ref_scope.kind.local.mutable
                    else
                        false; // References a temp var
                };

                if (self.ty_hint != null and self.ty_hint.?.* == .slice and base.* == .array) {
                    if (self.ty_hint.?.slice.base == base.array.base) {
                        break :blk self.interner.sliceTy(base.array.base, mutable);
                    }
                }

                break :blk self.interner.referenceTy(base, mutable);
            },
            .dereference => |expr| blk: {
                const base = try self.typeCheckNode(expr.expr);
                if (base.* != .reference) {
                    std.log.err("Tried to dereference non pointer type!", .{});
                }

                break :blk base.reference.base;
            },
            .const_expr => |expr| try self.typeCheckNode(expr.expr),
            .const_block => |expr| blk: {
                const nodes = self.nodesRange(expr.block);
                if (nodes.len > 0) {
                    for (nodes[0 .. nodes.len - 1]) |id| {
                        _ = try self.typeCheckNode(id);
                    }
                    break :blk try self.typeCheckNode(nodes[nodes.len - 1]);
                }
                break :blk self.interner.unitTy();
            },
            .variant_init => |vi| blk: {
                const old_var_init = self.variant_node;
                defer self.variant_node = old_var_init;
                self.variant_node = vi.init;

                break :blk try self.typeCheckNode(vi.variant);
            },
            .implicit_variant => |iv| blk: {
                const union_ty = self.getDeclaredType(self.ty_hint.?.named).?.owned_type.base.@"union";

                const variant_index = union_ty.variants.multi_type_keyed_impl;
                const variants = &self.interner.multi_types_keyed.items[variant_index];

                const this_var = variants.get(iv.ident).?;
                if (this_var.* == .unit) {} else if (self.variant_node) |var_val_node| {
                    const old_hint = self.ty_hint;
                    defer self.ty_hint = old_hint;
                    self.ty_hint = this_var;

                    const val_ty = try self.typeCheckNode(var_val_node);

                    if (!self.coerceNode(var_val_node, val_ty, this_var)) {
                        const declared_ty_str = self.interner.printTyToStr(this_var, self.arena);
                        const ty_str = self.interner.printTyToStr(val_ty, self.arena);

                        self.d.addErr(node_id, "Type of union initializer does not match variant type! \nDeclared type:\n  {s}\nInitial value type:\n  {s}\n", .{ declared_ty_str, ty_str }, .{});
                    }
                }

                break :blk self.ty_hint.?;
            },
            .parameter => |param| {
                const ty = try self.typeCheckNode(param.ty);

                const actual_ty = if (ty.* == .type)
                    ty.type
                else if (ty.* == .named)
                    ty
                else if (ty.* == .alias)
                    ty.alias
                else blk1: {
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

                try self.putDeclaredType(node_id, actual_ty);

                return actual_ty;
            },

            .array_init_or_slice_one => |expr| blk: {
                const ref_entry = self.analyzer.node_ref.get(expr.expr);
                if (ref_entry) |field_node_id| {
                    const ref_node_id = self.analyzer.node_ref.get(node_id) orelse @panic("uanble to get node ref");
                    const bind_record_node = &self.nodes[ref_node_id.index].kind.binding;
                    const record_node = &self.nodes[bind_record_node.value.index];
                    const record_scope = blk1: {
                        const path = self.analyzer.node_to_path.get(ref_node_id) orelse @panic("unable to get node path");
                        const scope = self.analyzer.getScopeFromPath(path) orelse @panic("unable to get scope form apth");
                        break :blk1 scope;
                    };

                    const record_node_id = self.ty_hint.?.named;
                    const record_ty = self.getDeclaredType(record_node_id).?.owned_type.base.record;

                    const fields_index = record_ty.fields.multi_type_keyed_impl;
                    const fields = &self.interner.multi_types_keyed.items[fields_index];

                    var unchecked_fields = std.bit_set.IntegerBitSet(256).initEmpty();
                    unchecked_fields.setRangeValue(.{ .start = 0, .end = fields.count() }, true);

                    const field_node = self.nodes[field_node_id.index].kind.record_field;
                    const field_name = try self.analyzer.getSegment(field_node.name) orelse @panic("Unable to get field name");
                    const field_scope = record_scope.children.get(field_name) orelse @panic("Unable to get field in funciton scope");
                    const field_index = field_scope.kind.field.index;

                    const exp_ty = fields.values()[field_index];
                    const value_ty = try self.typeCheckNode(expr.value.?);

                    unchecked_fields.unset(field_index);
                    if (!self.coerceNode(expr.value.?, value_ty, exp_ty)) {
                        const arg_ty_str = self.interner.printTyToStr(value_ty, self.arena);
                        const exp_ty_str = self.interner.printTyToStr(exp_ty, self.arena);

                        self.d.addErr(expr.value.?, "Field initializer does not match field type! Expected {s} but found {s} (position {}).", .{ exp_ty_str, arg_ty_str, 0 }, .{});
                    }

                    if (record_node.kind == .type_record) {
                        const field_nodes = self.nodesRange(record_node.kind.type_record.fields);

                        for (0..fields.count()) |i| {
                            if (unchecked_fields.isSet(i)) {
                                const decl_field_node_id = field_nodes[i];
                                const decl_field = self.nodes[decl_field_node_id.index].kind.record_field;

                                if (decl_field.default == null) {
                                    std.log.err("Missing value for field `{s}`", .{decl_field.name}); // @TODO: print the types
                                }
                            }
                        }
                    }

                    break :blk self.ty_hint.?;
                } else {
                    const expr_ty = try self.typeCheckNode(expr.expr);
                    const value_expr = if (expr.value) |val| blk1: {
                        _ = try self.typeCheckNode(val);

                        const value = try self.evalConstValue(val);

                        break :blk1 value.kind.int;
                    } else null;

                    if (expr_ty.* == .type) {
                        const ty = if (value_expr) |size|
                            self.interner.arrayTy(expr_ty.*.type, @intCast(size))
                        else
                            self.interner.sliceTy(expr_ty.*.type, expr.mut);

                        break :blk self.interner.typeTy(ty);
                    } else {
                        break :blk self.interner.arrayTy(expr_ty, 1);
                    }
                }
            },

            .array_init => |expr| blk: {
                const nodes = self.nodesRange(expr.exprs);
                if (nodes.len < 2) @panic("whoops");

                // @TODO: do something smarter than just picking first element

                var first_ty = try self.typeCheckNode(nodes[0]);
                const base_ty = if (self.ty_hint != null) switch (self.ty_hint.?.*) {
                    .slice => |b| b.base,
                    .array => |b| b.base,
                    else => null,
                } else null;

                first_ty = if (base_ty) |ty| blk1: {
                    if (!self.coerceNode(nodes[0], first_ty, ty)) {
                        const first_ty_str = self.interner.printTyToStr(first_ty, self.arena);
                        const ty_str = self.interner.printTyToStr(ty, self.arena);

                        self.d.addErr(nodes[0], "Array initializer values type mismatch. Expected {s} but received {s} (position {})", .{ ty_str, first_ty_str, 0 }, .{});
                        std.log.err("Array initializer values type mismatch (position {})", .{0});
                    }

                    break :blk1 ty;
                } else first_ty;

                for (nodes[1..], 0..) |id, i| {
                    const this_ty = try self.typeCheckNode(id);
                    if (!self.coerceNode(id, this_ty, first_ty)) {
                        const this_ty_str = self.interner.printTyToStr(this_ty, self.arena);
                        const first_ty_str = self.interner.printTyToStr(first_ty, self.arena);

                        self.d.addErr(nodes[0], "Array initializer values type mismatch. Expected {s} but received {s} (position {})", .{ first_ty_str, this_ty_str, i }, .{});
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
                var fields = std.StringArrayHashMap(Type).init(self.arena);

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

                break :blk self.interner.typeTy(self.interner.recordTy(backing_field_ty, fields));
            },
            .type_union => |uni| blk: {
                const backing_field_ty = if (uni.backing_field) |f| blk1: {
                    const ty = try self.typeCheckNode(f);
                    break :blk1 ty.unwrapType();
                } else null;
                var variants = std.StringArrayHashMap(Type).init(self.arena);
                var indicies = std.ArrayList(Type).init(self.arena);
                var variant_index: u64 = 0;

                const variant_nodes = self.nodesRange(uni.variants);
                for (variant_nodes) |id| {
                    const variant_node = self.nodes[id.index];
                    switch (variant_node.kind) {
                        .union_variant => |var_val| {
                            const name_node = self.nodes[var_val.name.index];
                            const var_ty = if (var_val.ty == null)
                                self.interner.unitTy()
                            else blk1: {
                                const actual_ty = try self.typeCheckNode(var_val.ty.?);

                                break :blk1 if (actual_ty.* == .type or actual_ty.* == .named) actual_ty.type else {
                                    std.log.err("Invalid Type", .{});
                                    std.debug.dumpCurrentStackTrace(null);
                                    break :blk1 self.interner.unitTy();
                                };
                            };

                            // @TODO: implement type names
                            const name = if (name_node.kind == .identifier)
                                name_node.kind.identifier
                            else
                                @panic("Unimplemented");

                            try variants.put(name, var_ty);

                            if (var_val.index) |ind| {
                                const value = try self.evalConstValue(ind);
                                try indicies.append(self.interner.createOrGetTy(.{ .simple_int_value = @intCast(value.kind.int) }));
                                variant_index = @as(u64, @intCast(value.kind.int)) + 1;
                            } else {
                                try indicies.append(self.interner.createOrGetTy(.{ .simple_int_value = variant_index }));
                                variant_index += 1;
                            }
                        },
                        else => {
                            _ = try self.typeCheckNode(id);
                        },
                    }
                }

                break :blk self.interner.typeTy(self.interner.unionTy(backing_field_ty, variants, indicies.items));
            },
            .type_ref => |ty| blk: {
                const base_ty = try self.typeCheckNode(ty.ty);
                if (base_ty.* == .named) {
                    break :blk self.interner.typeTy(self.interner.referenceTy(base_ty, ty.mut));
                } else if (base_ty.* == .alias) {
                    break :blk self.interner.typeTy(self.interner.referenceTy(base_ty.alias, ty.mut));
                }
                break :blk self.interner.typeTy(self.interner.referenceTy(base_ty.unwrapType(), ty.mut));
            },
            .type_opt => |ty| blk: {
                const base_ty = try self.typeCheckNode(ty.ty);
                if (base_ty.* == .named) {
                    break :blk self.interner.typeTy(self.interner.optionalTy(base_ty));
                } else if (base_ty.* == .alias) {
                    break :blk self.interner.typeTy(self.interner.optionalTy(base_ty.alias));
                }

                break :blk self.interner.typeTy(self.interner.optionalTy(base_ty.unwrapType()));
            },
            .type_alias => |id| blk: {
                const original_ty = try self.typeCheckNode(id);
                if (original_ty.* == .named) {
                    break :blk self.interner.typeTy(self.interner.aliasTy(original_ty));
                } else if (original_ty.* == .alias) {
                    break :blk self.interner.typeTy(self.interner.aliasTy(original_ty.alias));
                }

                break :blk self.interner.typeTy(self.interner.aliasTy(original_ty.unwrapType()));
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
            .type_bool => self.interner.typeTy(self.interner.boolTy()),
            .type_float => |size| self.interner.typeTy(self.interner.floatTy(size)),
            .type_wild => |_| return self.getDeclaredType(node_id).?,

            else => blk: {
                std.log.err("Unhandled case (typecheck): {}", .{node_value});
                break :blk self.interner.unitTy();
            },
        };

        try self.putType(node_id, ty);

        return ty;
    }

    fn matchWildType(self: *Self, varying_type: node.NodeId, match_ty: Type) Type {
        const node_value = &self.nodes[varying_type.index];

        return switch (node_value.kind) {
            .type_wild => match_ty,
            .type_ref => |tref| if (match_ty.* == .reference)
                self.matchWildType(tref.ty, match_ty.reference.base)
            else
                match_ty,
            .type_opt => |tref| if (match_ty.* == .optional)
                self.matchWildType(tref.ty, match_ty.optional.base)
            else
                match_ty,
            else => @panic("Unimlemented"),
        };
    }

    fn evalConstValue(self: *Self, val: node.NodeId) !eval.Value {
        const save_point = self.evaluator.save();
        const old_ec = self.evaluator.eval_const;
        self.evaluator.eval_const = true;
        const value_id = try self.evaluator.evalNode(val);
        self.evaluator.eval_const = old_ec;

        const value = if (value_id) |id| self.evaluator.instructions.items[id.index] else null;
        if (value_id == null or value.?.kind != .constant or value.?.value.?.kind != .int) {
            std.log.err("Expected constant int for array type size!", .{});
        }
        self.evaluator.reset(save_point);

        return value.?.value.?;
    }

    pub fn unwrapNamedTy(self: *const Self, ty: Type) Type {
        var base = ty;

        while (base.* == .named) {
            base = self.getDeclaredType(base.named).?.owned_type.base;
        }

        return base;
    }

    pub fn coerceNode(self: *Self, node_id: node.NodeId, from: Type, to: Type) bool {
        if (from == to) return true;
        if (canCoerce(from, to)) {
            self.getOrPutType(node_id, to) catch @panic("Unable to getOrPut");
            return true;
        }

        return false;
    }

    pub fn canConvert(from: Type, to: Type) bool {
        if (from == to) return true;
        return switch (from.*) {
            .reference => |fref| switch (to.*) {
                .slice => |tslice| switch (fref.base.*) {
                    .array => |farr| !(!fref.mut and tslice.mut) and canCoerce(farr.base, tslice.base),
                    else => false,
                },
                else => false,
            },
            else => false,
        };
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
            .array => |farr| switch (to.*) {
                .array => |tarr| farr.size == tarr.size and canCoerce(farr.base, tarr.base),
                // .slice => |tslice| canCoerce(farr.base, tslice.base),
                else => false,
            },
            .reference => |fref| switch (to.*) {
                // .slice => |tslice| switch (fref.base.*) {
                //     .array => |farr| !(!fref.mut and tslice.mut) and canCoerce(farr.base, tslice.base),
                //     else => false,
                // },
                .reference => |tref| !(!fref.mut and tref.mut) and canCoerce(fref.base, tref.base),
                else => false,
            },
            else => false,
        };
    }

    fn putType(self: *Self, node_id: node.NodeId, ty: Type) !void {
        if (self.generic_ctx) |gtx| {
            const entry = try self.generic_types.getOrPut(gtx);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.AutoHashMap(node.NodeId, Type).init(self.gpa);
            }

            try entry.value_ptr.put(node_id, ty);
        } else {
            try self.types.put(node_id, ty);
        }
    }

    fn getOrPutType(self: *Self, node_id: node.NodeId, ty: Type) !void {
        if (self.generic_ctx) |gtx| {
            const gentry = try self.generic_types.getOrPut(gtx);
            if (!gentry.found_existing) {
                gentry.value_ptr.* = std.AutoHashMap(node.NodeId, Type).init(self.gpa);
            }

            const entry = try gentry.value_ptr.getOrPut(node_id);
            entry.value_ptr.* = ty;
        } else {
            const entry = try self.types.getOrPut(node_id);
            entry.value_ptr.* = ty;
        }
    }

    fn putDeclaredType(self: *Self, node_id: node.NodeId, ty: Type) !void {
        if (self.generic_ctx) |gtx| {
            const entry = try self.generic_declared_types.getOrPut(gtx);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.AutoHashMap(node.NodeId, Type).init(self.gpa);
            }

            try entry.value_ptr.put(node_id, ty);
        } else {
            try self.declared_types.put(node_id, ty);
        }
    }

    fn getType(self: *const Self, node_id: node.NodeId) ?Type {
        if (self.generic_ctx) |gtx| {
            const entry = self.generic_types.getEntry(gtx) orelse return null;
            return entry.value_ptr.get(node_id);
        } else {
            return self.types.get(node_id);
        }
    }

    fn getDeclaredType(self: *const Self, node_id: node.NodeId) ?Type {
        if (self.generic_ctx) |gtx| {
            const entry = self.generic_declared_types.getEntry(gtx) orelse return null;
            return entry.value_ptr.get(node_id);
        } else {
            return self.declared_types.get(node_id);
        }
    }

    inline fn nodesRange(self: *const Self, range: node.NodeRange) []const node.NodeId {
        return self.node_ranges[range.start .. range.start + range.len];
    }
};
