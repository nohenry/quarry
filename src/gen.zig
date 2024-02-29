const std = @import("std");
const ir = @import("llvm_wrap");

const analyze = @import("analyze.zig");
const node = @import("node.zig");
const eval = @import("eval.zig");
const typecheck = @import("typecheck.zig");

const cstr = [:0]const u8;
pub fn start() void {
    const module = ir.LLVMModuleCreateWithName(@as(cstr, "Foo"));
    // ir.LLVMWriteBitcodeToFile(module, @as(cstr, "out.bc"))
    var err: [:0]u8 = undefined;
    const res = ir.LLVMPrintModuleToFile(module, @as(cstr, "out.ll"), @ptrCast(&err));
    std.debug.assert(res == 0);
}

pub const FunctionState = struct {
    llvm_val: ir.LLVMValueRef,
    alloc_block: ir.LLVMBasicBlockRef,
    control_flow_terminated: bool = false,
    loop_start_block: ?ir.LLVMBasicBlockRef = null,
    loop_done_block: ?ir.LLVMBasicBlockRef = null,
};

pub const CodeGenerator = struct {
    arena: std.mem.Allocator,
    analyzer: *const analyze.Analyzer,
    evaluator: *const eval.Evaluator,
    typechecker: *const typecheck.TypeChecker,

    module: ir.LLVMModuleRef,

    globals: std.AutoHashMap(node.NodeId, ir.LLVMValueRef),
    value_map: std.ArrayList(std.AutoHashMap(node.NodeId, ir.LLVMValueRef)),

    ty_hint: ?typecheck.Type = null,
    llvm_ty_hint: ?ir.LLVMTypeRef = null,
    current_function: ?FunctionState = null,
    make_ref: bool = false,

    builder: ir.LLVMBuilderRef,

    const Self = @This();

    pub fn init(
        analyzer: *const analyze.Analyzer,
        evaluator: *const eval.Evaluator,
        typechecker: *const typecheck.TypeChecker,
        arena: std.mem.Allocator,
        allocator: std.mem.Allocator,
    ) Self {
        const module = ir.LLVMModuleCreateWithName(@as(cstr, "Foo"));

        return .{
            .arena = arena,
            .analyzer = analyzer,
            .evaluator = evaluator,
            .typechecker = typechecker,
            .module = module,
            .globals = std.AutoHashMap(node.NodeId, ir.LLVMValueRef).init(allocator),
            .value_map = std.ArrayList(std.AutoHashMap(node.NodeId, ir.LLVMValueRef)).init(allocator),
            .builder = ir.LLVMCreateBuilder(),
        };
    }

    pub fn genInstructions(self: *Self, instrs: []const eval.InstructionId) !void {
        for (instrs) |instr| {
            _ = try self.genInstr(instr);
        }

        var fn_it = self.evaluator.functions.iterator();
        var funcs = std.ArrayList(struct { node.NodeId, eval.FunctionValue, ir.LLVMValueRef }).init(self.arena);
        while (fn_it.next()) |func| {
            const fn_value = try self.genFuncProto(func.key_ptr.*, func.value_ptr.*);
            try funcs.append(.{ func.key_ptr.*, func.value_ptr.*, fn_value });
        }

        for (funcs.items) |func| {
            _ = try self.genFunc(func[0], func[1], func[2]);
        }

        var err: [*:0]u8 = undefined;
        if (ir.LLVMVerifyModule(self.module, ir.LLVMPrintMessageAction, @ptrCast(&err)) == 1) {
            std.log.err("Error verifying module: {s}", .{err});
        }

        const res = ir.LLVMPrintModuleToFile(self.module, @as(cstr, "out.ll"), @ptrCast(&err));
        std.debug.assert(res == 0);
    }

    pub fn genFuncProto(self: *Self, bind_id: node.NodeId, func: eval.FunctionValue) !ir.LLVMValueRef {
        const path = self.analyzer.node_to_path.get(bind_id) orelse @panic("can't get path");
        var fn_name = std.ArrayList(u8).init(self.arena);
        {
            var fn_name_writer = fn_name.writer();
            if (path.segments.len > 0) {
                try fn_name_writer.writeAll(path.segments[0]);

                for (path.segments[1..]) |seg| {
                    try fn_name_writer.writeByte('.');
                    try fn_name_writer.writeAll(seg);
                }
            }
            try fn_name_writer.writeByte(0);
        }

        const fn_ty = self.typechecker.types.get(func.node_id) orelse @panic("cant get fn type");
        const llvm_fn_ty = try self.genType(fn_ty);

        const llvm_func = ir.LLVMAddFunction(self.module, fn_name.items.ptr, llvm_fn_ty);
        try self.globals.put(bind_id, llvm_func);
        return llvm_func;
    }

    pub fn genFunc(self: *Self, bind_id: node.NodeId, func: eval.FunctionValue, llvm_func: ir.LLVMValueRef) !ir.LLVMValueRef {
        try self.pushScope();
        defer self.popScope();

        const alloc_block = ir.LLVMAppendBasicBlock(llvm_func, @as(cstr, "alloc"));
        const start_block = ir.LLVMAppendBasicBlock(llvm_func, @as(cstr, "start"));
        ir.LLVMPositionBuilderAtEnd(self.builder, start_block);

        std.log.info("Instet bufnion {}", .{bind_id});

        const old_func = self.current_function;
        std.debug.assert(old_func == null);
        self.current_function = .{
            .llvm_val = llvm_func,
            .alloc_block = alloc_block,
        };
        defer self.current_function = old_func;

        try self.genRange(func.instructions);

        ir.LLVMPositionBuilderAtEnd(self.builder, alloc_block);
        _ = ir.LLVMBuildBr(self.builder, start_block);

        return llvm_func;
    }

    pub fn genRange(self: *Self, range: eval.InstructionRange) std.mem.Allocator.Error!void {
        const instr_ids = self.evaluator.instruction_ranges.items[range.start .. range.start + range.len];
        for (instr_ids) |instr_id| {
            _ = try self.genInstr(instr_id);
        }
    }

    pub fn genInstr(self: *Self, instr_id: eval.InstructionId) !?ir.LLVMValueRef {
        const instr = self.evaluator.instructions.items[instr_id.index];

        const result = switch (instr.kind) {
            .constant => blk: {
                switch (instr.value.?.kind) {
                    .int => |val| {
                        const signed: c_int = switch (self.ty_hint.?.*) {
                            .int, .int_literal, .iptr => 1,
                            .uint, .uptr => 0,
                            else => @panic("Expected int type"),
                        };
                        const value = ir.LLVMConstInt(self.llvm_ty_hint.?, @intCast(val), signed);
                        break :blk value;
                    },
                    .bool => |val| {
                        const value = ir.LLVMConstInt(ir.LLVMInt1Type(), if (val) 1 else 0, 0);
                        break :blk value;
                    },
                    .float => |val| {
                        const value = ir.LLVMConstReal(self.llvm_ty_hint.?, val);
                        break :blk value;
                    },
                    else => {
                        std.log.err("Unhandled constant value {}", .{instr.value.?.kind});
                        return null;
                    },
                }
            },
            .identifier => |id| {
                const bound_path = self.analyzer.node_to_path.get(id) orelse @panic("Unable to get path of ident");
                const scope = self.analyzer.getScopeFromPath(bound_path) orelse @panic("Unable to get scpe from path");
                const param_index = scope.kind.local.parameter;
                if (param_index) |ind| {
                    if (self.current_function) |*func| {
                        const value = ir.LLVMGetParam(func.llvm_val, @intCast(ind));
                        if (self.make_ref) {
                            // Lazily store params in variables when we need to take an address of them
                            const current_block = ir.LLVMGetInsertBlock(self.builder);
                            ir.LLVMPositionBuilderAtEnd(self.builder, func.alloc_block);
                            const alloc_value = ir.LLVMBuildAlloca(self.builder, ir.LLVMTypeOf(value), @as(cstr, ""));
                            ir.LLVMPositionBuilderAtEnd(self.builder, current_block);
                            _ = ir.LLVMBuildStore(self.builder, value, alloc_value);

                            return alloc_value;
                        }

                        return value;
                    }
                }

                const value = self.resolveValueUp(id);
                const global_value = if (value == null) self.globals.get(id) else null;
                if (self.make_ref) return value orelse global_value;

                if (value != null) {
                    const ty = self.typechecker.declared_types.get(id) orelse @panic("Unable to get declared type");
                    const llty = try self.genType(ty);

                    const load = ir.LLVMBuildLoad2(self.builder, llty, value.?, @as(cstr, ""));

                    return load;
                } else {
                    return ir.LLVMGetInitializer(global_value.?);
                }
            },
            .@"break" => |_| {
                // @TODO: handle expression
                const func = if (self.current_function) |*func| func else @panic("Expected function!!");
                func.control_flow_terminated = true;
                const done_block = func.loop_done_block orelse @panic("Expected loop done block");

                _ = ir.LLVMBuildBr(self.builder, done_block);
                return null;
            },
            .ret => |exp| {
                const func = if (self.current_function) |*func| func else @panic("Expected function!!");
                func.control_flow_terminated = true;
                if (exp.expr) |e| {
                    const node_id = self.evaluator.instr_to_node.get(e) orelse @panic("Unable to get node id from isntruction return value");
                    const ret_ty = self.typechecker.types.get(node_id).?;

                    const value = try self.genWithTypeHint(ret_ty, genInstr, .{ self, e });

                    _ = ir.LLVMBuildRet(self.builder, value.?);
                } else {
                    _ = ir.LLVMBuildRetVoid(self.builder);
                }
                return null;
            },
            .binding => |info| blk: {
                const ty = self.typechecker.declared_types.getEntry(info.node) orelse @panic("No declared type");
                const llty = try self.genType(ty.value_ptr.*);
                const llval = try self.genWithTypeHint(ty.value_ptr.*, genInstr, .{ self, info.value }) orelse @panic("no init");

                if (self.current_function) |cfunc| {
                    const current_block = ir.LLVMGetInsertBlock(self.builder);
                    ir.LLVMPositionBuilderAtEnd(self.builder, cfunc.alloc_block);
                    const alloc_value = ir.LLVMBuildAlloca(self.builder, llty, @as(cstr, ""));
                    ir.LLVMPositionBuilderAtEnd(self.builder, current_block);
                    _ = ir.LLVMBuildStore(self.builder, llval, alloc_value);

                    try self.value_map.items[self.value_map.items.len - 1].put(info.node, alloc_value);

                    break :blk alloc_value;
                } else {
                    const global_var = ir.LLVMAddGlobal(self.module, llty, @as(cstr, ""));
                    _ = ir.LLVMSetInitializer(global_var, llval);
                    try self.globals.put(info.node, global_var);
                    break :blk global_var;
                }
            },
            .assign => |exp| {
                const lvalue = try self.genWithRef(true, genInstr, .{ self, exp.left }) orelse @panic("expected lvalue");

                const lhs_node_id = self.evaluator.instr_to_node.get(exp.left) orelse @panic("Unable to get lhs node id");
                const ty = self.typechecker.types.getEntry(lhs_node_id) orelse @panic("Unable to get type entry");
                const rvalue = try self.genWithTypeHint(ty.value_ptr.*, genInstr, .{ self, exp.right }) orelse @panic("expected rvalue");

                const svalue = ir.LLVMBuildStore(self.builder, rvalue, lvalue);
                return svalue;
            },
            .binary_expr => |binop| {
                const lhs_node_id = self.evaluator.instr_to_node.get(binop.left) orelse @panic("Unable to get lhs node id");
                const rhs_node_id = self.evaluator.instr_to_node.get(binop.right) orelse @panic("Unable to get rhs node id");
                const ty = self.typechecker.types.get(lhs_node_id) orelse
                    self.typechecker.types.get(rhs_node_id) orelse
                    self.ty_hint orelse
                    @panic("Unable to retrieve type information for node");

                const lhs = try self.genWithTypeHint(ty, genInstr, .{ self, binop.left }) orelse @panic("Unable to get LHS");
                const rhs = try self.genWithTypeHint(ty, genInstr, .{ self, binop.right }) orelse @panic("Unable to get RHS");

                return switch (ty.*) {
                    // @TODO: think about nuw and nsw
                    .int, .iptr => switch (binop.op) {
                        .plus => ir.LLVMBuildAdd(self.builder, lhs, rhs, @as(cstr, "")),
                        .minus => ir.LLVMBuildSub(self.builder, lhs, rhs, @as(cstr, "")),
                        .times => ir.LLVMBuildMul(self.builder, lhs, rhs, @as(cstr, "")),
                        .divide => ir.LLVMBuildSDiv(self.builder, lhs, rhs, @as(cstr, "")),
                        .bitand => ir.LLVMBuildAnd(self.builder, lhs, rhs, @as(cstr, "")),
                        .bitor => ir.LLVMBuildOr(self.builder, lhs, rhs, @as(cstr, "")),
                        .bitxor => ir.LLVMBuildXor(self.builder, lhs, rhs, @as(cstr, "")),
                        .shiftleft => ir.LLVMBuildShl(self.builder, lhs, rhs, @as(cstr, "")),
                        .shiftright => ir.LLVMBuildLShr(self.builder, lhs, rhs, @as(cstr, "")),

                        .equal => ir.LLVMBuildICmp(self.builder, ir.LLVMIntEQ, lhs, rhs, @as(cstr, "")),
                        .not_equal => ir.LLVMBuildICmp(self.builder, ir.LLVMIntNE, lhs, rhs, @as(cstr, "")),
                        .gt => ir.LLVMBuildICmp(self.builder, ir.LLVMIntSGT, lhs, rhs, @as(cstr, "")),
                        .gte => ir.LLVMBuildICmp(self.builder, ir.LLVMIntSGE, lhs, rhs, @as(cstr, "")),
                        .lt => ir.LLVMBuildICmp(self.builder, ir.LLVMIntSLT, lhs, rhs, @as(cstr, "")),
                        .lte => ir.LLVMBuildICmp(self.builder, ir.LLVMIntSLE, lhs, rhs, @as(cstr, "")),
                        else => @panic("Invalid operator"),
                    },
                    .uint, .uptr => switch (binop.op) {
                        .plus => ir.LLVMBuildAdd(self.builder, lhs, rhs, @as(cstr, "")),
                        .minus => ir.LLVMBuildSub(self.builder, lhs, rhs, @as(cstr, "")),
                        .times => ir.LLVMBuildMul(self.builder, lhs, rhs, @as(cstr, "")),
                        .divide => ir.LLVMBuildUDiv(self.builder, lhs, rhs, @as(cstr, "")),
                        .bitand => ir.LLVMBuildAnd(self.builder, lhs, rhs, @as(cstr, "")),
                        .bitor => ir.LLVMBuildOr(self.builder, lhs, rhs, @as(cstr, "")),
                        .bitxor => ir.LLVMBuildXor(self.builder, lhs, rhs, @as(cstr, "")),
                        .shiftleft => ir.LLVMBuildShl(self.builder, lhs, rhs, @as(cstr, "")),
                        .shiftright => ir.LLVMBuildAShr(self.builder, lhs, rhs, @as(cstr, "")),

                        .equal => ir.LLVMBuildICmp(self.builder, ir.LLVMIntEQ, lhs, rhs, @as(cstr, "")),
                        .not_equal => ir.LLVMBuildICmp(self.builder, ir.LLVMIntNE, lhs, rhs, @as(cstr, "")),
                        .gt => ir.LLVMBuildICmp(self.builder, ir.LLVMIntUGT, lhs, rhs, @as(cstr, "")),
                        .gte => ir.LLVMBuildICmp(self.builder, ir.LLVMIntUGE, lhs, rhs, @as(cstr, "")),
                        .lt => ir.LLVMBuildICmp(self.builder, ir.LLVMIntULT, lhs, rhs, @as(cstr, "")),
                        .lte => ir.LLVMBuildICmp(self.builder, ir.LLVMIntULE, lhs, rhs, @as(cstr, "")),
                        else => @panic("Invalid operator"),
                    },
                    .float => switch (binop.op) {
                        .plus => ir.LLVMBuildFAdd(self.builder, lhs, rhs, @as(cstr, "")),
                        .minus => ir.LLVMBuildFSub(self.builder, lhs, rhs, @as(cstr, "")),
                        .times => ir.LLVMBuildFMul(self.builder, lhs, rhs, @as(cstr, "")),
                        .divide => ir.LLVMBuildFDiv(self.builder, lhs, rhs, @as(cstr, "")),

                        .equal => ir.LLVMBuildFCmp(self.builder, ir.LLVMRealOEQ, lhs, rhs, @as(cstr, "")),
                        .not_equal => ir.LLVMBuildFCmp(self.builder, ir.LLVMRealONE, lhs, rhs, @as(cstr, "")),
                        .gt => ir.LLVMBuildFCmp(self.builder, ir.LLVMRealOGT, lhs, rhs, @as(cstr, "")),
                        .gte => ir.LLVMBuildFCmp(self.builder, ir.LLVMRealOGE, lhs, rhs, @as(cstr, "")),
                        .lt => ir.LLVMBuildFCmp(self.builder, ir.LLVMRealOLT, lhs, rhs, @as(cstr, "")),
                        .lte => ir.LLVMBuildFCmp(self.builder, ir.LLVMRealOLE, lhs, rhs, @as(cstr, "")),
                        else => @panic("Unhandled binop operaotr"),
                    },
                    .boolean => switch (binop.op) {
                        .equal => ir.LLVMBuildICmp(self.builder, ir.LLVMIntEQ, lhs, rhs, @as(cstr, "")),
                        .not_equal => ir.LLVMBuildICmp(self.builder, ir.LLVMIntNE, lhs, rhs, @as(cstr, "")),
                        else => @panic("Unhandled binop operaotr"),
                    },
                    else => @panic("Unhandled binop type"),
                };
            },
            .unary_expr => |unary| {
                const expr = try self.genInstr(unary.expr) orelse @panic("Unable to get expr");

                const expr_node_id = self.evaluator.instr_to_node.get(unary.expr) orelse @panic("Unable to get expr node id");
                const ty = self.typechecker.types.get(expr_node_id) orelse
                    self.ty_hint orelse
                    @panic("Unable to retrieve type information for node");

                return switch (ty.*) {
                    // @TODO: think about nuw and nsw
                    .int, .iptr, .uint, .uptr => switch (unary.op) {
                        .minus => ir.LLVMBuildNeg(self.builder, expr, @as(cstr, "")),
                        else => @panic("Invalid operator"),
                    },
                    .float => switch (unary.op) {
                        .minus => ir.LLVMBuildFNeg(self.builder, expr, @as(cstr, "")),
                        else => @panic("Unhandled binop operaotr"),
                    },
                    .boolean => switch (unary.op) {
                        .bang => ir.LLVMBuildFNeg(self.builder, expr, @as(cstr, "")),
                        else => @panic("Unhandled binop operaotr"),
                    },
                    else => @panic("Unhandled binop type"),
                };
            },
            .argument => |arg_instr_id| try self.genInstr(arg_instr_id),
            .invoke => |call| {
                var llvm_args = std.ArrayList(ir.LLVMValueRef).init(self.arena);
                try llvm_args.ensureTotalCapacity(call.args.len);
                const arg_instrs = self.instrRange(call.args);

                const node_id = self.evaluator.instr_to_node.get(instr_id) orelse @panic("Unable to get node id of invoke");
                const ref_node_id = self.analyzer.node_ref.get(node_id) orelse @panic("uanble to get node ref");
                const bind_func_node = &self.analyzer.nodes[ref_node_id.index].kind.binding;
                const func_node = &self.analyzer.nodes[bind_func_node.value.index].kind.func;

                const param_nodes = self.analyzer.nodesRange(func_node.params);
                std.debug.assert(param_nodes.len == arg_instrs.len);

                for (arg_instrs, 0..) |arg_id, i| {
                    const parameter_ty = self.typechecker.declared_types.get(param_nodes[i]) orelse @panic("Unable to get param ty");
                    const value = try self.genWithTypeHint(parameter_ty, genInstr, .{ self, arg_id }) orelse @panic("Unable to get argument value");

                    try llvm_args.append(value);
                }

                const callee_id = self.evaluator.instr_to_node.get(call.expr) orelse @panic("Unable to get callee id");
                const callee_type = self.typechecker.types.get(callee_id) orelse @panic("Unable to get callee ty");
                const callee_binding = self.analyzer.node_ref.get(callee_id) orelse @panic("Unable to get original fn id");

                const llvm_fn_ty = try self.genType(callee_type);
                const global_val = self.globals.get(callee_binding) orelse @panic("function not in global table");

                const result = ir.LLVMBuildCall2(
                    self.builder,
                    llvm_fn_ty,
                    global_val,
                    llvm_args.items.ptr,
                    @intCast(llvm_args.items.len),
                    @as(cstr, ""),
                );

                return result;
            },
            .if_expr => |expr| {
                const func = if (self.current_function) |*func| func else @panic("Expected function!!");
                const old_cf = func.control_flow_terminated;
                defer func.control_flow_terminated = old_cf;
                func.control_flow_terminated = false;

                const cond_value = try self.genInstr(expr.cond) orelse @panic("Unable to get ifexpr");

                const true_block = ir.LLVMAppendBasicBlock(func.llvm_val, @as(cstr, "if.then"));
                const false_block = if (expr.false_block) |_| ir.LLVMAppendBasicBlock(func.llvm_val, @as(cstr, "if.else")) else null;
                const done_block = ir.LLVMAppendBasicBlock(func.llvm_val, @as(cstr, "if.done"));

                _ = ir.LLVMBuildCondBr(self.builder, cond_value, true_block, false_block orelse done_block);

                ir.LLVMPositionBuilderAtEnd(self.builder, true_block);
                try self.genRange(expr.true_block);
                if (!func.control_flow_terminated) {
                    _ = ir.LLVMBuildBr(self.builder, done_block);
                }

                func.control_flow_terminated = false;

                if (false_block) |fblk| {
                    ir.LLVMPositionBuilderAtEnd(self.builder, fblk);
                    try self.genRange(expr.false_block.?);
                    if (!func.control_flow_terminated) {
                        _ = ir.LLVMBuildBr(self.builder, done_block);
                    }
                }

                ir.LLVMPositionBuilderAtEnd(self.builder, done_block);

                return null;
            },
            .loop => |loop| {
                const func = if (self.current_function) |*func| func else @panic("Expected function!!");
                const loop_block = ir.LLVMAppendBasicBlock(func.llvm_val, @as(cstr, "loop.loop"));
                const done_block = ir.LLVMAppendBasicBlock(func.llvm_val, @as(cstr, "loop.done"));

                const old_loop_start = func.loop_start_block;
                const old_loop_done = func.loop_done_block;
                defer {
                    func.loop_start_block = old_loop_start;
                    func.loop_done_block = old_loop_done;
                }

                func.loop_start_block = loop_block;
                func.loop_done_block = done_block;

                _ = ir.LLVMBuildBr(self.builder, loop_block);

                ir.LLVMPositionBuilderAtEnd(self.builder, loop_block);
                try self.genRange(loop.loop_block);
                _ = ir.LLVMBuildBr(self.builder, loop_block);

                ir.LLVMPositionBuilderAtEnd(self.builder, done_block);

                return null;
            },
            .array_init => |arr| blk: {
                const node_id = self.evaluator.instr_to_node.get(instr_id) orelse @panic("Unable to get node id of invoke");
                const node_ty = self.typechecker.types.get(node_id) orelse @panic("Unable to get node type");
                const base_ty = node_ty.array.base;

                var ll_vals = std.ArrayList(ir.LLVMValueRef).init(self.arena);
                try ll_vals.ensureTotalCapacity(arr.exprs.len);

                const llarrty = try self.genType(node_ty);
                const llty = try self.genType(base_ty);
                const old_ty_hint = self.ty_hint;
                const old_llvm_ty_hint = self.llvm_ty_hint;
                self.ty_hint = base_ty;
                self.llvm_ty_hint = llty;
                defer {
                    self.ty_hint = old_ty_hint;
                    self.llvm_ty_hint = old_llvm_ty_hint;
                }

                const item_nodes = self.instrRange(arr.exprs);
                for (item_nodes) |item_id| {
                    const value = try self.genInstr(item_id) orelse @panic("Unable to gen llvm value");
                    try ll_vals.append(value);
                }

                const arr_value = ir.LLVMConstArray2(llty, ll_vals.items.ptr, ll_vals.items.len);
                const global_value = ir.LLVMAddGlobal(self.module, llarrty, @as(cstr, ""));
                ir.LLVMSetGlobalConstant(global_value, 1);
                ir.LLVMSetInitializer(global_value, arr_value);

                break :blk global_value;
            },
            .reference => |ref| blk: {
                const value = try self.genWithRef(true, genInstr, .{ self, ref.expr });
                break :blk value;
            },
            .dereference => |ref| blk: {
                // const value = try self.genInstr(ref.expr) orelse @panic("Unable to get dereference value");
                const value = try self.genWithRef(false, genInstr, .{ self, ref.expr }) orelse @panic("Unable to get dereference value");
                // @TODO: check if we need to do anything special for make ref (i dont think so)
                if (self.make_ref) {
                    break :blk value;
                }
                const node_id = self.evaluator.instr_to_node.get(instr_id) orelse @panic("Unable to get node id of invoke");
                const node_ty = self.typechecker.types.get(node_id) orelse @panic("Unable to get node type");
                const llvm_ty = try self.genType(node_ty);

                break :blk ir.LLVMBuildLoad2(self.builder, llvm_ty, value, @as(cstr, ""));
            },
            //
            // else => {
            //     std.log.err("Unhandled instruction in codegen! {}", .{instr});
            //     return null;
            // },
        };

        return result;
    }

    pub fn genWithRef(self: *Self, ref: bool, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) @typeInfo(@TypeOf(func)).Fn.return_type.? {
        const old_mr = self.make_ref;
        self.make_ref = ref;
        defer self.make_ref = old_mr;
        return @call(.auto, func, args);
    }

    pub fn genWithTypeHint(self: *Self, ty: typecheck.Type, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) @typeInfo(@TypeOf(func)).Fn.return_type.? {
        const llty = try self.genType(ty);
        const old_ty_hint = self.ty_hint;
        const old_llvm_ty_hint = self.llvm_ty_hint;
        self.ty_hint = ty;
        self.llvm_ty_hint = llty;
        defer {
            self.ty_hint = old_ty_hint;
            self.llvm_ty_hint = old_llvm_ty_hint;
        }

        return @call(.auto, func, args);
    }

    pub fn genType(self: *const Self, ty: typecheck.Type) !ir.LLVMTypeRef {
        return switch (ty.*) {
            .int, .uint => |size| ir.LLVMIntType(@intCast(size)),
            .int_literal => ir.LLVMInt64Type(),
            .boolean => ir.LLVMInt1Type(),
            .float => |size| switch (size) {
                16 => ir.LLVMHalfType(),
                32 => ir.LLVMFloatType(),
                64 => ir.LLVMDoubleType(),
                128 => ir.LLVMFP128Type(),
                else => std.debug.panic("Unsupported float size {}", .{size}),
            },
            .array => |arr_ty| blk: {
                const ll_base = try self.genType(arr_ty.base);
                break :blk ir.LLVMArrayType2(ll_base, arr_ty.size);
            },
            .reference => |ref| blk: {
                const ll_base = try self.genType(ref.base);
                break :blk ir.LLVMPointerType(ll_base, 0);
            },
            .func => |fn_ty| blk: {
                var llvm_param_tys = std.ArrayList(ir.LLVMTypeRef).init(self.arena);
                const param_index_tys = fn_ty.params.*.multi_type_impl;
                const param_tys = self.typechecker.interner.multi_types.items[param_index_tys.start .. param_index_tys.start + param_index_tys.len];

                for (param_tys) |pty| {
                    try llvm_param_tys.append(try self.genType(pty));
                }

                const ret_ty = if (fn_ty.ret_ty) |rty| try self.genType(rty) else ir.LLVMVoidType();

                break :blk ir.LLVMFunctionType(
                    ret_ty,
                    llvm_param_tys.items.ptr,
                    @intCast(llvm_param_tys.items.len),
                    0,
                );
            },
            else => std.debug.panic("Unknown type! {}", .{ty.*}),
        };
    }

    inline fn pushScope(self: *Self) !void {
        try self.value_map.append(std.AutoHashMap(node.NodeId, ir.LLVMValueRef).init(self.arena));
    }

    inline fn popScope(self: *Self) void {
        self.value_map.items.len -= 1;
    }

    fn resolveValueUp(self: *Self, id: node.NodeId) ?ir.LLVMValueRef {
        var current = self.value_map.items;
        while (current.len > 0) : (current = current[0 .. current.len - 1]) {
            if (current[current.len - 1].get(id)) |val| return val;
        }

        // return self.globals.get(id);
        return null;
    }

    fn resolveValueUpPtr(self: *Self, id: node.NodeId) ?*ir.LLVMValueRef {
        var current = self.value_map.items;
        while (current.len > 0) : (current = current[0 .. current.len - 1]) {
            if (current[current.len - 1].getEntry(id)) |val| return val.value_ptr;
        }

        if (self.globals.getEntry(id)) |ent| return ent.value_ptr;

        return null;
    }

    inline fn instrRange(self: *const Self, range: eval.InstructionRange) []const eval.InstructionId {
        return self.evaluator.instruction_ranges.items[range.start .. range.start + range.len];
    }
};
