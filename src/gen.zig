const std = @import("std");
const ir = @import("llvm_wrap");

const analyze = @import("analyze.zig");
const node = @import("node.zig");
const eval = @import("eval.zig");
const typecheck = @import("typecheck.zig");
const diags = @import("diagnostics.zig");

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

pub const StoreOperation = union(enum) {
    none,
    store,
    memcpy: usize,
};

pub const ParamInfo = struct {
    index: usize,
    indirect: bool,
};

pub const CodeGenerator = struct {
    arena: std.mem.Allocator,
    analyzer: *const analyze.Analyzer,
    evaluator: *const eval.Evaluator,
    typechecker: *const typecheck.TypeChecker,
    d: *diags.Diagnostics,

    context: ir.LLVMContextRef,
    module: ir.LLVMModuleRef,
    target: ir.LLVMTargetRef,
    target_machine: ir.LLVMTargetMachineRef,
    target_data: ir.LLVMTargetDataRef,

    globals: std.AutoHashMap(node.NodeId, ir.LLVMValueRef),
    type_map: std.AutoHashMap(node.NodeId, ir.LLVMTypeRef),
    value_map: std.ArrayList(std.AutoHashMap(node.NodeId, ir.LLVMValueRef)),

    ty_hint: ?typecheck.Type = null,
    llvm_ty_hint: ?ir.LLVMTypeRef = null,
    alloca_hint: ?ir.LLVMValueRef = null,
    current_function: ?FunctionState = null,
    make_ref: bool = false,
    store_op: StoreOperation = .store,
    param_info: std.ArrayList(ParamInfo),

    builder: ir.LLVMBuilderRef,

    const Self = @This();

    pub fn init(
        analyzer: *const analyze.Analyzer,
        evaluator: *const eval.Evaluator,
        typechecker: *const typecheck.TypeChecker,
        d: *diags.Diagnostics,
        arena: std.mem.Allocator,
        allocator: std.mem.Allocator,
    ) Self {
        const context = ir.LLVMContextCreate();
        const module = ir.LLVMModuleCreateWithNameInContext(@as(cstr, "Foo"), context);
        ir.LLVM_InitializeAllTargets();
        ir.LLVM_InitializeAllTargetInfos();
        ir.LLVM_InitializeAllAsmParsers();
        ir.LLVM_InitializeAllAsmPrinters();
        ir.LLVM_InitializeAllDisassemblers();
        ir.LLVM_InitializeAllTargetMCs();

        const target_triple: [*:0]u8 = ir.LLVMGetDefaultTargetTriple();
        std.log.info("Using target triple: {s}", .{target_triple});
        var target: ir.LLVMTargetRef = undefined;
        var err: [*:0]u8 = undefined;
        if (ir.LLVMGetTargetFromTriple(target_triple, &target, @ptrCast(&err)) == 1) {
            std.log.err("Error getting target: {s}", .{err});
        }

        const target_machine = ir.LLVMCreateTargetMachine(
            target,
            target_triple,
            ir.LLVMGetHostCPUName(),
            ir.LLVMGetHostCPUFeatures(),
            ir.LLVMCodeGenLevelNone,
            ir.LLVMRelocDefault,
            ir.LLVMCodeModelDefault,
        );
        const target_data = ir.LLVMCreateTargetDataLayout(target_machine);

        return .{
            .arena = arena,
            .analyzer = analyzer,
            .evaluator = evaluator,
            .typechecker = typechecker,

            .d = d,
            .context = context,
            .module = module,
            .target = target,
            .target_machine = target_machine,
            .target_data = target_data,
            .param_info = std.ArrayList(ParamInfo).init(allocator),

            .globals = std.AutoHashMap(node.NodeId, ir.LLVMValueRef).init(allocator),
            .type_map = std.AutoHashMap(node.NodeId, ir.LLVMTypeRef).init(allocator),
            .value_map = std.ArrayList(std.AutoHashMap(node.NodeId, ir.LLVMValueRef)).init(allocator),
            .builder = ir.LLVMCreateBuilder(),
        };
    }

    pub fn genInstructions(self: *Self, instrs: []const eval.InstructionId) !void {
        for (instrs) |instr| {
            _ = try self.genInstr(instr);
        }

        var ty_it = self.evaluator.types.iterator();
        while (ty_it.next()) |ty| {
            // const path = self.analyzer.node_to_path.get(ty.key_ptr.*) orelse @panic("can't get path");
            // const name = try self.manglePath(path);
            const named_struct = ir.LLVMStructCreateNamed(self.context, @as(cstr, "fooo"));

            const tyty = self.typechecker.types.get(ty.value_ptr.node_id) orelse @panic("Unable to get type for named type");
            // const base_ty = self.typechecker.types.get(tyty.named).?;
            _ = try self.genType(tyty.type, .{ .named_struct = named_struct });
            try self.type_map.put(ty.key_ptr.*, named_struct);
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

        if (ir.LLVMTargetMachineEmitToFile(
            self.target_machine,
            self.module,
            @as(cstr, "out.o"),
            ir.LLVMObjectFile,
            @ptrCast(&err),
        ) == 1) {
            std.log.err("Error writint to object file: {s}", .{err});
        }
    }

    fn manglePath(self: *Self, path: analyze.Path) ![]const u8 {
        var mangled_name = std.ArrayList(u8).init(self.arena);
        var mangled_name_writer = mangled_name.writer();
        if (path.segments.len > 0) {
            try mangled_name_writer.writeAll(path.segments[0]);

            for (path.segments[1..]) |seg| {
                try mangled_name_writer.writeByte('_');
                try mangled_name_writer.writeAll(seg);
            }
        }
        try mangled_name_writer.writeByte(0);

        return mangled_name.items;
    }

    pub fn genFuncProto(self: *Self, bind_id: node.NodeId, func: eval.FunctionValue) !ir.LLVMValueRef {
        const path = self.analyzer.node_to_path.get(bind_id) orelse @panic("can't get path");
        const mangled_name = try self.manglePath(path);

        const fn_ty = self.typechecker.types.get(func.node_id) orelse @panic("cant get fn type");
        const llvm_fn_ty = try self.genType(fn_ty, .{});

        const llvm_func = ir.LLVMAddFunction(self.module, mangled_name.ptr, llvm_fn_ty);
        for (self.param_info.items) |info| {
            if (info.indirect) {
                const nonnull = ir.LLVMCreateEnumAttribute(self.context, 38, 1); // nonnull
                const readonly = ir.LLVMCreateEnumAttribute(self.context, 45, 1); // readonly
                ir.LLVMAddAttributeAtIndex(llvm_func, @intCast(info.index + 1), nonnull);
                ir.LLVMAddAttributeAtIndex(llvm_func, @intCast(info.index + 1), readonly);
            }
        }
        try self.globals.put(bind_id, llvm_func);
        return llvm_func;
    }

    pub fn genFunc(self: *Self, bind_id: node.NodeId, func: eval.FunctionValue, llvm_func: ir.LLVMValueRef) !ir.LLVMValueRef {
        try self.pushScope();
        defer self.popScope();

        const alloc_block = ir.LLVMAppendBasicBlockInContext(self.context, llvm_func, @as(cstr, "alloc"));
        const start_block = ir.LLVMAppendBasicBlockInContext(self.context, llvm_func, @as(cstr, "start"));
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

        // const attr = ir.LLVMCreateEnumAttribute(ir.LLVMGetGlobalContext(), 10, 1);
        // ir.LLVMAddAttributeAtIndex(llvm_func, 1, attr);

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
                const ty = self.typechecker.declared_types.get(id) orelse @panic("Unable to get declared type");

                if (param_index) |ind| {
                    // const pinfo = blk: {
                    //     for (self.param_info.items) |item| {
                    //         if (item.index == ind) break :blk item;
                    //     }
                    //     @panic("Unable to get aprameter info");
                    // };

                    if (self.current_function) |*func| {
                        const value = ir.LLVMGetParam(func.llvm_val, @intCast(ind));
                        const indirect = self.paramWillBeIndirect(ty);

                        if (self.make_ref and !indirect) {
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
                    const llty = try self.genType(ty, .{});

                    if (ty.* == .array) {
                        const size = ir.LLVMStoreSizeOfType(self.target_data, llty);
                        self.store_op = .{ .memcpy = size };
                        return value.?;
                    }

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
                var ty = self.typechecker.declared_types.get(info.node) orelse @panic("No declared type");
                const llty = try self.genType(ty, .{});

                while (ty.* == .named) {
                    ty = self.typechecker.declared_types.get(ty.named).?.owned_type.base;
                }

                if (self.current_function) |cfunc| {
                    const current_block = ir.LLVMGetInsertBlock(self.builder);
                    ir.LLVMPositionBuilderAtEnd(self.builder, cfunc.alloc_block);
                    const alloc_value = ir.LLVMBuildAlloca(self.builder, llty, @as(cstr, "bind"));
                    ir.LLVMPositionBuilderAtEnd(self.builder, current_block);

                    self.alloca_hint = alloc_value;
                    const llval = try self.genWithTypeHint(ty, genInstr, .{ self, info.value }) orelse @panic("no init");
                    self.alloca_hint = null;

                    switch (self.store_op) {
                        .none => {},
                        .memcpy => |size| {
                            _ = ir.LLVMBuildMemCpy(
                                self.builder,
                                alloc_value,
                                0,
                                llval,
                                0,
                                ir.LLVMConstInt(self.ptrSizedInt(), size, 0),
                            );
                        },
                        .store => {
                            _ = ir.LLVMBuildStore(
                                self.builder,
                                llval,
                                alloc_value,
                            );
                        },
                    }
                    self.store_op = .store;

                    try self.value_map.items[self.value_map.items.len - 1].put(info.node, alloc_value);

                    break :blk alloc_value;
                } else {
                    const llval = try self.genWithTypeHint(ty, genInstr, .{ self, info.value }) orelse @panic("no init");
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

                defer self.store_op = .store;

                const node_id = self.evaluator.instr_to_node.get(instr_id) orelse @panic("Unable to get node id of invoke");
                const ref_node_id = self.analyzer.node_ref.get(node_id) orelse @panic("uanble to get node ref");
                const bind_func_node = &self.analyzer.nodes[ref_node_id.index].kind.binding;
                const func_node = &self.analyzer.nodes[bind_func_node.value.index].kind.func;

                const param_nodes = self.analyzer.nodesRange(func_node.params);
                std.debug.assert(param_nodes.len == arg_instrs.len);

                for (arg_instrs, 0..) |arg_id, i| {
                    const old_alloca_hint = self.alloca_hint;
                    defer self.alloca_hint = old_alloca_hint;
                    self.alloca_hint = null;

                    var parameter_ty = self.typechecker.declared_types.get(param_nodes[i]) orelse @panic("Unable to get param ty");

                    const old_makeref = self.make_ref;
                    defer self.make_ref = old_makeref;
                    // Arguments like aggregate types should be referenced.
                    self.make_ref = self.paramWillBeIndirect(parameter_ty);

                    while (parameter_ty.* == .named) {
                        parameter_ty = self.typechecker.declared_types.get(parameter_ty.named).?.owned_type.base;
                    }
                    // Why does not looking at store op work here?
                    const value = try self.genWithTypeHint(parameter_ty, genInstr, .{ self, arg_id }) orelse @panic("Unable to get argument value");

                    try llvm_args.append(value);
                }

                const callee_id = self.evaluator.instr_to_node.get(call.expr) orelse @panic("Unable to get callee id");
                const callee_type = self.typechecker.types.get(callee_id) orelse @panic("Unable to get callee ty");
                const callee_binding = self.analyzer.node_ref.get(callee_id) orelse @panic("Unable to get original fn id");

                const llvm_fn_ty = try self.genType(callee_type, .{});
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
            .subscript => |sub| blk: {
                var ll_expr = try self.genWithRef(true, genInstr, .{ self, sub.expr }) orelse @panic("Unable to get subscript expression!");

                const ll_sub = try self.genWithTypeHint(self.typechecker.interner.uintTy(64), genInstr, .{ self, sub.sub }) orelse @panic("Unable to get subscript sub!");

                const node_id = self.evaluator.instr_to_node.get(sub.expr) orelse @panic("Unable to get node id of subscript expression");
                var node_ty = self.typechecker.types.get(node_id) orelse @panic("Unable to get node type of subscript expression");
                while (node_ty.* == .reference) {
                    const llty_tmp = try self.genType(node_ty, .{});
                    ll_expr = ir.LLVMBuildLoad2(self.builder, llty_tmp, ll_expr, @as(cstr, ""));
                    node_ty = node_ty.reference.base;
                }
                const llty = try self.genType(node_ty, .{});

                switch (node_ty.*) {
                    .array => |arr_ty| {
                        const value = ir.LLVMBuildZExtOrBitCast(self.builder, ll_sub, ir.LLVMInt64TypeInContext(self.context), @as(cstr, ""));
                        var indicies = [2]ir.LLVMValueRef{ ir.LLVMConstInt(ir.LLVMInt64TypeInContext(self.context), 0, 0), value };
                        const ptr = ir.LLVMBuildInBoundsGEP2(self.builder, llty, ll_expr, @ptrCast(&indicies), @intCast(indicies.len), @as(cstr, ""));
                        if (self.make_ref) {
                            break :blk ptr;
                        } else {
                            const ll_base = try self.genType(arr_ty.base, .{});
                            break :blk ir.LLVMBuildLoad2(self.builder, ll_base, ptr, @as(cstr, ""));
                        }
                    },
                    .slice => |slc_ty| {
                        const base_ty = try self.genType(slc_ty.base, .{});
                        const str: [*:0]u8 = ir.LLVMPrintValueToString(ll_expr);
                        std.log.info("Val: {s}", .{str});

                        const value = ir.LLVMBuildZExtOrBitCast(self.builder, ll_sub, ir.LLVMInt64TypeInContext(self.context), @as(cstr, ""));
                        var indicies = [_]ir.LLVMValueRef{
                            ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), 0, 0),
                            ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), 0, 0),
                        };

                        var ptr = ir.LLVMBuildInBoundsGEP2(self.builder, llty, ll_expr, @ptrCast(&indicies), @intCast(indicies.len), @as(cstr, ""));
                        ptr = ir.LLVMBuildLoad2(self.builder, ir.LLVMPointerTypeInContext(self.context, 0), ptr, @as(cstr, ""));

                        // @TODO: bounds checking
                        var next_indicies = [_]ir.LLVMValueRef{
                            value,
                        };
                        ptr = ir.LLVMBuildInBoundsGEP2(self.builder, base_ty, ptr, @ptrCast(&next_indicies), @intCast(next_indicies.len), @as(cstr, ""));

                        if (self.make_ref) {
                            break :blk ptr;
                        } else {
                            const ll_base = try self.genType(slc_ty.base, .{});
                            break :blk ir.LLVMBuildLoad2(self.builder, ll_base, ptr, @as(cstr, ""));
                        }
                    },
                    else => @panic("Unimplemnted type for subscirpt"),
                }
            },
            .if_expr => |expr| {
                const func = if (self.current_function) |*func| func else @panic("Expected function!!");
                const old_cf = func.control_flow_terminated;
                defer func.control_flow_terminated = old_cf;
                func.control_flow_terminated = false;

                const cond_value = try self.genInstr(expr.cond) orelse @panic("Unable to get ifexpr");

                const true_block = ir.LLVMAppendBasicBlockInContext(self.context, func.llvm_val, @as(cstr, "if.then"));
                const false_block = if (expr.false_block) |_| ir.LLVMAppendBasicBlockInContext(self.context, func.llvm_val, @as(cstr, "if.else")) else null;
                const done_block = ir.LLVMAppendBasicBlockInContext(self.context, func.llvm_val, @as(cstr, "if.done"));

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
                const loop_block = ir.LLVMAppendBasicBlockInContext(self.context, func.llvm_val, @as(cstr, "loop.loop"));
                const done_block = ir.LLVMAppendBasicBlockInContext(self.context, func.llvm_val, @as(cstr, "loop.done"));

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

                const llty = try self.genType(base_ty, .{});
                const llarrty = ir.LLVMArrayType2(llty, node_ty.array.size);
                var is_const: bool = true;

                {
                    // Generate init values and mark if they are constant.
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
                        const value = try self.genWithRef(false, genInstr, .{ self, item_id }) orelse @panic("Unable to gen llvm value");
                        if (ir.LLVMIsConstant(value) == 0) is_const = false;
                        try ll_vals.append(value);
                    }
                }

                if (is_const) {
                    // @TODO: do non const arrays
                    const arr_value = ir.LLVMConstArray2(llty, ll_vals.items.ptr, ll_vals.items.len);
                    const global_value = ir.LLVMAddGlobal(self.module, llarrty, @as(cstr, ""));
                    ir.LLVMSetGlobalConstant(global_value, 1);
                    ir.LLVMSetInitializer(global_value, arr_value);
                    // ir.LLVMSetAlignment(global_value, 8);
                    ir.LLVMSetLinkage(global_value, ir.LLVMPrivateLinkage);
                    ir.LLVMSetUnnamedAddr(global_value, 1);

                    if (!self.make_ref) {
                        const size = ir.LLVMStoreSizeOfType(self.target_data, llarrty);
                        self.store_op = .{ .memcpy = size };
                    }

                    break :blk global_value;
                } else {
                    // If we're binding straight to an array, use that ptr. Otherwise, create new alloca
                    const alloca = if (self.alloca_hint != null and self.ty_hint != null and self.ty_hint.?.* == .array)
                        self.alloca_hint.?
                    else blk1: {
                        const cfunc = self.current_function.?;

                        const current_block = ir.LLVMGetInsertBlock(self.builder);
                        ir.LLVMPositionBuilderAtEnd(self.builder, cfunc.alloc_block);
                        const alloc_value = ir.LLVMBuildAlloca(self.builder, llarrty, @as(cstr, "arr_tmp"));
                        ir.LLVMPositionBuilderAtEnd(self.builder, current_block);

                        break :blk1 alloc_value;
                    };

                    for (ll_vals.items, 0..) |item, i| {
                        var indicies = [_]ir.LLVMValueRef{
                            ir.LLVMConstInt(ir.LLVMInt64TypeInContext(self.context), i, 0),
                        };

                        const ptr = ir.LLVMBuildInBoundsGEP2(self.builder, llty, alloca, @ptrCast(&indicies), @intCast(indicies.len), @as(cstr, ""));
                        _ = ir.LLVMBuildStore(self.builder, item, ptr);
                    }

                    if (self.alloca_hint != null and self.ty_hint != null and self.ty_hint.?.* == .array)
                        self.store_op = .none;

                    break :blk alloca;
                }
            },
            .reference => |ref| blk: {
                const this_node = self.evaluator.instr_to_node.get(instr_id) orelse @panic("Unable to get instrid for reference");
                const this_ty = self.typechecker.types.get(this_node) orelse @panic("Unable to get type for reference");

                const base_node = self.evaluator.instr_to_node.get(ref.expr) orelse @panic("Unable to get instrid for reference base");
                const base_ty = self.typechecker.types.get(base_node) orelse @panic("Unable to get type for reference base");

                const value = try self.genWithRef(true, genInstr, .{ self, ref.expr }) orelse @panic("invalid ref value");

                if (this_ty.* == .slice and base_ty.* == .array) {
                    const llty = try self.genType(this_ty, .{});
                    const alloca_val = if (self.alloca_hint) |a| a else blk1: {
                        const cfunc = self.current_function.?;

                        const current_block = ir.LLVMGetInsertBlock(self.builder);
                        ir.LLVMPositionBuilderAtEnd(self.builder, cfunc.alloc_block);
                        const alloc_value = ir.LLVMBuildAlloca(self.builder, llty, @as(cstr, "gennnnn"));
                        ir.LLVMPositionBuilderAtEnd(self.builder, current_block);

                        break :blk1 alloc_value;
                    };

                    var indicies = [_]ir.LLVMValueRef{
                        ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), 0, 0),
                        ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), 0, 0),
                    };

                    var ll_ptr = ir.LLVMBuildInBoundsGEP2(self.builder, llty, alloca_val, @ptrCast(&indicies), @intCast(indicies.len), @as(cstr, ""));
                    _ = ir.LLVMBuildStore(self.builder, value, ll_ptr);

                    indicies[1] = ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), 1, 0);
                    ll_ptr = ir.LLVMBuildInBoundsGEP2(self.builder, llty, alloca_val, @ptrCast(&indicies), @intCast(indicies.len), @as(cstr, ""));
                    const size_value = ir.LLVMConstInt(self.ptrSizedInt(), base_ty.array.size, 0);
                    _ = ir.LLVMBuildStore(self.builder, size_value, ll_ptr);

                    if (self.alloca_hint != null) {
                        self.store_op = .none;
                    }
                    if (!self.make_ref and self.store_op != .none) {
                        return ir.LLVMBuildLoad2(self.builder, llty, alloca_val, @as(cstr, "arr_init_load"));
                    }

                    return alloca_val;
                }

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
                const llvm_ty = try self.genType(node_ty, .{});

                break :blk ir.LLVMBuildLoad2(self.builder, llvm_ty, value, @as(cstr, ""));
            },
            .record_init => |ri| blk: {
                const node_id = self.evaluator.instr_to_node.get(instr_id) orelse @panic("Unable to get node id of invoke");
                const ref_node = self.analyzer.node_ref.get(node_id) orelse @panic("Unable tog et node ref");
                const node_ty = self.typechecker.types.get(node_id) orelse @panic("Unable to get node type");

                const record_ty = self.typechecker.declared_types.get(node_ty.named).?.owned_type.base.record;
                const fields_index = record_ty.fields.multi_type_keyed_impl;
                const fields = &self.typechecker.interner.multi_types_keyed.items[fields_index];

                var ll_vals = std.ArrayList(ir.LLVMValueRef).init(self.arena);
                try ll_vals.ensureTotalCapacity(fields.count());

                const ll_structty = self.type_map.get(ref_node) orelse @panic("Unable to get type");
                var is_const: bool = true;

                {
                    // Generate init values and mark if they are constant.
                    const old_ty_hint = self.ty_hint;
                    const old_llvm_ty_hint = self.llvm_ty_hint;
                    defer {
                        self.ty_hint = old_ty_hint;
                        self.llvm_ty_hint = old_llvm_ty_hint;
                    }

                    const item_nodes = self.instrRange(ri.exprs);
                    for (item_nodes, fields.values()) |item_id, field| {
                        self.ty_hint = field;
                        self.llvm_ty_hint = try self.genType(field, .{});

                        const value = try self.genWithRef(false, genInstr, .{ self, item_id }) orelse @panic("Unable to gen llvm value");
                        if (ir.LLVMIsConstant(value) == 0) is_const = false;
                        try ll_vals.append(value);
                    }
                }

                if (is_const) {
                    const rec_value = ir.LLVMConstNamedStruct(ll_structty, ll_vals.items.ptr, @intCast(ll_vals.items.len));
                    const global_value = ir.LLVMAddGlobal(self.module, ll_structty, @as(cstr, ""));
                    ir.LLVMSetGlobalConstant(global_value, 1);
                    ir.LLVMSetInitializer(global_value, rec_value);
                    // ir.LLVMSetAlignment(global_value, 8);
                    ir.LLVMSetLinkage(global_value, ir.LLVMPrivateLinkage);
                    ir.LLVMSetUnnamedAddr(global_value, 1);

                    if (!self.make_ref) {
                        const size = ir.LLVMStoreSizeOfType(self.target_data, ll_structty);
                        self.store_op = .{ .memcpy = size };
                    }

                    break :blk global_value;
                } else {
                    const alloca = if (self.alloca_hint != null and self.ty_hint != null and self.ty_hint.?.* == .record)
                        self.alloca_hint.?
                    else blk1: {
                        const cfunc = self.current_function.?;

                        const current_block = ir.LLVMGetInsertBlock(self.builder);
                        ir.LLVMPositionBuilderAtEnd(self.builder, cfunc.alloc_block);
                        const alloc_value = ir.LLVMBuildAlloca(self.builder, ll_structty, @as(cstr, "rec_tmp"));
                        ir.LLVMPositionBuilderAtEnd(self.builder, current_block);

                        break :blk1 alloc_value;
                    };

                    for (ll_vals.items, 0..) |item, i| {
                        var indicies = [_]ir.LLVMValueRef{
                            ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), i, 0),
                            ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), i, 0),
                        };

                        const ptr = ir.LLVMBuildInBoundsGEP2(self.builder, ll_structty, alloca, @ptrCast(&indicies), @intCast(indicies.len), @as(cstr, ""));
                        _ = ir.LLVMBuildStore(self.builder, item, ptr);
                    }

                    if (self.alloca_hint != null and self.ty_hint != null and self.ty_hint.?.* == .record)
                        self.store_op = .none;

                    break :blk alloca;
                }
            },
            .member_access => |acc| blk: {
                var ll_expr = try self.genWithRef(true, genInstr, .{ self, acc.expr }) orelse @panic("Unable to get base for fiels access!");

                const expr_node = self.evaluator.instr_to_node.get(acc.expr) orelse @panic("Unable to get lhs node");
                var expr_ty = self.typechecker.types.get(expr_node).?;

                while (expr_ty.* == .reference) {
                    const llty_tmp = try self.genType(expr_ty, .{});
                    ll_expr = ir.LLVMBuildLoad2(self.builder, llty_tmp, ll_expr, @as(cstr, ""));
                    expr_ty = expr_ty.reference.base;
                }

                while (expr_ty.* == .named) {
                    expr_ty = self.typechecker.declared_types.get(expr_ty.named).?.owned_type.base;
                }

                while (expr_ty.* == .reference) {
                    const llty_tmp = try self.genType(expr_ty, .{});
                    ll_expr = ir.LLVMBuildLoad2(self.builder, llty_tmp, ll_expr, @as(cstr, ""));
                    expr_ty = expr_ty.reference.base;
                }

                const ll_basety = try self.genType(expr_ty, .{});

                switch (expr_ty.*) {
                    .record => |_| {
                        var indicies = [_]ir.LLVMValueRef{
                            ir.LLVMConstInt(ir.LLVMInt64TypeInContext(self.context), 0, 0),
                            ir.LLVMConstInt(ir.LLVMInt32TypeInContext(self.context), acc.index, 0),
                        };

                        const ptr = ir.LLVMBuildInBoundsGEP2(self.builder, ll_basety, ll_expr, @ptrCast(&indicies), @intCast(indicies.len), @as(cstr, ""));

                        if (self.make_ref) {
                            break :blk ptr;
                        } else {
                            const this_node = self.evaluator.instr_to_node.get(instr_id).?;
                            const out_ty = self.typechecker.types.get(this_node).?;

                            const llty = try self.genType(out_ty, .{});

                            break :blk ir.LLVMBuildLoad2(self.builder, llty, ptr, @as(cstr, ""));
                        }
                    },
                    else => @panic("Unimplemetned"),
                }
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
        const llty = try self.genType(ty, .{});
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

    pub inline fn ptrSizedInt(self: *const Self) ir.LLVMTypeRef {
        return ir.LLVMIntPtrTypeInContext(self.context, self.target_data);
    }

    fn paramWillBeIndirect(self: *const Self, ty: typecheck.Type) bool {
        var base = ty;
        while (base.* == .named) {
            base = self.typechecker.declared_types.get(base.named).?.owned_type.base;
        }
        return switch (base.*) {
            .array => true,
            .record => true,
            else => false,
        };
    }

    // pub fn genRecord(self: *self,ty: typecheck.Type) !ir.LLVMTypeRef {

    // }

    pub fn genType(
        self: *Self,
        ty: typecheck.Type,
        options: struct {
            param: bool = false,
            indirect_param: ?*bool = null,
            named_struct: ?ir.LLVMTypeRef = null,
        },
    ) !ir.LLVMTypeRef {
        const llty = switch (ty.*) {
            .int, .uint => |size| ir.LLVMIntTypeInContext(self.context, @intCast(size)),
            .int_literal => ir.LLVMInt64TypeInContext(self.context),
            .boolean => ir.LLVMInt1TypeInContext(self.context),
            .float => |size| switch (size) {
                16 => ir.LLVMHalfTypeInContext(self.context),
                32 => ir.LLVMFloatTypeInContext(self.context),
                64 => ir.LLVMDoubleTypeInContext(self.context),
                128 => ir.LLVMFP128TypeInContext(self.context),
                else => std.debug.panic("Unsupported float size {}", .{size}),
            },
            .array => |arr_ty| blk: {
                const ll_base = try self.genType(arr_ty.base, .{});
                const aty = ir.LLVMArrayType2(ll_base, arr_ty.size);
                if (options.param) {
                    if (options.indirect_param) |indirect| {
                        indirect.* = true;
                    }

                    break :blk ir.LLVMPointerTypeInContext(self.context, 0);
                } else {
                    break :blk aty;
                }
            },
            .slice => |slc_ty| blk: {
                const ll_base = try self.genType(slc_ty.base, .{});
                var ll_element_tys = [2]ir.LLVMTypeRef{
                    ir.LLVMPointerType(ll_base, 0),
                    ir.LLVMIntPtrType(self.target_data),
                };
                const ll_slice_ty = ir.LLVMStructTypeInContext(self.context, &ll_element_tys, ll_element_tys.len, 0);

                break :blk ll_slice_ty;
            },
            .reference => |_| blk: {
                // const ll_base = try self.genType(ref.base, .{});
                break :blk ir.LLVMPointerTypeInContext(self.context, 0);
            },
            .func => |fn_ty| blk: {
                var llvm_param_tys = std.ArrayList(ir.LLVMTypeRef).init(self.arena);
                const param_index_tys = fn_ty.params.*.multi_type_impl;
                const param_tys = self.typechecker.interner.multi_types.items[param_index_tys.start .. param_index_tys.start + param_index_tys.len];
                try self.param_info.ensureTotalCapacity(param_tys.len);
                try llvm_param_tys.ensureTotalCapacity(param_tys.len);
                self.param_info.items.len = 0;

                for (param_tys, 0..) |pty, i| {
                    var indirect = self.paramWillBeIndirect(pty);
                    if (indirect) {
                        try llvm_param_tys.append(ir.LLVMPointerTypeInContext(self.context, 0));
                    } else {
                        try llvm_param_tys.append(try self.genType(pty, .{ .param = true, .indirect_param = &indirect }));
                    }

                    try self.param_info.append(.{
                        .index = i,
                        .indirect = indirect,
                    });
                }

                const ret_ty = if (fn_ty.ret_ty) |rty| try self.genType(rty, .{}) else ir.LLVMVoidTypeInContext(self.context);

                break :blk ir.LLVMFunctionType(
                    ret_ty,
                    llvm_param_tys.items.ptr,
                    @intCast(llvm_param_tys.items.len),
                    0,
                );
            },
            .record => |rec| blk: {
                if (options.param) {
                    if (options.indirect_param) |indirect| {
                        indirect.* = true;
                    }

                    break :blk ir.LLVMPointerTypeInContext(self.context, 0);
                }

                var llvm_field_tys = std.ArrayList(ir.LLVMTypeRef).init(self.arena);
                const field_index_tys = rec.fields.*.multi_type_keyed_impl;
                const field_tys = &self.typechecker.interner.multi_types_keyed.items[field_index_tys];

                try llvm_field_tys.ensureTotalCapacity(field_tys.count());
                // self.param_info.items.len = 0;

                var field_it = field_tys.iterator();
                while (field_it.next()) |fty| {
                    try llvm_field_tys.append(try self.genType(fty.value_ptr.*, .{}));
                }

                if (options.named_struct) |ns| {
                    ir.LLVMStructSetBody(
                        ns,
                        llvm_field_tys.items.ptr,
                        @intCast(llvm_field_tys.items.len),
                        0,
                    );

                    break :blk ir.LLVMVoidTypeInContext(self.context);
                } else {
                    break :blk ir.LLVMStructTypeInContext(
                        self.context,
                        llvm_field_tys.items.ptr,
                        @intCast(llvm_field_tys.items.len),
                        0,
                    );
                }
            },
            .named => |id| self.type_map.get(id).?,

            else => std.debug.panic("Unknown type! {}", .{ty.*}),
        };

        return llty;
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
