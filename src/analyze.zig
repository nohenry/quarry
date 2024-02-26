const std = @import("std");
const node = @import("node.zig");

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

    const Self = @This();

    pub fn init(parent: *Scope, path: Path, allocator: std.mem.Allocator) Self {
        return .{
            .children = ScopeChildMap.init(allocator),
            .path = path,
            .parent = parent,
            .kind = .root,
        };
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
    },
    type: struct {
        references: u32,
    },
    field: struct {
        references: u32,
    },
    local: struct {
        references: u32,
        parameter: ?u32,
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

    param_index: ?u32 = 0,
    last_ref: ?node.NodeId = null,

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
            .binding => |value| {
                const init_node = self.nodes[value.value.index];
                switch (init_node.kind) {
                    .func, .func_no_params => {
                        const this_scope = try self.pushScope(try self.segment(value.name), .{
                            .func = .{
                                .references = 0,
                            },
                        });
                        try self.path_to_node.put(this_scope.path, index);
                        try self.node_to_path.put(index, this_scope.path);
                    },
                    .type_record,
                    .type_union,
                    => {
                        const this_scope = try self.pushScope(try self.segment(value.name), .{
                            .type = .{
                                .references = 0,
                            },
                        });
                        try self.path_to_node.put(this_scope.path, index);
                        try self.node_to_path.put(index, this_scope.path);
                    },
                    else => {
                        const this_scope = try self.pushScope(try self.segment(value.name), .{
                            .local = .{
                                .references = 0,
                                .parameter = null,
                            },
                        });
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
                    std.log.err("Unable to resolve symbol: `{s}``", .{str});
                } else {
                    // @TODO: dont do this for locals
                    try self.deferred_nodes.append(.{
                        .path = try self.pathFromCurrent(),
                        .node = index,
                    });
                }
            },
            .parameter => |value| {
                try self.analyzeNode(value.ty);
                if (value.spread) {
                    @panic("Unimplemented");
                }

                const this_scope = try self.pushScope(try self.segment(value.name), .{
                    .local = .{
                        .references = 0,
                        .parameter = self.param_index,
                    },
                });
                try self.path_to_node.put(this_scope.path, index);
                try self.node_to_path.put(index, this_scope.path);
                self.popScope();

                if (value.default) |def| {
                    try self.analyzeNode(def);
                }
            },
            .func => |fval| {
                const param_nodes = self.nodesRange(fval.params);
                for (param_nodes, 0..) |param, i| {
                    self.param_index = @truncate(i);
                    try self.analyzeNode(param);
                }
                self.param_index = null;

                if (fval.ret_ty) |ret| {
                    try self.analyzeNode(ret);
                }

                const block_nodes = self.nodesRange(fval.block);
                for (block_nodes) |item| {
                    try self.analyzeNode(item);
                }
            },
            .func_no_params => |fval| {
                if (fval.ret_ty) |ret| {
                    try self.analyzeNode(ret);
                }

                const block_nodes = self.nodesRange(fval.block);
                for (block_nodes) |item| {
                    try self.analyzeNode(item);
                }
            },
            .key_value => |expr| {
                // @TODO: imlement key
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
                try self.analyzeNode(expr.right);
            },
            .unary_expr => |expr| {
                try self.analyzeNode(expr.expr);
            },
            .invoke => |expr| blk: {
                try self.analyzeNode(expr.expr);
                var doing_named: bool = false;

                const arg_nodes = self.nodesRange(expr.args);
                const func_scope = if (self.last_ref) |ref| blk1: {
                    const path = self.node_to_path.get(ref) orelse break :blk1 null;
                    const scope = self.getScopeFromPath(path) orelse break :blk1 null;
                    break :blk1 scope;
                } else {
                    try self.deferred_nodes.append(.{
                        .path = try self.pathFromCurrent(),
                        .node = index,
                    });
                    break :blk;
                };

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
                                if (func_scope == null) {} else if (func_scope.?.children.get(kv.key)) |param| {
                                    if (param.kind == .local and param.kind.local.parameter != null) {
                                        const param_node_id = self.path_to_node.get(param.path);
                                        if (param_node_id) |id| {
                                            try self.node_ref.put(item, id);
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
                                            try self.node_ref.put(item, id);
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
            .const_expr => |expr| {
                try self.analyzeNode(expr.expr);
            },
            .const_block => |expr| {
                const item_nodes = self.nodesRange(expr.block);
                for (item_nodes) |item| {
                    try self.analyzeNode(item);
                }
            },
            .array_init_or_slice_one => |val| {
                try self.analyzeNode(val.expr);
                if (val.value) |expr| {
                    try self.analyzeNode(expr);
                }
            },
            .array_init => |val| {
                const exprs = self.nodesRange(val.exprs);
                for (exprs) |expr| {
                    try self.analyzeNode(expr);
                }
            },

            .type_record => |record| {
                if (record.backing_field) |field| {
                    try self.analyzeNode(field);
                }

                const field_nodes = self.nodesRange(record.fields);
                for (field_nodes) |field| {
                    try self.analyzeNode(field);
                }
            },
            .record_field => |field| {
                try self.analyzeNode(field.ty);
                {
                    _ = try self.pushScope(try self.segment(field.name), .{
                        .field = .{
                            .references = 0,
                        },
                    });
                    self.popScope();
                }

                if (field.default) |def| {
                    try self.analyzeNode(def);
                }
            },
            .type_union => |uni| {
                if (uni.backing_field) |field| {
                    try self.analyzeNode(field);
                }

                const variant_nodes = self.nodesRange(uni.variants);
                for (variant_nodes) |variant| {
                    try self.analyzeNode(variant);
                }
            },
            .union_variant => |vari| {
                try self.analyzeNode(vari.ty);
                {
                    const vnode = self.nodes[vari.name.index];
                    switch (vnode.kind) {
                        .identifier => |name| {
                            _ = try self.pushScope(try self.segment(name), .{
                                .field = .{
                                    .references = 0,
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
            else => std.log.err("Unhandled case: {}", .{node_value}),
        }
    }

    fn nodesRange(self: *const Self, range: node.NodeRange) []const node.NodeId {
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

    fn getScopeFromPath(self: *Self, path: Path) ?*Scope {
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

    fn segment(self: *Self, name: []const u8) !PathSegment {
        if (self.segment_set.getEntry(name)) |value| {
            return value.key_ptr.*;
        }

        const value = try self.allocator.dupe(u8, name);
        try self.segment_set.put(value, {});

        return value;
    }
};
