const std = @import("std");
const node = @import("node.zig");
const tokenize = @import("tokenize.zig");

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEnd,
    UnexpectedGarbage,
} || std.mem.Allocator.Error;

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,
    lexer: *tokenize.Lexer,

    nodes: std.ArrayList(node.Node),
    node_tokens: std.ArrayList(node.NodeTokens),
    node_ranges: std.ArrayList(node.NodeId),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, lexer: *tokenize.Lexer) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .lexer = lexer,

            .nodes = std.ArrayList(node.Node).init(allocator),
            .node_tokens = std.ArrayList(node.NodeTokens).init(allocator),
            .node_ranges = std.ArrayList(node.NodeId).init(allocator),
        };
    }

    pub fn parse(self: *Self) ![]const node.NodeId {
        var these_nodes = std.ArrayList(node.NodeId).init(self.arena.allocator());
        defer self.arena.deinit();

        var last: ?usize = null;
        self.consumeNL();

        while (self.lexer.hasNext()) {
            if (last != null and last.? == self.lexer.position) {
                return error.UnexpectedGarbage;
            }

            last = self.lexer.position;
            const item = try self.parseItem();
            try these_nodes.append(item);

            self.consumeNL();
        }
        const start = self.node_ranges.items.len;
        try self.node_ranges.appendSlice(these_nodes.items);

        return self.node_ranges.items[start..];
    }

    pub fn parseBraceBlock(self: *Self) !struct { node.NodeRange, tokenize.TokenId, tokenize.TokenId } {
        const ob_tok = try self.expect(.open_brace);
        var cb_tok = self.consumeIfIs(.close_brace);
        if (cb_tok) |tok| {
            return .{ node.NodeRange{
                .start = @truncate(self.node_ranges.items.len),
                .len = 0,
            }, ob_tok[0], tok };
        }
        const block = try self.parseBlock();
        cb_tok = (try self.expect(.close_brace))[0];

        return .{ block, ob_tok[0], cb_tok.? };
    }

    pub fn parseBlock(self: *Self) !node.NodeRange {
        var these_nodes = std.ArrayList(node.NodeId).init(self.arena.allocator());

        var last: ?usize = null;
        self.consumeNL();

        var tok = self.peek();
        while (tok != null) : (tok = self.peek()) {
            if (tok.?.kind == .close_brace) {
                break;
            } else if (last != null and last.? == self.lexer.position) {
                break;
            }

            last = self.lexer.position;
            const item = try self.parseItem();
            try these_nodes.append(item);

            self.consumeNL();
        }
        const starti = self.node_ranges.items.len;
        try self.node_ranges.appendSlice(these_nodes.items);

        return .{
            .start = @truncate(starti),
            .len = @truncate(self.node_ranges.items.len - starti),
        };
    }

    pub fn parseItem(self: *Self) !node.NodeId {
        const tok = self.peek() orelse return error.UnexpectedEnd;

        return switch (tok.kind) {
            .let => self.parseBinding(),
            .@"extern" => self.parseBinding(),
            .@"export" => self.parseBinding(),
            .public => self.parseBinding(),
            else => blk: {
                const expr = try self.parseExpr();

                for (self.nodes.items) |nodei| {
                    nodei.print();
                }

                self.nodes.items[expr.index].print();
                if (self.nextIsNoNL(.identifier)) {
                    self.lexer.resync();
                }

                break :blk if (self.nextIsNoNL(.identifier) or self.nextIsNoNL(.mut))
                    self.parseBindingWithType(expr, null, .{})
                else
                    expr;
            },
        };
    }

    pub fn parseBinding(self: *Self) !node.NodeId {
        const public_tok = self.consumeIfIs(.public);
        const extern_tok = self.consumeIfIs(.@"extern");
        const export_tok = self.consumeIfIs(.@"export");

        const let_tok = self.consumeIfIs(.let);
        const ty = if (let_tok == null)
            try self.parseExpr()
        else
            null;

        return self.parseBindingWithType(ty, let_tok, .{
            .pub_tok = public_tok,
            .extern_tok = extern_tok,
            .export_tok = export_tok,
        });
    }

    pub fn parseBindingWithType(
        self: *Self,
        ty_node_id: ?node.NodeId,
        let_tok: ?tokenize.TokenId,
        modifiers: struct {
            pub_tok: ?tokenize.TokenId = null,
            export_tok: ?tokenize.TokenId = null,
            extern_tok: ?tokenize.TokenId = null,
        },
    ) !node.NodeId {
        const mutable = self.consumeIfIs(.mut);
        const name = try self.expect(.identifier);
        const eq = try self.expect(.assign);
        const expr = try self.parseExpr();
        var tags = node.SymbolTag.Tag.initEmpty();
        tags.setValue(node.SymbolTag.public, modifiers.pub_tok != null);
        tags.setValue(node.SymbolTag.exported, modifiers.export_tok != null);
        tags.setValue(node.SymbolTag.external, modifiers.extern_tok != null);

        return self.createNode(.{
            .binding = .{
                .name = name[1],
                .ty = ty_node_id,
                .mutable = mutable != null,
                .tags = tags,
                .value = expr,
            },
        }, .{
            .binding = .{
                .public_tok = modifiers.pub_tok,
                .export_tok = modifiers.export_tok,
                .extern_tok = modifiers.extern_tok,
                .let_tok = let_tok,
                .mut_tok = mutable,
                .name_tok = name[0],
                .eq_tok = eq[0],
            },
        });
    }

    pub fn parseExpr(self: *Self) ParseError!node.NodeId {
        return try self.parseBinExpr(0);
    }

    pub fn parseBinExpr(self: *Self, last_prec: u8) ParseError!node.NodeId {
        return self.parseBinExprWithLeft(try self.parsePrimaryExpr(), last_prec);
    }

    pub fn parseBinExprWithLeft(self: *Self, left_id: node.NodeId, last_prec: u8) ParseError!node.NodeId {
        var left = left_id;
        // var next_last_prec = last_prec;

        while (true) {
            left = try self.parsePostExpr(last_prec, left);

            const op_tok = self.lexer.peek() orelse break;
            const op = node.Operator.fromTokenKind(op_tok.kind) orelse break;

            const prec = binaryPrec(op);
            if (prec == 0 or prec < last_prec) break;
            const op_final_tok = self.lexer.next();

            const right = try self.parseBinExpr(prec);

            left = try self.createNode(.{
                .binary_expr = .{
                    .left = left,
                    .op = op,
                    .right = right,
                },
            }, .{
                .single = op_final_tok.?.id,
            });
        }

        return left;
    }

    pub fn parsePostExpr(self: *Self, last_prec: u8, left_id: node.NodeId) !node.NodeId {
        var left = left_id;

        var tok = self.peekNoNL();
        while (tok != null) : (tok = self.peek()) {
            const op = node.Operator.fromTokenKind(tok.?.kind) orelse break;
            const prec = postPrec(op);
            if (prec == 0 or prec < last_prec) break;

            self.lexer.resync();
            tok = self.peekNoNL();

            switch (tok.?.kind) {
                .coloncolon => {
                    const col_tok = self.next().?;
                    std.log.warn("FGoing colon", .{});
                    const expr = try self.parseBinExpr(postPrec(op));

                    left = try self.createNode(.{
                        .variant_init = .{
                            .variant = left,
                            .init = expr,
                        },
                    }, .{ .single = col_tok.id });
                },
                .open_paren => {
                    // parseInvoke
                    const op_tok = self.next();
                    const first = if (!self.nextIs(.close_paren))
                        try self.parseArgument()
                    else
                        null;

                    const args = if (first) |expr|
                        try self.parseCommaSimpleFirst(expr, .close_paren, parseArgument)
                    else
                        node.NodeRange{
                            .start = @truncate(self.node_ranges.items.len),
                            .len = 0,
                        };

                    const cp_tok = try self.expect(.close_paren);

                    const trailing_block = if (self.nextIs(.open_brace))
                        try self.parseBraceBlock()
                    else
                        null;

                    left = try self.createNode(.{
                        .invoke = .{
                            .expr = left,
                            .args = args,
                            .trailing_block = if (trailing_block) |tb| tb[0] else null,
                        },
                    }, .{
                        .invoke = .{
                            .open_paren_tok = op_tok.?.id,
                            .close_paren_tok = cp_tok[0],
                        },
                    });
                },
                .open_bracket => {
                    // parseSubscript
                    const ob_tok = self.next();
                    const sub = try self.parseExpr();
                    const cb_tok = try self.expect(.close_bracket);

                    left = try self.createNode(.{
                        .subscript = .{
                            .expr = left,
                            .sub = sub,
                        },
                    }, .{
                        .subscript = .{
                            .open_bracket_tok = ob_tok.?.id,
                            .close_bracket_tok = cb_tok[0],
                        },
                    });
                },
                else => break,
            }
        }

        tok = self.peek();
        while (tok != null) : (tok = self.peek()) {
            const op = node.Operator.fromTokenKind(tok.?.kind) orelse break;
            const prec = postPrec(op);
            if (prec == 0 or prec < last_prec) break;

            switch (tok.?.kind) {
                .dot_ampersand => {
                    left = try self.createNodeAndNext(.{
                        .reference = .{
                            .expr = left,
                        },
                    });
                },
                .dot_star => {
                    left = try self.createNodeAndNext(.{
                        .dereference = .{
                            .expr = left,
                        },
                    });
                },
                else => break,
            }
        }

        tok = self.peek();
        while (tok != null) : (tok = self.peek()) {
            const op = node.Operator.fromTokenKind(tok.?.kind) orelse break;
            const prec = postPrec(op);
            if (prec == 0 or prec < last_prec) break;

            switch (tok.?.kind) {
                .mut => {
                    const mut_tok = self.next();
                    if (!self.nextIs(.ampersand)) {
                        self.lexer.resyncN(2);
                        break;
                    }
                    const ref_tok = try self.expect(.ampersand);

                    left = try self.createNode(.{
                        .type_ref = .{
                            .ty = left,
                            .mut = true,
                        },
                    }, .{
                        .type_ref = .{
                            .ref_tok = ref_tok[0],
                            .mut_tok = mut_tok.?.id,
                        },
                    });
                },
                .ampersand => {
                    left = try self.createNodeAndNext(.{
                        .type_ref = .{
                            .ty = left,
                            .mut = false,
                        },
                    });
                },
                .question => {
                    left = try self.createNodeAndNext(.{
                        .type_opt = .{ .ty = left },
                    });
                },
                else => break,
            }
        }
        return left;
    }

    pub fn parsePrimaryExpr(self: *Self) !node.NodeId {
        const tok = self.peek() orelse return error.UnexpectedEnd;
        switch (tok.kind) {
            .type => {
                const ty_tok = self.next();

                const op_tok = self.consumeIfIs(.open_paren);
                var cp_tok: ?tokenize.TokenId = null;

                const backing_field = if (op_tok != null) blk: {
                    const field = try self.parseExpr();
                    cp_tok = (try self.expect(.close_paren))[0];
                    break :blk field;
                } else null;

                if (self.consumeIfIs(.open_bracket)) |ob_tok| {
                    // parseRecord

                    if (self.consumeIfIs(.close_bracket)) |cb_tok| {
                        return self.createNode(.{
                            .type_record = .{
                                .backing_field = backing_field,
                                .fields = .{
                                    .start = @truncate(self.node_ranges.items.len),
                                    .len = 0,
                                },
                            },
                        }, .{
                            .type_record = .{
                                .ty_tok = ty_tok.?.id,
                                .open_paren_tok = op_tok,
                                .close_paren_tok = cp_tok,

                                .open_bracket_tok = ob_tok,
                                .close_bracket_tok = cb_tok,
                            },
                        });
                    }

                    const first = try self.parseRecordField();
                    const fields = try self.parseCommaSimpleFirst(first, .close_bracket, parseRecordField);
                    const cb_tok = try self.expect(.close_bracket);

                    return self.createNode(.{
                        .type_record = .{
                            .backing_field = backing_field,
                            .fields = fields,
                        },
                    }, .{
                        .type_record = .{
                            .ty_tok = ty_tok.?.id,

                            .open_paren_tok = op_tok,
                            .close_paren_tok = cp_tok,

                            .open_bracket_tok = ob_tok,
                            .close_bracket_tok = cb_tok[0],
                        },
                    });
                }

                const first_ty = try self.parseBinExpr(81);
                if (self.nextIs(.pipe) or self.nextIs(.identifier) or self.nextIs(.assign)) {
                    // parseUnion

                    const variant = try self.parseUnionVariantFirstExpr(first_ty, null);

                    var these_nodes = std.ArrayList(node.NodeId).init(self.arena.allocator());
                    try these_nodes.append(variant);

                    var pipe = self.peek();
                    while (pipe != null and pipe.?.kind == .pipe) : (pipe = self.peek()) {
                        const pipe_tok = self.next();
                        const next_variant = try self.parseUnionVariant(pipe_tok.?.id);
                        try these_nodes.append(next_variant);
                    }

                    const starti = self.node_ranges.items.len;
                    try self.node_ranges.appendSlice(these_nodes.items);

                    return self.createNode(.{
                        .type_union = .{
                            .backing_field = backing_field,
                            .variants = .{
                                .start = @truncate(starti),
                                .len = @truncate(self.node_ranges.items.len - starti),
                            },
                        },
                    }, .{
                        .type_union = .{
                            .ty_tok = ty_tok.?.id,

                            .open_paren_tok = op_tok,
                            .close_paren_tok = cp_tok,
                        },
                    });
                }

                return self.createNode(.{
                    .type_alias = first_ty,
                }, .{ .single = ty_tok.?.id });
            },
            .open_paren => {
                const op_tok = self.next();
                var cp_tok = self.consumeIfIs(.close_paren);
                const expr = if (cp_tok == null)
                    try self.parseExpr()
                else
                    null;

                cp_tok = self.consumeIfIs(.close_paren);
                if (expr != null and cp_tok != null) {
                    return expr.?;
                }
                // parseFunc
                if (expr != null and self.nextIs(.identifier) or self.nextIs(.spread)) {
                    const first_param = try self.parseParameterWithFirstType(expr.?);
                    const params = try self.parseCommaSimpleFirst(first_param, .close_paren, parseParameter);

                    const this_cp_tok = try self.expect(.close_paren);

                    return self.parseFuncWithParams(params, op_tok.?.id, this_cp_tok[0]);
                } else if (expr == null) {
                    return self.parseFuncWithParams(null, op_tok.?.id, cp_tok.?);
                }

                _ = try self.expect(.close_paren);

                return expr.?;
            },
            .open_bracket => {
                const ob_tok = self.next();

                // parseArrayInit
                // parseSliceType
                // parseArrayType

                const mut = self.consumeIfIs(.mut);
                const expr = try self.parseExpr();
                const colon_tok = self.consumeIfIs(.colon);

                const value = if (colon_tok != null)
                    try self.parseExpr()
                else
                    null;

                if (mut == null and self.nextIs(.comma)) {
                    var these_nodes = std.ArrayList(node.NodeId).init(self.arena.allocator());
                    if (value) |val| {
                        const next_expr = try self.createNode(.{
                            .key_value = .{
                                .key = expr,
                                .value = val,
                            },
                        }, .{ .single = colon_tok.? });

                        try these_nodes.append(next_expr);
                    } else {
                        try these_nodes.append(expr);
                    }

                    const is_record = value != null;

                    var comma = self.peek();
                    while (comma != null and comma.?.kind == .comma) : (comma = self.peek()) {
                        _ = self.next();
                        var next_expr = try self.parseExpr();

                        const nx_colon_tok = self.consumeIfIs(.colon);
                        if (nx_colon_tok) |nx_tok| {
                            const this_value = try self.parseExpr();
                            next_expr = try self.createNode(.{
                                .key_value = .{
                                    .key = next_expr,
                                    .value = this_value,
                                },
                            }, .{ .single = nx_tok });

                            if (!is_record) {
                                std.log.err("Expected record field but found single expression!", .{});
                            }
                        } else if (is_record) {
                            std.log.err("Expected single expression but found record field!", .{});
                        }

                        try these_nodes.append(next_expr);
                    }

                    const starti = self.node_ranges.items.len;
                    try self.node_ranges.appendSlice(these_nodes.items);

                    const cb_tok = try self.expect(.close_bracket);

                    return self.createNode(.{
                        .array_init = .{
                            .exprs = .{
                                .start = @truncate(starti),
                                .len = @truncate(self.node_ranges.items.len - starti),
                            },
                        },
                    }, .{
                        .array_init = .{
                            .open_bracket_tok = ob_tok.?.id,
                            .close_bracket_tok = cb_tok[0],
                        },
                    });
                }

                const cb_tok = try self.expect(.close_bracket);

                return self.createNode(.{
                    .array_init_or_slice_one = .{
                        .expr = expr,
                        .value = value,
                        .mut = mut != null,
                    },
                }, .{
                    .array_init_or_slice_one = .{
                        .mut_tok = mut,
                        .open_bracket_tok = ob_tok.?.id,
                        .close_bracket_tok = cb_tok[0],
                    },
                });
            },
            .@"if" => {
                // parseIf
                const if_tok = self.next();
                const cond = try self.parseExpr();

                const captures = if (self.consumeIfIs(.arrow) != null) blk1: {
                    _ = try self.expect(.open_paren);
                    const captures = if (!self.nextIs(.close_paren)) blk: {
                        const first = try self.parsePattern();
                        break :blk try self.parseCommaSimpleFirst(first, .close_paren, parsePattern);
                    } else null;

                    _ = try self.expect(.close_paren);
                    break :blk1 captures;
                } else null;

                const true_block = try self.parseBraceBlock();

                const else_tok = self.consumeIfIs(.@"else");
                const false_block = if (else_tok != null)
                    try self.parseBraceBlock()
                else
                    null;

                return self.createNode(.{
                    .if_expr = .{
                        .cond = cond,
                        .captures = captures,
                        .true_block = true_block[0],
                        .false_block = if (false_block) |fb| fb[0] else null,
                    },
                }, .{
                    .if_expr = .{
                        .if_tok = if_tok.?.id,
                        .open_brace_tok = true_block[1],
                        .close_brace_tok = true_block[2],

                        .else_tok = else_tok,
                        .else_open_brace_tok = if (false_block) |fb| fb[1] else null,
                        .else_close_brace_tok = if (false_block) |fb| fb[2] else null,
                    },
                });
            },
            .loop => {
                // parseLoop,
                const loop_tok = self.next();
                const expr = if (!self.nextIs(.open_brace))
                    try self.parseExpr()
                else
                    null;

                const captures = if (self.consumeIfIs(.arrow) != null) blk1: {
                    _ = try self.expect(.open_paren);
                    const captures = if (!self.nextIs(.close_paren)) blk: {
                        const first = try self.parsePattern();
                        break :blk try self.parseCommaSimpleFirst(first, .close_paren, parsePattern);
                    } else null;

                    _ = try self.expect(.close_paren);
                    break :blk1 captures;
                } else null;
                const loop_block = try self.parseBraceBlock();

                var finally_tok = self.consumeIfIs(.finally);
                const finally_block_pre = if (finally_tok != null)
                    try self.parseBraceBlock()
                else
                    null;

                const else_tok = self.consumeIfIs(.@"else");
                const else_block = if (else_tok != null)
                    try self.parseBraceBlock()
                else
                    null;

                if (finally_block_pre != null and else_block != null) {
                    std.log.err("Finally block should be after else block!", .{});
                }

                const finally_block = if (finally_block_pre) |blk|
                    blk
                else blk: {
                    finally_tok = self.consumeIfIs(.finally);

                    break :blk if (finally_tok != null)
                        try self.parseBraceBlock()
                    else
                        null;
                };

                return self.createNode(.{
                    .loop = .{
                        .expr = expr,
                        .captures = captures,

                        .loop_block = loop_block[0],
                        .else_block = if (else_block) |eb| eb[0] else null,
                        .finally_block = if (finally_block) |fb| fb[0] else null,
                    },
                }, .{
                    .loop = .{
                        .loop_tok = loop_tok.?.id,

                        .open_brace_tok = loop_block[1],
                        .close_brace_tok = loop_block[2],

                        .else_tok = else_tok,
                        .else_open_brace_tok = if (else_block) |eb| eb[1] else null,
                        .else_close_brace_tok = if (else_block) |eb| eb[2] else null,

                        .finally_tok = finally_tok,
                        .finally_open_brace_tok = if (finally_block) |fb| fb[1] else null,
                        .finally_close_brace_tok = if (finally_block) |fb| fb[2] else null,
                    },
                });
            },
            .@"const" => {
                const const_tok = self.next();
                if (self.nextIs(.open_brace)) {
                    const block = try self.parseBraceBlock();
                    return self.createNode(.{
                        .const_block = .{ .block = block[0] },
                    }, .{
                        .const_block = .{
                            .const_tok = const_tok.?.id,
                            .open_brace_tok = block[1],
                            .close_brace_tok = block[2],
                        },
                    });
                } else {
                    const expr = try self.parseExpr();
                    return self.createNode(.{
                        .const_expr = .{ .expr = expr },
                    }, .{ .single = const_tok.?.id });
                }
            },
            else => return self.parseLiteral(),
        }
    }

    pub fn parseFuncWithParams(
        self: *Self,
        params: ?node.NodeRange,
        op_tok: tokenize.TokenId,
        cp_tok: tokenize.TokenId,
    ) !node.NodeId {
        const ty = if (!self.nextIs(.open_brace))
            try self.parseExpr()
        else
            null;

        const ob_tok = self.consumeIfIs(.open_brace);
        var cb_tok = self.consumeIfIs(.close_brace);

        const block = if (cb_tok != null)
            node.NodeRange{ .start = @truncate(self.node_ranges.items.len), .len = 0 }
        else if (ob_tok != null) blk: {
            const block = try self.parseBlock();
            cb_tok = (try self.expect(.close_brace))[0];
            break :blk block;
        } else null;

        if (params) |pparams| {
            return self.createNode(.{
                .func = .{
                    .params = pparams,
                    .ret_ty = ty,
                    .block = block,
                },
            }, .{
                .func = .{
                    .open_paren_tok = op_tok,
                    .close_paren_tok = cp_tok,
                    .open_brace_tok = ob_tok,
                    .close_brace_tok = cb_tok,
                },
            });
        } else {
            return self.createNode(.{
                .func_no_params = .{
                    .ret_ty = ty,
                    .block = block,
                },
            }, .{
                .func = .{
                    .open_paren_tok = op_tok,
                    .close_paren_tok = cp_tok,
                    .open_brace_tok = ob_tok,
                    .close_brace_tok = cb_tok,
                },
            });
        }
    }

    pub fn parseRecordField(self: *Self) !node.NodeId {
        const ty = try self.parseExpr();
        const name = try self.expect(.identifier);

        const eq_tok = self.consumeIfIs(.assign);
        const default = if (eq_tok != null)
            try self.parseExpr()
        else
            null;

        return self.createNode(.{
            .record_field = .{
                .ty = ty,
                .name = name[1],
                .default = default,
            },
        }, .{
            .record_field = .{
                .name_tok = name[0],
                .eq_tok = eq_tok,
            },
        });
    }

    pub fn parseUnionVariant(self: *Self, pipe_tok: ?tokenize.TokenId) !node.NodeId {
        const first = try self.parseBinExpr(81);
        return self.parseUnionVariantFirstExpr(first, pipe_tok);
    }

    pub fn parseUnionVariantFirstExpr(self: *Self, _first: node.NodeId, pipe_tok: ?tokenize.TokenId) !node.NodeId {
        var first: ?node.NodeId = _first;
        const name = if (!self.hasNext() or self.nextIs(.pipe) or self.nextIs(.assign) or self.nextIsNoNLResync(.newline)) blk: {
            first = null;
            break :blk _first;
        } else try self.parseLiteral();

        const eq_tok = self.consumeIfIs(.assign);
        const index = if (eq_tok != null)
            try self.parseBinExpr(81)
        else
            null;

        return self.createNode(.{
            .union_variant = .{
                .ty = first,
                .name = name,
                .index = index,
            },
        }, .{
            .union_variant = .{
                .pipe_tok = pipe_tok,
                .eq_tok = eq_tok,
            },
        });
    }

    pub fn parseLiteral(self: *Self) !node.NodeId {
        const tok = self.peek() orelse return error.UnexpectedEnd;
        std.log.debug("Literal: {}", .{tok});

        return switch (tok.kind) {
            .dot => blk: {
                const dot_tok = self.next();
                const ident = try self.expect(.identifier);
                break :blk try self.createNode(.{
                    .implicit_variant = .{
                        .ident = ident[1],
                    },
                }, .{
                    .implicit_variant = .{
                        .dot_tok = dot_tok.?.id,
                        .ident_tok = ident[0],
                    },
                });
            },
            .star => blk: {
                const star_tok = self.next();
                const ident = try self.expect(.identifier);
                break :blk try self.createNode(.{
                    .type_wild = ident[1],
                }, .{
                    .type_wild = .{
                        .dot_tok = star_tok.?.id,
                        .ident_tok = ident[0],
                    },
                });
            },
            .int_literal => |value| self.createNodeAndNext(.{ .int_literal = value }),
            .float_literal => |value| self.createNodeAndNext(.{ .float_literal = value }),
            .bool_literal => |value| self.createNodeAndNext(.{ .bool_literal = value }),
            .string_literal => |value| self.createNodeAndNext(.{ .string_literal = value }),
            .identifier => |value| self.createNodeAndNext(.{ .identifier = value }),

            // Types
            .int => |size| self.createNodeAndNext(.{ .type_int = size }),
            .uint => |size| self.createNodeAndNext(.{ .type_uint = size }),
            .float => |size| self.createNodeAndNext(.{ .type_float = size }),
            .bool => self.createNodeAndNext(.type_bool),
            else => error.UnexpectedToken,
        };
    }

    pub fn parsePattern(self: *Self) !node.NodeId {
        const tok = self.peek() orelse return error.UnexpectedEnd;
        switch (tok.kind) {
            .identifier => |value| return self.createNodeAndNext(.{ .identifier = value }),
            else => return error.UnexpectedToken,
        }
    }

    pub fn parseArgument(self: *Self) !node.NodeId {
        const val = try self.parseKvOrExpr();
        if (self.nodes.items[val.index].kind != .key_value and self.nodes.items[val.index].kind != .key_value_ident) {
            const tok = self.node_tokens.items[val.index];
            return self.createNode(.{ .argument = val }, tok);
        }
        return val;
    }

    pub fn parseKvOrExpr(self: *Self) !node.NodeId {
        const first = try self.parseExpr();
        if (self.consumeIfIs(.colon)) |colon_tok| {
            if (self.nodes.items[first.index].kind == .identifier) {
                const key = self.nodes.items[first.index].kind.identifier;
                self.nodes.items.len -= 1;

                const value = try self.parseExpr();
                return self.createNode(.{
                    .key_value_ident = .{
                        .key = key,
                        .value = value,
                    },
                }, .{
                    .key_value_ident = .{
                        .name_tok = self.node_tokens.items[first.index].single,
                        .colon_tok = colon_tok,
                    },
                });
            }
            const value = try self.parseExpr();
            return self.createNode(.{
                .key_value = .{
                    .key = first,
                    .value = value,
                },
            }, .{ .single = colon_tok });
        }

        return first;
    }

    pub fn parseParameter(self: *Self) !node.NodeId {
        const ty = try self.parseExpr();
        return self.parseParameterWithFirstType(ty);
    }

    pub fn parseParameterWithFirstType(self: *Self, ty: node.NodeId) !node.NodeId {
        const spread = self.consumeIfIs(.spread);
        const ident = try self.expect(.identifier);
        const eq_tok = self.consumeIfIs(.assign);

        const default = if (eq_tok != null)
            try self.parseExpr()
        else
            null;

        return self.createNode(.{
            .parameter = .{
                .ty = ty,
                .spread = spread != null,
                .name = ident[1],
                .default = default,
            },
        }, .{
            .parameter = .{
                .spread_tok = spread,
                .name_tok = ident[0],
                .eq_tok = eq_tok,
            },
        });
    }

    fn parseCommaSimpleFirst(
        self: *Self,
        first: node.NodeId,
        comptime end_hint: ?std.meta.FieldEnum(tokenize.TokenKind),
        comptime cb: fn (*Self) ParseError!node.NodeId,
    ) !node.NodeRange {
        var these_nodes = std.ArrayList(node.NodeId).init(self.arena.allocator());
        try these_nodes.append(first);

        var comma = self.peek();
        while (comma != null and comma.?.kind == .comma) : (comma = self.peek()) {
            _ = self.next();
            if (end_hint != null and self.nextIs(end_hint.?)) break;

            const next_param = try cb(self);
            try these_nodes.append(next_param);
        }

        const starti = self.node_ranges.items.len;
        try self.node_ranges.appendSlice(these_nodes.items);

        return .{
            .start = @truncate(starti),
            .len = @truncate(self.node_ranges.items.len - starti),
        };
    }

    pub fn nodeRange(self: *const Self, range: node.NodeRange) []const node.NodeId {
        return self.node_ranges.items[range.start .. range.start + range.len];
    }

    fn consumeNL(self: *Self) void {
        var tok = self.lexer.peek() orelse return;
        while (tok.kind == .newline) : (tok = self.lexer.peek() orelse return) {
            _ = self.lexer.next();
        }
    }

    inline fn consumeIfIs(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) ?tokenize.TokenId {
        const tok = self.peek() orelse return null;
        if (tok.kind == kind) {
            _ = self.next();
            return self.lexer.lastIndex();
        }

        return null;
    }

    inline fn nextIs(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) bool {
        const tok = self.peek() orelse return false;
        return tok.kind == kind;
    }

    inline fn nextIsNoNL(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) bool {
        const tok = self.peekNoNL() orelse return false;
        return tok.kind == kind;
    }

    inline fn nextIsNoNLResync(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) bool {
        self.lexer.resync();
        const tok = self.peekNoNL() orelse return false;
        return tok.kind == kind;
    }

    inline fn hasNext(self: *Self) bool {
        self.consumeNL();
        return self.lexer.hasNext();
    }

    inline fn peek(self: *Self) ?tokenize.Token {
        self.consumeNL();
        return self.lexer.peek();
    }

    inline fn next(self: *Self) ?tokenize.Token {
        self.consumeNL();
        return self.lexer.next();
    }

    inline fn peekNoNL(self: *Self) ?tokenize.Token {
        return self.lexer.peek();
    }

    inline fn nextNoNL(self: *Self) ?tokenize.Token {
        return self.lexer.next();
    }

    fn expect(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) !struct {
        tokenize.TokenId,
        std.meta.FieldType(tokenize.TokenKind, kind),
    } {
        const tok = self.peek() orelse return error.UnexpectedEnd;
        if (tok.kind == kind) {
            _ = self.next();
            return .{ self.lexer.lastIndex(), @field(tok.kind, @tagName(kind)) };
        }

        return error.UnexpectedToken;
    }

    fn expectNoNL(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) !struct {
        tokenize.TokenId,
        std.meta.FieldType(tokenize.TokenKind, kind),
    } {
        const tok = self.peekNoNL() orelse return error.UnexpectedEnd;
        if (tok.kind == kind) {
            _ = self.nextNoNL();
            return .{ self.lexer.lastIndex(), @field(tok.kind, @tagName(kind)) };
        }

        return error.UnexpectedToken;
    }

    fn createNodeAndNext(self: *Self, kind: node.NodeKind) !node.NodeId {
        _ = self.next();
        return try self.createNode(kind, .{ .single = self.lexer.lastIndex() });
    }

    fn createNodeAndNextNoNL(self: *Self, kind: node.NodeKind) !node.NodeId {
        _ = self.nextNoNL();
        return try self.createNode(kind, .{ .single = self.lexer.lastIndex() });
    }

    fn createNode(self: *Self, kind: node.NodeKind, tokens: node.NodeTokens) !node.NodeId {
        const index = self.nodes.items.len;
        const id: node.NodeId = .{
            .file = 0,
            .index = @truncate(index),
        };

        try self.node_tokens.append(tokens);

        try self.nodes.append(.{
            .id = id,
            .kind = kind,
        });

        return id;
    }
};

fn binaryPrec(op: node.Operator) u8 {
    return switch (op) {
        .times, .divide => 80,
        .plus, .minus => 70,

        .bitnot => 60,
        .bitand => 0, // @TODO: idk what to do here
        .bitor => 50,
        .bitxor => 45,

        .shiftleft, .shiftright => 40,

        .assign => 20,
        .plus_eq => 20,
        .minus_eq => 20,
        .times_eq => 20,
        .divide_eq => 20,
        .bitor_eq => 20,
        .bitxor_eq => 20,
        .member_access => 86,

        .equal => 30,
        .not_equal => 30,
        .gt => 30,
        .gte => 30,
        .lt => 30,
        .lte => 30,

        else => 0,
    };
}

fn postPrec(op: node.Operator) u8 {
    return switch (op) {
        .invoke, .subscript => 85,
        .ref => 81,
        .opt => 81,

        .deref, .take_ref => 81,
        .colon => 20,
        else => 0,
    };
}
