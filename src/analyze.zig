const std = @import("std");
const node = @import("node.zig");
const typecheck = @import("typecheck.zig");

const AnalyzeError = error{
    ChildExists,
};

const ScopeChildMap = std.HashMap(
    PathSegment,
    Scope,
    PathSegmentContext,
    std.hash_map.default_max_load_percentage,
);

pub const Scope = struct {
    children: ScopeChildMap,
    path: Path,
    parent: ?*Scope,
    kind: ScopeKind,
    tags: node.SymbolTag.Tag = node.SymbolTag.Tag.initEmpty(),

    const Self = @This();

    pub fn init(parent: *Scope, path: Path, allocator: std.mem.Allocator) Self {
        return .{
            .children = ScopeChildMap.init(allocator),
            .path = path,
            .parent = parent,
            .kind = .root,
        };
    }

    pub fn setGeneric(self: *Scope, generic: bool) void {
        switch (self.kind) {
            .func => |*f| f.generic = generic,
            .type => |*f| f.generic = generic,
            else => {},
        }
    }

    pub fn createChild(self: *Scope, path: Path, name: PathSegment, kind: ScopeKind) !*Self {
        const child = try self.children.getOrPut(name);

        if (child.found_existing) {
            return error.ChildExists;
        }

        child.value_ptr.* = .{
            .children = ScopeChildMap.init(self.children.allocator),
            .path = path,
            .parent = self,
            .kind = kind,
        };

        return child.value_ptr;
    }

    pub fn resolveUpChain(self: *Self, seg: PathSegment) ?*Scope {
        if (self.children.getEntry(seg)) |scp| {
            return scp.value_ptr;
        }

        if (self.parent) |prt| {
            return prt.resolveUpChain(seg);
        }

        return null;
    }

    pub fn incReference(self: *Self) void {
        switch (self.kind) {
            .local => |*val| val.references += 1,
            .func => |*val| val.references += 1,
            .type => |*val| val.references += 1,
            .field => |*val| val.references += 1,
            .root, .anonymous => {},
        }
    }

    pub fn print(self: *const Scope) void {
        self.printImpl(0);
    }

    fn printImpl(self: *const Scope, indent: usize) void {
        self.path.print();
        var it = self.children.iterator();
        while (it.next()) |child| {
            for (0..indent + 1) |_| {
                std.debug.print("    ", .{});
            }
            child.value_ptr.printImpl(indent + 1);
        }
    }
};

pub const ScopeKind = union(enum) {
    root: void,
    anonymous: void,
    func: struct {
        references: u32,
        generic: bool,
    },
    type: struct {
        references: u32,
        generic: bool,
    },
    field: struct {
        index: u32,
        references: u32,
        generic: ?node.NodeId = null,
    },
    local: struct {
        references: u32,
        mutable: bool,
        parameter: ?u32,
        generic: ?node.NodeId = null,
    },
};

pub const PathSegment = []const u8;

pub const PathSegmentContext = struct {
    pub fn hash(ctx: @This(), key: PathSegment) u64 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Shallow);
        return hasher.final();
    }

    pub const eql = std.hash_map.getAutoEqlFn(PathSegment, @This());
};

pub const Path = struct {
    segments: []const PathSegment,

    pub fn print(self: *const Path) void {
        self.printNoNL();
        std.debug.print("\n", .{});
    }

    pub fn printNoNL(self: *const Path) void {
        if (self.segments.len > 0) {
            std.debug.print("{s}", .{self.segments[0]});
        }
        for (self.segments[1..]) |seg| {
            std.debug.print(".{s}", .{seg});
        }
    }
};

pub const PathContext = struct {
    pub fn hash(ctx: @This(), key: Path) u64 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key.segments, .Deep);
        return hasher.final();
    }

    pub fn eql(ctx: @This(), a: Path, b: Path) bool {
        _ = ctx;
        if (a.segments.len != b.segments.len) return false;

        for (a.segments, b.segments) |aval, bval| {
            if (!std.meta.eql(aval, bval)) return false;
        }

        return true;
    }
};

const PathToNodeMap = std.HashMap(
    Path,
    node.NodeId,
    PathContext,
    std.hash_map.default_max_load_percentage,
);

pub const NodeRefMap = std.AutoHashMap(node.NodeId, node.NodeId);
const SegmentSet = std.StringHashMap(void);

const DeferredNode = struct {
    path: Path,
    node: node.NodeId,
    param_index: ?u32 = null,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    scope_arena: std.mem.Allocator,
    root_scope: Scope,
    current_scope: *Scope,
    segment_set: std.StringHashMap(void),

    current_path: std.ArrayList(PathSegment),

    deferred_nodes: std.ArrayList(DeferredNode),

    path_to_node: PathToNodeMap,
    node_to_path: std.AutoHashMap(node.NodeId, Path),
    node_ref: NodeRefMap,

    node_ranges: []const node.NodeId,
    nodes: []const node.Node,
    deferred: bool = false,

    param_doing_default: bool = false,
    param_index: ?u32 = 0,
    last_ref: ?node.NodeId = null,
    last_deferred: bool = false,
    last_generic: ?node.NodeId = null,

    const Self = @This();

    pub fn init(prgm_nodes: []const node.Node, node_ranges: []const node.NodeId, allocator: std.mem.Allocator) Self {
        var scope_arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = scope_arena.allocator();

        return .{
            .allocator = allocator,
            .scope_arena = arena_alloc,
            .root_scope = .{
                .children = ScopeChildMap.init(allocator),
                .path = undefined,
                .parent = null,
                .kind = .root,
            },
            .current_scope = undefined,
            .deferred_nodes = std.ArrayList(DeferredNode).init(allocator),
            .segment_set = std.StringHashMap(void).init(allocator),
            .path_to_node = PathToNodeMap.init(allocator),
            .node_to_path = std.AutoHashMap(node.NodeId, Path).init(allocator),
            .current_path = std.ArrayList(PathSegment).init(allocator),
            .node_ref = NodeRefMap.init(allocator),
            .node_ranges = node_ranges,
            .nodes = prgm_nodes,
        };
    }

    pub fn analyze(self: *Self, indicies: []const node.NodeId) !void {
        self.current_scope = &self.root_scope;
        try self.current_path.append(try self.segment("root"));
        self.root_scope.path = try self.pathFromCurrent();

        for (indicies) |index| {
            try self.analyzeNode(index);
        }

        self.deferred = true;
        for (self.deferred_nodes.items) |deferred_node| {
            self.setScopeFromPath(deferred_node.path);
            const old_ind = self.param_index;
            defer self.param_index = old_ind;
            if (deferred_node.param_index) |ind| {
                self.param_index = ind;
            }

            try self.analyzeNode(deferred_node.node);
        }
        self.current_scope = &self.root_scope;

        self.current_scope.print();
        {
            var it = self.path_to_node.iterator();
            while (it.next()) |ptn| {
                ptn.key_ptr.printNoNL();
                std.debug.print(" => {}\n", .{ptn.value_ptr.*});
            }
        }

        {
            var it = self.node_ref.iterator();
            while (it.next()) |ptn| {
                std.log.info("{} => {}", .{ ptn.key_ptr.*, ptn.value_ptr.* });
            }
        }
    }

    pub fn analyzeNode(self: *Self, index: node.NodeId) !void {
        const node_value = self.nodes[index.index];

        switch (node_value.kind) {
            .type_int, .type_uint, .type_float, .type_bool => {},
            .binding => |value| {
                const init_node = self.nodes[value.value.index];
                defer self.last_generic = null;

                switch (init_node.kind) {
                    .func, .func_no_params => {
                        const this_scope = try self.pushScope(try self.segment(value.name), .{
                            .func = .{
                                .references = 0,
                                .generic = self.last_generic != null,
                            },
                        });
                        this_scope.tags = value.tags;
                        try self.path_to_node.put(this_scope.path, index);
                        try self.node_to_path.put(index, this_scope.path);
                    },
                    .type_record,
                    .type_union,
                    => {
                        const this_scope = try self.pushScope(try self.segment(value.name), .{
                            .type = .{
                                .references = 0,
                                .generic = self.last_generic != null,
                            },
                        });
                        this_scope.tags = value.tags;
                        try self.path_to_node.put(this_scope.path, index);
                        try self.node_to_path.put(index, this_scope.path);
                    },
                    else => {
                        const this_scope = try self.pushScope(try self.segment(value.name), .{
                            .local = .{
                                .references = 0,
                                .mutable = value.mutable,
                                .parameter = null,
                            },
                        });
                        this_scope.tags = value.tags;
                        try self.path_to_node.put(this_scope.path, index);
                        try self.node_to_path.put(index, this_scope.path);
                        self.popScope();
                    },
                }

                if (value.ty) |ty| {
                    try self.analyzeNode(ty);
                }
                try self.analyzeNode(value.value);

                switch (init_node.kind) {
                    .func,
                    .func_no_params,
                    .type_record,
                    .type_union,
                    => {
                        self.current_scope.setGeneric(self.last_generic != null);
                        self.popScope();
                    },
                    else => {},
                }
            },
            .identifier => |str| {
                if (self.lookupIdent(try self.segment(str))) |scope| {
                    scope.incReference();
                    if (self.path_to_node.get(scope.path)) |found_id| {
                        try self.node_ref.put(index, found_id);
                        self.last_ref = found_id;
                        return;
                    }
                }

                if (self.deferred) {
                    std.log.err("Unable to resolve symbol: `{s}`", .{str});
                } else {
                    self.last_deferred = true;
                    // @TODO: dont do this for locals
                    try self.deferred_nodes.append(.{
                        .path = try self.pathFromCurrent(),
                        .node = index,
                    });
                }
            },
            .parameter => |value| {
                try self.analyzeNode(value.ty);
                const generic = self.last_generic;

                if (value.spread) {
                    @panic("Unimplemented");
                }

                const this_scope = try self.pushScope(try self.segment(value.name), .{
                    .local = .{
                        .references = 0,
                        .parameter = self.param_index,
                        .mutable = false,
                        .generic = generic,
                    },
                });
                try self.path_to_node.put(this_scope.path, index);
                try self.node_to_path.put(index, this_scope.path);
                self.popScope();

                if (value.default) |def| {
                    self.param_doing_default = true;
                    try self.analyzeNode(def);
                } else if (self.param_doing_default) {
                    std.log.err("Default arguments should be after all positional arguments!", .{});
                }

                self.last_generic = generic;
            },
            .func => |fval| {
                const param_nodes = self.nodesRange(fval.params);
                self.param_doing_default = false;
                var generic = false;

                for (param_nodes, 0..) |param, i| {
                    self.param_index = @truncate(i);
                    try self.analyzeNode(param);
                    generic = generic or self.last_generic != null;
                }

                self.param_index = null;

                if (fval.ret_ty) |ret| {
                    try self.analyzeNode(ret);
                }

                if (fval.block) |body| {
                    const block_nodes = self.nodesRange(body);
                    for (block_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }

                self.last_generic = if (generic) index else null;
            },
            .func_no_params => |fval| {
                if (fval.ret_ty) |ret| {
                    try self.analyzeNode(ret);
                }

                if (fval.block) |body| {
                    const block_nodes = self.nodesRange(body);
                    for (block_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }

                self.last_generic = null;
            },
            .key_value => |expr| {
                // @TODO: imlement key
                try self.analyzeNode(expr.key);
                try self.analyzeNode(expr.value);
            },
            .key_value_ident => |expr| {
                // @TODO: imlement key
                try self.analyzeNode(expr.value);
            },
            .argument => |expr| try self.analyzeNode(expr),
            .int_literal => |_| {},
            .float_literal => |_| {},
            .bool_literal => |_| {},
            .string_literal => |_| {},
            .binary_expr => |expr| {
                try self.analyzeNode(expr.left);
                switch (expr.op) {
                    .member_access => {},
                    else => {
                        try self.analyzeNode(expr.right);
                    },
                }
            },
            .unary_expr => |expr| {
                try self.analyzeNode(expr.expr);
            },
            .invoke => |expr| blk: {
                try self.analyzeNode(expr.expr);
                if (self.last_deferred) {
                    // If the function is deferred, we also must defer this function since we don't know the parameters at this point
                    try self.deferred_nodes.append(.{
                        .path = try self.pathFromCurrent(),
                        .node = index,
                    });
                    self.last_deferred = false;
                    break :blk;
                }

                var doing_named: bool = false;

                const func_scope = if (self.last_ref) |ref| blk1: {
                    const path = self.node_to_path.get(ref) orelse break :blk1 null;
                    const scope = self.getScopeFromPath(path) orelse break :blk1 null;
                    try self.node_ref.put(index, ref);
                    break :blk1 scope;
                } else {
                    try self.deferred_nodes.append(.{
                        .path = try self.pathFromCurrent(),
                        .node = index,
                    });
                    break :blk;
                };

                // keep track of typechecked arguments. used for default args
                var checked_args = std.bit_set.IntegerBitSet(256).initEmpty();
                const arg_nodes = self.nodesRange(expr.args);

                if (func_scope == null) {
                    std.log.err("Unable to get function scope!", .{});
                }

                for (arg_nodes, 0..) |item, i| {
                    const arg_value = self.nodes[item.index];
                    switch (arg_value.kind) {
                        // @TODO: handle .key_value
                        .key_value_ident => |kv| {
                            doing_named = true;

                            blk1: {
                                const key = try self.segment(kv.key);
                                if (func_scope == null) {
                                    @panic("hmm expected fn");
                                } else if (func_scope.?.children.get(key)) |param| {
                                    if (param.kind == .local and param.kind.local.parameter != null) {
                                        const param_node_id = self.path_to_node.get(param.path);
                                        if (param_node_id) |id| {
                                            const ref_entry = try self.node_ref.getOrPut(item);
                                            if (checked_args.isSet(param.kind.local.parameter.?) or ref_entry.found_existing) {
                                                std.log.err("Parameter `{s}` already has been passed a value", .{key});
                                            }

                                            checked_args.set(param.kind.local.parameter.?);

                                            // Reference argument node to parameter node
                                            ref_entry.value_ptr.* = id;
                                            break :blk1;
                                        }
                                    }
                                }
                                std.log.err("Named argument doesn't exist for function", .{});
                            }

                            try self.analyzeNode(kv.value);
                        },
                        else => {
                            if (doing_named) {
                                std.log.err("All positional arguments must be before any named arguments!", .{});
                            }
                            if (func_scope) |scp| {
                                var it = scp.children.iterator();
                                while (it.next()) |lcl| {
                                    if (lcl.value_ptr.kind == .local and lcl.value_ptr.kind.local.parameter != null and lcl.value_ptr.kind.local.parameter.? == i) {
                                        const param_node_id = self.path_to_node.get(lcl.value_ptr.path);

                                        if (param_node_id) |id| {
                                            const ref_entry = try self.node_ref.getOrPut(item);
                                            if (checked_args.isSet(lcl.value_ptr.kind.local.parameter.?) or ref_entry.found_existing) {
                                                std.log.err("Parameter `{s}` already has been passed a value", .{lcl.key_ptr.*});
                                            }

                                            checked_args.set(lcl.value_ptr.kind.local.parameter.?);

                                            // Reference argument node to parameter node
                                            ref_entry.value_ptr.* = id;
                                        } else {
                                            std.log.err("Unable to get parameter node id", .{});
                                        }
                                        break;
                                    }
                                }
                                try self.analyzeNode(item);
                            }
                        },
                    }
                }

                if (expr.trailing_block) |block| {
                    const item_nodes = self.nodesRange(block);
                    for (item_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }
            },
            .subscript => |sub| {
                try self.analyzeNode(sub.expr);
                try self.analyzeNode(sub.sub);
            },
            .if_expr => |expr| {
                try self.analyzeNode(expr.cond);
                // @TODO: Implement captures
                {
                    const item_nodes = self.nodesRange(expr.true_block);
                    for (item_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }

                if (expr.false_block) |block| {
                    const item_nodes = self.nodesRange(block);
                    for (item_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }
            },
            .loop => |expr| {
                if (expr.expr) |exp| {
                    try self.analyzeNode(exp);
                }

                // @TODO: Implement captures
                {
                    const item_nodes = self.nodesRange(expr.loop_block);
                    for (item_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }

                if (expr.else_block) |block| {
                    const item_nodes = self.nodesRange(block);
                    for (item_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }

                if (expr.finally_block) |block| {
                    const item_nodes = self.nodesRange(block);
                    for (item_nodes) |item| {
                        try self.analyzeNode(item);
                    }
                }
            },
            .reference => |expr| try self.analyzeNode(expr.expr),
            .dereference => |expr| try self.analyzeNode(expr.expr),
            .const_expr => |expr| {
                try self.analyzeNode(expr.expr);
            },
            .const_block => |expr| {
                const item_nodes = self.nodesRange(expr.block);
                for (item_nodes) |item| {
                    try self.analyzeNode(item);
                }
            },
            .variant_init => |varin| {
                try self.analyzeNode(varin.variant);
                try self.analyzeNode(varin.init);
            },
            .implicit_variant => |_| {},
            .array_init_or_slice_one => |val| {
                const record_scope = if (self.last_ref) |ref| blk1: {
                    const path = self.node_to_path.get(ref) orelse break :blk1 null;
                    const scope = self.getScopeFromPath(path) orelse break :blk1 null;
                    try self.node_ref.put(index, ref);
                    break :blk1 scope;
                } else null;

                const expr_node = self.nodes[val.expr.index];
                if (val.mut or record_scope == null or expr_node.kind != .identifier or record_scope.?.children.getEntry(try self.segment(expr_node.kind.identifier)) == null) {
                    try self.analyzeNode(val.expr);
                    if (val.value) |expr| {
                        try self.analyzeNode(expr);
                    }
                    return;
                }

                const key = try self.segment(expr_node.kind.identifier);

                if (record_scope.?.children.getEntry(key)) |field| {
                    if (field.value_ptr.kind == .field) {
                        const field_node_id = self.path_to_node.get(field.value_ptr.path);
                        if (field_node_id) |id| {
                            const ref_entry = try self.node_ref.getOrPut(val.expr);
                            ref_entry.value_ptr.* = id;
                            field.value_ptr.kind.field.references += 1;
                        }
                    }
                }

                try self.analyzeNode(val.value.?);
            },
            .array_init => |val| {
                const exprs = self.nodesRange(val.exprs);
                if (exprs.len == 0) return;
                if (self.nodes[exprs[0].index].kind != .key_value or self.nodes[exprs[0].index].kind != .key_value_ident) {
                    for (exprs) |expr| {
                        try self.analyzeNode(expr);
                    }
                    return;
                }

                const record_scope = if (self.last_ref) |ref| blk1: {
                    const path = self.node_to_path.get(ref) orelse break :blk1 null;
                    const scope = self.getScopeFromPath(path) orelse break :blk1 null;
                    try self.node_ref.put(index, ref);
                    break :blk1 scope;
                } else null;

                var checked_args = std.bit_set.IntegerBitSet(512).initEmpty();
                for (exprs) |item| {
                    const arg_value = self.nodes[item.index].kind.key_value_ident;

                    const key = try self.segment(arg_value.key);

                    if (record_scope.?.children.getEntry(key)) |field| {
                        if (field.value_ptr.kind == .field) {
                            const field_node_id = self.path_to_node.get(field.value_ptr.path);
                            if (field_node_id) |id| {
                                const ref_entry = try self.node_ref.getOrPut(item);
                                if (checked_args.isSet(field.value_ptr.kind.field.index) or ref_entry.found_existing) {
                                    std.log.err("Field `{s}`has already been passed a value", .{key});
                                }

                                checked_args.set(field.value_ptr.kind.field.index);

                                ref_entry.value_ptr.* = id;
                                field.value_ptr.kind.field.references += 1;
                            }
                        }
                    }
                }
            },

            .type_record => |record| {
                if (record.backing_field) |field| {
                    try self.analyzeNode(field);
                }

                const old_param_index = self.param_index;
                defer self.param_index = old_param_index;

                const field_nodes = self.nodesRange(record.fields);
                var generic = false;
                for (field_nodes, 0..) |field, i| {
                    self.param_index = @truncate(i);
                    try self.analyzeNode(field);
                    generic = generic or self.last_generic != null;
                }

                self.last_generic = if (generic) index else null;
            },
            .record_field => |field| {
                try self.analyzeNode(field.ty);
                const generic = self.last_generic;
                {
                    const this_scope = try self.pushScope(try self.segment(field.name), .{
                        .field = .{
                            .index = self.param_index.?,
                            .references = 0,
                            .generic = generic,
                        },
                    });

                    try self.path_to_node.put(this_scope.path, index);
                    try self.node_to_path.put(index, this_scope.path);

                    self.popScope();
                }

                if (field.default) |def| {
                    try self.analyzeNode(def);
                }

                self.last_generic = generic;
            },
            .type_union => |uni| {
                if (uni.backing_field) |field| {
                    try self.analyzeNode(field);
                }

                const old_param_index = self.param_index;
                defer self.param_index = old_param_index;

                const variant_nodes = self.nodesRange(uni.variants);
                var generic = false;

                for (variant_nodes, 0..) |variant, i| {
                    self.param_index = @truncate(i);
                    try self.analyzeNode(variant);
                    generic = generic or self.last_generic != null;
                }

                self.last_generic = if (generic) index else null;
            },
            .union_variant => |vari| {
                if (!self.deferred) {
                    try self.deferred_nodes.append(.{
                        .path = try self.pathFromCurrent(),
                        .node = index,
                        .param_index = self.param_index,
                    });
                    return;
                }

                if (vari.ty) |ty| {
                    try self.analyzeNode(ty);
                }

                const generic = self.last_generic;

                {
                    const vnode = self.nodes[vari.name.index];
                    switch (vnode.kind) {
                        .identifier => |name| {
                            _ = try self.pushScope(try self.segment(name), .{
                                .field = .{
                                    .index = self.param_index.?,
                                    .references = 0,
                                    .generic = if (vari.ty != null) generic else null,
                                },
                            });
                            self.popScope();
                        },
                        else => @panic("Unhandled record name!"),
                    }
                }

                if (vari.index) |ind| {
                    try self.analyzeNode(ind);
                }

                if (vari.ty != null) {
                    self.last_generic = generic;
                }
            },

            .type_alias => |alias| {
                try self.analyzeNode(alias);
            },
            .type_ref => |ref| {
                try self.analyzeNode(ref.ty);
            },
            .type_opt => |opt| {
                try self.analyzeNode(opt.ty);
            },
            .type_wild => |tw| {
                const this_scope = try self.pushScope(try self.segment(tw), .{
                    .type = .{
                        .references = 0,
                        .generic = false,
                    },
                });
                try self.path_to_node.put(this_scope.path, index);
                try self.node_to_path.put(index, this_scope.path);
                self.popScope();

                self.last_generic = index;
            },
            // else => std.log.err("Unhandled case: {}", .{node_value}),
        }
    }

    // pub fn analyzeMemberAccess(self: *Self, lty: typecheck.Type,  expr: @TypeOf(node.Node.binary_expr)) void {
    //     const rhs = self.nodes[expr.right.index].identifier;
    //     if (self.last_ref == null) {
    //         std.log.err("LHS does not support property access", .{});
    //         return;
    //     }

    //     const last_path = self.node_to_path.get(self.last_ref.?) orelse @panic("Unable to get last path");
    //     const last_scope = self.getScopeFromPath(last_path) orelse @panic("unable to get scope form path");

    //     switch (last_scope.kind) {}

    // }

    pub fn nodesRange(self: *const Self, range: node.NodeRange) []const node.NodeId {
        return self.node_ranges[range.start .. range.start + range.len];
    }

    fn setScopeFromPath(self: *Self, path: Path) void {
        self.current_scope = &self.root_scope;
        var seg = path.segments[1..];
        while (seg.len > 0) : (seg = seg[1..]) {
            if (self.current_scope.children.getEntry(seg[0])) |val| {
                self.current_scope = val.value_ptr;
            } else {
                @panic("Should ahve found path!");
            }
        }
    }

    pub fn getScopeFromPath(self: *const Self, path: Path) ?*const Scope {
        var current_scope = &self.root_scope;
        var seg = path.segments[1..];
        while (seg.len > 0) : (seg = seg[1..]) {
            if (current_scope.children.getEntry(seg[0])) |val| {
                current_scope = val.value_ptr;
            } else {
                return null;
            }
        }
        return current_scope;
    }

    fn lookupIdent(self: *Self, seg: PathSegment) ?*Scope {
        const scope = self.current_scope.resolveUpChain(seg) orelse return null;
        return scope;
    }

    fn pushScope(self: *Self, seg: PathSegment, kind: ScopeKind) !*Scope {
        try self.pushPath(seg);
        const path = try self.pathFromCurrent();

        const new_node = try self.current_scope.createChild(path, seg, kind);
        self.current_scope = new_node;

        return new_node;
    }

    fn popScope(self: *Self) void {
        _ = self.popPath();
        self.current_scope = self.current_scope.parent.?;
    }

    fn pathFromCurrent(self: *Self) !Path {
        const path = try self.allocator.dupe(PathSegment, self.current_path.items);
        return .{
            .segments = path,
        };
    }

    fn pushPath(self: *Self, new_seg: PathSegment) !void {
        try self.current_path.append(new_seg);
    }

    fn popPath(self: *Self) PathSegment {
        const last = self.current_path.getLast();
        self.current_path.items.len -= 1;
        return last;
    }

    pub fn segment(self: *Self, name: []const u8) !PathSegment {
        if (self.segment_set.getEntry(name)) |value| {
            return value.key_ptr.*;
        }

        const value = try self.allocator.dupe(u8, name);
        try self.segment_set.put(value, {});

        return value;
    }

    pub fn getSegment(self: *const Self, name: []const u8) !?PathSegment {
        if (self.segment_set.getEntry(name)) |value| {
            return value.key_ptr.*;
        }

        return null;
    }
};
