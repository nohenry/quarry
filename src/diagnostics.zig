const std = @import("std");
const node = @import("node.zig");
const tokenize = @import("tokenize.zig");

pub const Level = enum {
    info,
    warning,
    err,
};

pub const Diagnostic = struct {
    msg: []const u8,
    level: Level = .err,
    from: tokenize.TokenId,
    to: ?tokenize.TokenId = null,
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),
    nodes: []const node.Node,
    node_tokens: []const node.NodeTokens,

    const Self = @This();

    pub fn init(nodes: []const node.Node, node_tokens: []const node.NodeTokens, arena: std.mem.Allocator) Self {
        return .{
            .arena = arena,
            .nodes = nodes,
            .node_tokens = node_tokens,
            .diagnostics = std.ArrayList(Diagnostic).init(arena),
        };
    }

    pub fn allGood(self: *const Self) bool {
        return self.diagnostics.items.len == 0;
    }

    pub fn beginEnd(self: *const Self, node_id: node.NodeId) struct { tokenize.TokenId, tokenize.TokenId } {
        const node_val = &self.nodes[node_id.index];
        const tok = &self.node_tokens[node_id.index];

        return switch (node_val.kind) {
            .identifier, .int_literal, .float_literal, .string_literal => .{ tok.single, tok.single },
            .binding => |v| blk: {
                const start_tok = if (v.ty) |ty| self.beginEnd(ty)[0] else tok.binding.let_tok.?;
                const end_tok = self.beginEnd(v.value)[1];

                break :blk .{ start_tok, end_tok };
            },
            .binary_expr => |v| blk: {
                const start_tok = self.beginEnd(v.left)[0];
                const end_tok = self.beginEnd(v.right)[1];

                break :blk .{ start_tok, end_tok };
            },
            .unary_expr => |v| blk: {
                const start_tok = tok.single;
                const end_tok = self.beginEnd(v.expr)[1];

                break :blk .{ start_tok, end_tok };
            },
            .key_value => |v| blk: {
                const start_tok = self.beginEnd(v.key)[0];
                const end_tok = self.beginEnd(v.value)[1];

                break :blk .{ start_tok, end_tok };
            },
            .key_value_ident => |v| blk: {
                const start_tok = tok.key_value_ident.name_tok;
                const end_tok = self.beginEnd(v.value)[1];

                break :blk .{ start_tok, end_tok };
            },
            .argument => |v| blk: {
                break :blk self.beginEnd(v);
            },
            .parameter => |v| blk: {
                const start_tok = self.beginEnd(v.ty)[0];
                const end_tok = if (v.default) |def| self.beginEnd(def)[1] else tok.parameter.name_tok;

                break :blk .{ start_tok, end_tok };
            },
            .func, .func_no_params => blk: {
                const start_tok = tok.func.open_paren_tok;
                const end_tok = tok.func.close_brace_tok;

                break :blk .{ start_tok, end_tok };
            },
            .invoke => |v| blk: {
                const start_tok = self.beginEnd(v.expr)[0];
                const end_tok = tok.invoke.close_paren_tok;

                break :blk .{ start_tok, end_tok };
            },
            .subscript => |v| blk: {
                const start_tok = self.beginEnd(v.expr)[0];
                const end_tok = tok.subscript.close_bracket_tok;

                break :blk .{ start_tok, end_tok };
            },
            .if_expr => |_| blk: {
                const start_tok = tok.if_expr.if_tok;
                const end_tok = tok.if_expr.else_close_brace_tok orelse tok.if_expr.close_brace_tok;

                break :blk .{ start_tok, end_tok };
            },
            .loop => |_| blk: {
                const start_tok = tok.loop.loop_tok;
                const end_tok = tok.loop.else_close_brace_tok orelse
                    tok.loop.finally_close_brace_tok orelse
                    tok.loop.close_brace_tok;

                break :blk .{ start_tok, end_tok };
            },
            .reference => |v| blk: {
                const start_tok = self.beginEnd(v.expr)[0];
                const end_tok = tok.single;

                break :blk .{ start_tok, end_tok };
            },
            .dereference => |v| blk: {
                const start_tok = self.beginEnd(v.expr)[0];
                const end_tok = tok.single;

                break :blk .{ start_tok, end_tok };
            },
            .const_expr => |v| blk: {
                const start_tok = tok.single;
                const end_tok = self.beginEnd(v.expr)[1];

                break :blk .{ start_tok, end_tok };
            },
            .const_block => |_| blk: {
                const start_tok = tok.const_block.const_tok;
                const end_tok = tok.const_block.close_brace_tok;

                break :blk .{ start_tok, end_tok };
            },
            .array_init_or_slice_one => |_| blk: {
                const start_tok = tok.array_init_or_slice_one.open_bracket_tok;
                const end_tok = tok.array_init_or_slice_one.close_bracket_tok;

                break :blk .{ start_tok, end_tok };
            },
            .array_init => |_| blk: {
                const start_tok = tok.array_init.open_bracket_tok;
                const end_tok = tok.array_init.close_bracket_tok;

                break :blk .{ start_tok, end_tok };
            },
            .type_alias => |v| blk: {
                const start_tok = tok.single;
                const end_tok = self.beginEnd(v)[1];

                break :blk .{ start_tok, end_tok };
            },
            .type_ref => |v| blk: {
                const start_tok = self.beginEnd(v.ty)[0];
                const end_tok = tok.type_ref.ref_tok;

                break :blk .{ start_tok, end_tok };
            },
            .type_opt => |v| blk: {
                const start_tok = self.beginEnd(v.ty)[0];
                const end_tok = tok.single;

                break :blk .{ start_tok, end_tok };
            },
            .type_int, .type_uint, .type_float, .type_bool => blk: {
                break :blk .{ tok.single, tok.single };
            },

            else => @panic("Unimplemtned"),
        };
        // return switch (tok.*) {
        //     .single => |s| .{ s, null },
        //     .binding => |v| .{ v.mut_tok orelse v.name_tok, v.eq_tok },
        //     .parameter => |v| .{ v.spread_tok orelse v.name_tok, v.eq_tok orelse v.name_tok },
        //     .key_value_ident => |v| .{ v.name_tok, v.colon_tok },
        //     .func => |v| .{ v.open_paren_tok, v.close_brace_tok },
        //     .invoke => |v| .{ v.open_paren_tok, v.close_paren_tok },
        //     .subscript => |v| .{ v.open_bracket_tok, v.close_bracket_tok },
        //     .if_expr => |v| .{ v.if_tok, v.else_close_brace_tok orelse v.close_brace_tok },
        //     .loop => |v| .{ v.loop_tok, v.finally_close_brace_tok orelse v.else_close_brace_tok orelse v.close_brace_tok },
        //     .const_block => |v| .{ v.const_tok, v.close_brace_tok },
        //     .array_init_or_slice_one => |v| .{ v.open_bracket_tok, v.close_bracket_tok },
        //     .array_init => |v| .{ v.open_bracket_tok, v.close_bracket_tok },
        //     .type_record => |v| .{ v.ty_tok, v.close_bracket_tok },
        //     .record_field => |v| .{ v.name_tok, v.eq_tok },
        //     .type_union => |v| .{ v.ty_tok, v.close_paren_tok },
        //     .union_variant => |v| .{ v.pipe_tok, v.tok },
        //     .type_ref => |v| .{ v.tok, v.tok },
        // };
    }

    pub fn addErr(
        self: *Self,
        from: anytype,
        comptime format: []const u8,
        args: anytype,
        config: struct {
            to: ?@TypeOf(from) = null,
        },
    ) void {
        var buf = std.ArrayList(u8).init(self.arena);
        var buf_writer = buf.writer();
        buf_writer.print(format, args) catch @panic("Memory allocation failed");

        if (@TypeOf(from) == node.NodeId) {
            const begin = self.beginEnd(from);
            const end = if (config.to) |t| self.beginEnd(t)[1] else null;

            self.diagnostics.append(.{
                .msg = buf.items,
                .level = .err,
                .from = begin[0],
                .to = end orelse begin[1],
            }) catch @panic("Unable to apend diagonstic");
        } else if (@TypeOf(from) == tokenize.TokenId) {
            self.diagnostics.append(.{
                .msg = buf.items,
                .level = .err,
                .from = from,
                .to = config.to,
            }) catch @panic("Unable to apend diagonstic");
        } else if (@TypeOf(from) == tokenize.TokenId) {} else {
            @compileError("Invalid from token provided");
        }
    }

    pub fn addInfo(
        self: *Self,
        from: anytype,
        comptime format: []const u8,
        args: anytype,
        config: struct {
            to: ?@TypeOf(from) = null,
        },
    ) void {
        var buf = std.ArrayList(u8).init(self.arena);
        var buf_writer = buf.writer();
        buf_writer.print(format, args) catch @panic("Memory allocation failed");

        if (@TypeOf(from) == node.NodeId) {
            const begin = self.beginEnd(from);
            const end = if (config.to) |t| self.beginEnd(t)[1] else null;

            self.diagnostics.append(.{
                .msg = buf.items,
                .level = .info,
                .from = begin[0],
                .to = end orelse begin[1],
            }) catch @panic("Unable to apend diagonstic");
        } else if (@TypeOf(from) == tokenize.TokenId) {
            self.diagnostics.append(.{
                .msg = buf.items,
                .level = .info,
                .from = from,
                .to = config.to,
            }) catch @panic("Unable to apend diagonstic");
        } else if (@TypeOf(from) == tokenize.TokenId) {} else {
            @compileError("Invalid from token provided");
        }
    }

    pub fn dump(
        self: *const Self,
        src_info: *tokenize.SourceInfo,
    ) void {
        for (self.diagnostics.items) |diag| {
            const line_range = src_info.lineRangeAt(src_info.token_info[diag.from].position);
            switch (diag.level) {
                .err => std.debug.print("\x1b[1;31merror\x1b[0m", .{}),
                .warning => std.debug.print("\x1b[1;33mwarning\x1b[0m", .{}),
                .info => std.debug.print("\x1b[1;36minfo\x1b[0m", .{}),
            }

            const line_no = src_info.token_info[diag.from].line + 1;
            std.debug.print(": line {} => {s}\n\x1b[2m{}:\x1b[0m", .{ line_no, diag.msg, line_no });
            src_info.printRange(line_range[0], line_range[1]);
            std.debug.print("\n\n", .{});
        }
    }
};
