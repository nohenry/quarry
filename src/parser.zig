const std = @import("std");
const node = @import("node.zig");
const tokenize = @import("tokenize.zig");

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEnd,
    UnexpectedGarbage,
} || std.mem.Allocator.Error;

pub fn dbg(v: anytype) void {
    std.log.debug("{}", .{v});
}

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,
    lexer: *tokenize.Lexer,

    nodes: std.ArrayList(node.Node),
    node_ranges: std.ArrayList(node.NodeId),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, lexer: *tokenize.Lexer) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .lexer = lexer,

            .nodes = std.ArrayList(node.Node).init(allocator),
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

    pub fn parseBraceBlock(self: *Self) !node.NodeRange {
        _ = try self.expect(.open_brace);
        if (self.consumeIfIs(.close_brace) != null) {
            return node.NodeRange{
                .start = @truncate(self.node_ranges.items.len),
                .len = 0,
            };
        }
        const block = try self.parseBlock();
        _ = try self.expect(.close_brace);

        return block;
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

        std.log.debug("{}", .{tok});
        return switch (tok.kind) {
            .let => self.parseBinding(),
            else => blk: {
                const expr = try self.parseExpr();

                self.nodes.items[expr.index].print();
                if (self.nextIsNoNL(.identifier)) {
                    self.lexer.resync();
                }

                break :blk if (self.nextIsNoNL(.identifier) or self.nextIsNoNL(.mut))
                    self.parseBindingWithType(expr)
                else
                    expr;
            },
        };
    }

    pub fn parseBinding(self: *Self) !node.NodeId {
        const ty = if (self.consumeIfIs(.let) == null)
            try self.parseType()
        else
            null;

        return self.parseBindingWithType(ty);
    }

    pub fn parseBindingWithType(self: *Self, ty_node_id: ?node.NodeId) !node.NodeId {
        const mutable = self.consumeIfIs(.mut) != null;
        const name = try self.expect(.identifier);
        _ = try self.expect(.assign);
        const expr = try self.parseExpr();

        return self.createNode(.{
            .binding = .{
                .name = name,
                .ty = ty_node_id,
                .mutable = mutable,
                .tags = node.SymbolTag.Tag.initEmpty(),
                .value = expr,
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
        left = try self.parsePostExpr(last_prec, left);

        while (true) {
            const op_tok = self.lexer.peek() orelse break;
            const op = node.Operator.fromTokenKind(op_tok.kind) orelse break;

            const prec = binaryPrec(op);
            if (prec == 0 or prec < last_prec) break;
            _ = self.lexer.next();

            const right = try self.parseBinExpr(prec);

            left = try self.createNode(.{
                .binary_expr = .{
                    .left = left,
                    .op = op,
                    .right = right,
                },
            });
        }

        return left;
    }

    pub fn parsePostExpr(self: *Self, last_prec: u8, left_id: node.NodeId) !node.NodeId {
        var left = left_id;

        var tok = self.peekNoNL();
        while (tok != null) : (tok = self.peek()) {
            const op = node.Operator.fromTokenKind(tok.?.kind) orelse break;
            if (postPrec(op) < last_prec) break;

            self.lexer.resync();
            tok = self.peekNoNL();

            switch (tok.?.kind) {
                .open_paren => {
                    // parseInvoke
                    _ = self.next();
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

                    _ = try self.expect(.close_paren);

                    const trailing_block = if (self.nextIs(.open_brace))
                        try self.parseBraceBlock()
                    else
                        null;

                    left = try self.createNode(.{
                        .invoke = .{
                            .expr = left,
                            .args = args,
                            .trailing_block = trailing_block,
                        },
                    });
                },
                .open_bracket => {
                    // parseSubscript
                    _ = self.next();
                    const sub = try self.parseExpr();
                    _ = try self.expect(.close_bracket);

                    left = try self.createNode(.{
                        .subscript = .{
                            .expr = left,
                            .sub = sub,
                        },
                    });
                },
                else => break,
            }
        }

        tok = self.peek();
        while (tok != null) : (tok = self.peek()) {
            const op = node.Operator.fromTokenKind(tok.?.kind) orelse break;
            if (postPrec(op) < last_prec) break;

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
            if (postPrec(op) < last_prec) break;

            switch (tok.?.kind) {
                .mut => {
                    _ = self.next();
                    if (!self.nextIs(.ampersand)) {
                        self.lexer.resyncN(2);
                        break;
                    }
                    _ = try self.expect(.ampersand);

                    left = try self.createNode(.{
                        .type_ref = .{
                            .ty = left,
                            .mut = true,
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
                _ = self.next();

                const backing_field = if (self.consumeIfIs(.open_paren) != null) blk: {
                    const field = try self.parseExpr();
                    _ = try self.expect(.close_paren);
                    break :blk field;
                } else null;

                if (self.consumeIfIs(.open_bracket) != null) {
                    // parseRecord

                    if (self.consumeIfIs(.close_bracket) != null) {
                        return self.createNode(.{
                            .type_record = .{
                                .backing_field = backing_field,
                                .fields = .{
                                    .start = @truncate(self.node_ranges.items.len),
                                    .len = 0,
                                },
                            },
                        });
                    }

                    const first = try self.parseRecordField();
                    const fields = try self.parseCommaSimpleFirst(first, .close_bracket, parseRecordField);
                    _ = try self.expect(.close_bracket);

                    return self.createNode(.{
                        .type_record = .{
                            .backing_field = backing_field,
                            .fields = fields,
                        },
                    });
                }

                const first_ty = try self.parseBinExpr(81);
                if (self.nextIs(.pipe) or self.nextIs(.identifier) or self.nextIs(.assign)) {
                    // parseUnion

                    const variant = try self.parseUnionVariantFirstExpr(first_ty);

                    var these_nodes = std.ArrayList(node.NodeId).init(self.arena.allocator());
                    try these_nodes.append(variant);

                    var pipe = self.peek();
                    while (pipe != null and pipe.?.kind == .pipe) : (pipe = self.peek()) {
                        _ = self.next();
                        const next_variant = try self.parseUnionVariant();
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
                    });
                }

                return self.createNode(.{
                    .type_alias = first_ty,
                });
            },
            .open_paren => {
                _ = self.next();
                const expr = if (self.consumeIfIs(.close_paren) == null)
                    try self.parseExpr()
                else
                    null;

                if (expr != null and self.consumeIfIs(.close_paren) != null) {
                    return expr.?;
                }
                // parseFunc
                if (expr != null and self.nextIs(.identifier) or self.nextIs(.spread)) {
                    const first_param = try self.parseParameterWithFirstType(expr.?);
                    const params = try self.parseCommaSimpleFirst(first_param, .close_paren, parseParameter);

                    _ = try self.expect(.close_paren);

                    return self.parseFuncWithParams(params);
                } else if (expr == null) {
                    return self.parseFuncWithParams(null);
                }

                try self.expect(.close_paren);

                return expr.?;
            },
            .open_bracket => {
                _ = self.next();

                // parseArrayInit
                // parseSliceType
                // parseArrayType

                const mut = self.consumeIfIs(.mut);
                const expr = try self.parseExpr();

                const value = if (self.consumeIfIs(.colon) != null)
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
                        });

                        try these_nodes.append(next_expr);
                    } else {
                        try these_nodes.append(expr);
                    }

                    const is_record = value != null;

                    var comma = self.peek();
                    while (comma != null and comma.?.kind == .comma) : (comma = self.peek()) {
                        _ = self.next();
                        var next_expr = try self.parseExpr();

                        if (self.consumeIfIs(.colon) != null) {
                            const this_value = try self.parseExpr();
                            next_expr = try self.createNode(.{
                                .key_value = .{
                                    .key = next_expr,
                                    .value = this_value,
                                },
                            });

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

                    _ = try self.expect(.close_bracket);

                    return self.createNode(.{
                        .array_init = .{
                            .exprs = .{
                                .start = @truncate(starti),
                                .len = @truncate(self.node_ranges.items.len - starti),
                            },
                        },
                    });
                }

                _ = try self.expect(.close_bracket);

                return self.createNode(.{
                    .array_init_or_slice_one = .{
                        .expr = expr,
                        .value = value,
                        .mut = mut != null,
                    },
                });
            },
            .@"if" => {
                // parseIf
                _ = self.next();
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

                const false_block = if (self.consumeIfIs(.@"else") != null)
                    try self.parseBraceBlock()
                else
                    null;

                return self.createNode(.{
                    .if_expr = .{
                        .cond = cond,
                        .captures = captures,
                        .true_block = true_block,
                        .false_block = false_block,
                    },
                });
            },
            .loop => {
                // parseLoop
                _ = self.next();
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

                const finally_block_pre = if (self.consumeIfIs(.finally) != null)
                    try self.parseBraceBlock()
                else
                    null;

                const else_block = if (self.consumeIfIs(.@"else") != null)
                    try self.parseBraceBlock()
                else
                    null;

                if (finally_block_pre != null and else_block != null) {
                    std.log.err("Finally block should be after else block!", .{});
                }

                const finally_block = if (finally_block_pre) |blk|
                    blk
                else if (self.consumeIfIs(.finally) != null)
                    try self.parseBraceBlock()
                else
                    null;

                return self.createNode(.{
                    .loop = .{
                        .expr = expr,
                        .captures = captures,
                        .loop_block = loop_block,
                        .else_block = else_block,
                        .finally_block = finally_block,
                    },
                });
            },
            .@"const" => {
                _ = self.next();
                if (self.nextIs(.open_brace)) {
                    const block = try self.parseBraceBlock();
                    return self.createNode(.{
                        .const_block = .{ .block = block },
                    });
                } else {
                    const expr = try self.parseExpr();
                    return self.createNode(.{
                        .const_expr = .{ .expr = expr },
                    });
                }
            },
            else => return self.parseLiteral(),
        }
    }

    pub fn parseFuncWithParams(self: *Self, params: ?node.NodeRange) !node.NodeId {
        const ty = if (!self.nextIs(.open_brace))
            try self.parseExpr()
        else
            null;

        _ = try self.expect(.open_brace);

        const block = if (self.consumeIfIs(.close_brace) != null)
            node.NodeRange{ .start = @truncate(self.node_ranges.items.len), .len = 0 }
        else blk: {
            const block = try self.parseBlock();
            _ = try self.expect(.close_brace);
            break :blk block;
        };

        if (params) |pparams| {
            return self.createNode(.{
                .func = .{
                    .params = pparams,
                    .ret_ty = ty,
                    .block = block,
                },
            });
        } else {
            return self.createNode(.{
                .func_no_params = .{
                    .ret_ty = ty,
                    .block = block,
                },
            });
        }
    }

    pub fn parseRecordField(self: *Self) !node.NodeId {
        const ty = try self.parseExpr();
        const name = try self.expect(.identifier);

        const default = if (self.consumeIfIs(.assign) != null)
            try self.parseExpr()
        else
            null;

        return self.createNode(.{
            .record_field = .{
                .ty = ty,
                .name = name,
                .default = default,
            },
        });
    }

    pub fn parseUnionVariant(self: *Self) !node.NodeId {
        const first = try self.parseBinExpr(81);
        return self.parseUnionVariantFirstExpr(first);
    }

    pub fn parseUnionVariantFirstExpr(self: *Self, first: node.NodeId) !node.NodeId {
        const name = if (self.nextIsNoNL(.newline) or !self.hasNext() or self.nextIs(.pipe) or self.nextIs(.assign))
            first
        else
            try self.parseLiteral();

        const index = if (self.consumeIfIs(.assign) != null)
            try self.parseBinExpr(81)
        else
            null;

        return self.createNode(.{
            .union_variant = .{
                .ty = first,
                .name = name,
                .index = index,
            },
        });
    }

    pub fn parseLiteral(self: *Self) !node.NodeId {
        const tok = self.peek() orelse return error.UnexpectedEnd;
        std.log.debug("Literal: {}", .{tok});
        return switch (tok.kind) {
            .int_literal => |value| self.createNodeAndNext(.{ .int_literal = value }),
            .float_literal => |value| self.createNodeAndNext(.{ .float_literal = value }),
            .bool_literal => |value| self.createNodeAndNext(.{ .bool_literal = value }),
            .string_literal => |value| self.createNodeAndNext(.{ .string_literal = value }),
            .identifier => |value| self.createNodeAndNext(.{ .identifier = value }),

            // Types
            .int => |size| self.createNodeAndNext(.{ .type_int = size }),
            .uint => |size| self.createNodeAndNext(.{ .type_uint = size }),
            .float => |size| self.createNodeAndNext(.{ .type_float = size }),
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

    pub fn parseType(self: *Self) !node.NodeId {
        const tok = self.peekNoNL() orelse return error.UnexpectedEnd;
        return switch (tok.kind) {
            .int => |size| self.createNodeAndNext(.{
                .type_int = size,
            }),
            .uint => |size| self.createNodeAndNext(.{
                .type_uint = size,
            }),
            .float => |size| self.createNodeAndNext(.{
                .type_float = size,
            }),
            .bool => self.createNodeAndNext(.type_bool),
            else => error.UnexpectedToken,
        };
    }

    pub fn parseArgument(self: *Self) !node.NodeId {
        const val = try self.parseKvOrExpr();
        if (self.nodes.items[val.index].kind != .key_value and self.nodes.items[val.index].kind != .key_value_ident) {
            return self.createNode(.{ .argument = val });
        }
        return val;
    }

    pub fn parseKvOrExpr(self: *Self) !node.NodeId {
        const first = try self.parseExpr();
        if (self.consumeIfIs(.colon) != null) {
            if (self.nodes.items[first.index].kind == .identifier) {
                const key = self.nodes.items[first.index].kind.identifier;
                self.nodes.items.len -= 1;

                const value = try self.parseExpr();
                return self.createNode(.{
                    .key_value_ident = .{
                        .key = key,
                        .value = value,
                    },
                });
            }
            const value = try self.parseExpr();
            return self.createNode(.{
                .key_value = .{
                    .key = first,
                    .value = value,
                },
            });
        }

        return first;
    }

    pub fn parseParameter(self: *Self) !node.NodeId {
        const ty = try self.parseExpr();
        return self.parseParameterWithFirstType(ty);
    }

    pub fn parseParameterWithFirstType(self: *Self, ty: node.NodeId) !node.NodeId {
        const spread = self.consumeIfIs(.spread) != null;
        const ident = try self.expect(.identifier);
        const default = if (self.consumeIfIs(.assign) != null)
            try self.parseExpr()
        else
            null;

        return self.createNode(.{
            .parameter = .{
                .ty = ty,
                .spread = spread,
                .name = ident,
                .default = default,
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

    inline fn consumeIfIs(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) ?std.meta.FieldType(tokenize.TokenKind, kind) {
        const tok = self.peek() orelse return null;
        if (tok.kind == kind) {
            _ = self.next();
            return @field(tok.kind, @tagName(kind));
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

    fn expect(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) !std.meta.FieldType(tokenize.TokenKind, kind) {
        const tok = self.peek() orelse return error.UnexpectedEnd;
        if (tok.kind == kind) {
            _ = self.next();
            return @field(tok.kind, @tagName(kind));
        }

        return error.UnexpectedToken;
    }

    fn expectNoNL(self: *Self, comptime kind: std.meta.FieldEnum(tokenize.TokenKind)) !std.meta.FieldType(tokenize.TokenKind, kind) {
        const tok = self.peekNoNL() orelse return error.UnexpectedEnd;
        if (tok.kind == kind) {
            _ = self.nextNoNL();
            return @field(tok.kind, @tagName(kind));
        }

        return error.UnexpectedToken;
    }

    fn createNodeAndNext(self: *Self, kind: node.NodeKind) !node.NodeId {
        _ = self.next();
        return try self.createNode(kind);
    }

    fn createNodeAndNextNoNL(self: *Self, kind: node.NodeKind) !node.NodeId {
        _ = self.nextNoNL();
        return try self.createNode(kind);
    }

    fn createNode(self: *Self, kind: node.NodeKind) !node.NodeId {
        const index = self.nodes.items.len;
        const id: node.NodeId = .{
            .file = 0,
            .index = @truncate(index),
        };

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
        .invoke => 85,
        .ref => 81,
        .opt => 81,

        .deref, .take_ref => 81,
        else => 0,
    };
}
