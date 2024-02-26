const std = @import("std");

pub const TokenId = usize;

pub const Token = struct {
    id: TokenId,
    kind: TokenKind,
};

pub const TokenKind = union(enum) {
    int_literal: u64,
    float_literal: f64,
    bool_literal: bool,
    string_literal: []const u8,
    identifier: []const u8,

    newline,
    comma,
    colon,
    assign,
    arrow,
    spread,

    equal,
    not_equal,
    gt,
    gte,
    lt,
    lte,

    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    pipe_eq,
    carot_eq,

    plus,
    minus,
    star,
    slash,
    ampersand,
    pipe,
    carot,
    tilde,
    question,
    bang,
    dot,
    dot_question,
    dot_star,
    dot_bang,
    dot_ampersand,
    double_right,
    double_left,

    open_paren,
    close_paren,
    open_bracket,
    close_bracket,
    open_brace,
    close_brace,

    // kws
    let,
    @"defer",
    @"if",
    @"else",
    finally,
    loop,
    @"const",
    mut,
    type,
    protocol,
    uint: usize,
    int: usize,
    float: usize,
    @"export",
    @"extern",
};

pub const SourceInfo = struct {
    position: usize,
};

pub const Lexer = struct {
    source: []const u8,
    position: usize = 0,
    index: usize = 0,

    source_info: std.ArrayList(SourceInfo),

    peek_buff: ?Token = null,

    const Self = @This();

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Self {
        return .{
            .source_info = std.ArrayList(SourceInfo).init(allocator),
            .source = source,
        };
    }

    pub fn hasNext(self: *const Self) bool {
        return self.peek_buff != null or self.position < self.source.len;
    }

    pub fn peek(self: *Self) ?Token {
        if (self.peek_buff) |pk| {
            return pk;
        } else {
            self.peek_buff = self.next();
            return self.peek_buff;
        }
    }

    inline fn binAndAssign(self: *const Self, bin: TokenKind, assign: TokenKind, len: usize) struct { TokenKind, usize } {
        return if (self.source.len > (self.position + 1) and self.source[self.position + 1] == '=')
            .{ assign, len + 1 }
        else
            .{ bin, len };
    }

    pub fn resync(self: *Self) void {
        if (self.peek_buff != null) {
            self.peek_buff  = null;
            self.position = self.source_info.items[self.source_info.items.len - 2].position;
        } else {
            self.position = self.source_info.getLast().position;
        }
    }

    pub fn next(self: *Self) ?Token {
        if (self.peek_buff) |pk| {
            self.peek_buff = null;

            return pk;
        }

        // eat whitespace
        while (self.position < self.source.len and self.source[self.position] != '\n' and std.ascii.isWhitespace(self.source[self.position])) : (self.position += 1) {}

        if (self.position >= self.source.len) {
            return null;
        }

        const c = self.source[self.position];
        const old_position = self.position;

        const result: struct { TokenKind, usize } = switch (c) {
            '\n' => .{ .newline, 1 },
            ',' => .{ .comma, 1 },
            ':' => .{ .colon, 1 },
            '=' => if (self.source.len > (self.position + 1))
                switch (self.source[self.position + 1]) {
                    '>' => .{ .arrow, 2 },
                    '=' => .{ .equal, 2 },
                    else => .{ .assign, 1 },
                }
            else
                .{ .assign, 1 },

            '+' => self.binAndAssign(.plus, .plus_eq, 1),
            '-' => self.binAndAssign(.minus, .minus_eq, 1),
            '*' => self.binAndAssign(.star, .star_eq, 1),
            '&' => .{ .ampersand, 1 },
            '|' => self.binAndAssign(.pipe, .pipe_eq, 1),
            '^' => self.binAndAssign(.carot, .carot_eq, 1),
            '~' => .{ .tilde, 1 },
            '?' => .{ .question, 1 },
            '!' => self.binAndAssign(.bang, .not_equal, 1),
            '.' => if (self.source.len > (self.position + 1))
                switch (self.source[self.position + 1]) {
                    '?' => .{ .dot_question, 2 },
                    '!' => .{ .dot_bang, 2 },
                    '*' => .{ .dot_star, 2 },
                    '&' => .{ .dot_ampersand, 2 },
                    '.' => if (self.source.len > (self.position + 3) and self.source[self.position + 2] == '.' and self.source[self.position + 3] == '.')
                        .{ .spread, 3 }
                    else
                        std.debug.panic("Unexpected token {c} found in input!", .{c}),
                    else => .{ .dot, 1 },
                }
            else
                .{ .dot, 1 },
            '>' => if (self.source.len > (self.position + 1) and self.source[self.position + 1] == '>')
                .{ .double_right, 2 }
            else
                self.binAndAssign(.gt, .gte, 1),
            '<' => if (self.source.len > (self.position + 1) and self.source[self.position + 1] == '<')
                .{ .double_left, 2 }
            else
                self.binAndAssign(.lt, .lte, 1),
            '(' => .{ .open_paren, 1 },
            ')' => .{ .close_paren, 1 },
            '[' => .{ .open_bracket, 1 },
            ']' => .{ .close_bracket, 1 },
            '{' => .{ .open_brace, 1 },
            '}' => .{ .close_brace, 1 },
            '\'', '"' => blk: {
                const startc = c;
                const start = self.position;
                self.position += 1;
                while (self.position < self.source.len and self.source[self.position] != startc) : (self.position += 1) {}
                const str = self.source[start..self.position];

                if (str.len <= 0 or self.position >= self.source.len or self.source[self.position] != startc) {
                    std.debug.panic("Unclosed string!", .{});
                }

                self.position += 1; // closing token

                break :blk .{
                    .{ .string_literal = str },
                    0,
                };
            },
            '/' => blk: {
                if (self.source.len > (self.position + 1) and self.source[self.position + 1] == '/') {
                    while (self.position < self.source.len and self.source[self.position] != '\n') : (self.position += 1) {}
                    self.position += 1;
                } else if (self.source.len > (self.position + 1) and self.source[self.position + 1] == '*') {
                    while (self.position + 1 < self.source.len and self.source[self.position] != '*' and self.source[self.position + 1] != '/') : (self.position += 1) {}
                    self.position += 1;
                } else {
                    break :blk self.binAndAssign(.slash, .slash_eq, 1);
                }

                std.debug.panic("Unexpected token {c} found in input!", .{c});
            },
            else => blk: {
                if (isValidIdentifier(c, true)) {
                    const start = self.position;
                    while (self.position < self.source.len and isValidIdentifier(self.source[self.position], false)) : (self.position += 1) {}
                    const str = self.source[start..self.position];

                    if (str.len <= 0) return null;

                    if (keyword_map.get(str)) |value| {
                        break :blk .{ value, 0 };
                    } else {
                        break :blk .{
                            .{ .identifier = str },
                            0,
                        };
                    }
                } else if (std.ascii.isDigit(c)) {
                    const start = self.position;
                    var base: ?u8 = null;
                    var is_float: bool = false;
                    while (self.position < self.source.len and (std.ascii.isAlphanumeric(self.source[self.position]) or (!is_float and self.source[self.position] == '.') or (base == null and std.mem.indexOfScalar(u8, "xbo", self.source[self.position]) == 1))) : (self.position += 1) {
                        switch (self.source[self.position]) {
                            '.' => is_float = true,
                            'x' => base = 16,
                            'b' => base = 2,
                            'o' => base = 8,
                            else => {},
                        }
                    }

                    const str = self.source[start..self.position];
                    if (is_float) {
                        if (base != null) {
                            std.debug.panic("Found base prefix on floating literal! (don't know how to handle)", .{});
                        }
                        const f = std.fmt.parseFloat(f64, str) catch std.debug.panic("Unable to parse float!!!!", .{});
                        break :blk .{ .{ .float_literal = f }, 0 };
                    } else {
                        const starti: usize = if (base != null) 2 else 0;
                        const i = std.fmt.parseInt(u64, str[starti..], base orelse 10) catch std.debug.panic("Unable to parse int!!!!", .{});
                        break :blk .{ .{ .int_literal = i }, 0 };
                    }
                }
                std.debug.panic("Unexpected token {c} found in input!", .{c});
            },
        };

        self.source_info.append(.{
            .position = old_position,
        }) catch @panic("Memory error");

        self.position += result[1];

        const index = self.index;
        self.index += 1;

        return .{
            .id = index,
            .kind = result[0],
        };
    }
};

fn isValidIdentifier(c: u8, start: bool) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-' or (!start and std.ascii.isDigit(c));
}

const KV = struct { []const u8, TokenKind };
pub const keyword_map = std.ComptimeStringMap(TokenKind, [_]KV{
    .{ "let", .let },
    .{ "mut", .mut },
    .{ "type", .type },
    .{ "protocol", .protocol },
    .{ "if", .@"if" },
    .{ "else", .@"else" },
    .{ "loop", .loop },
    .{ "finally", .finally },
    .{ "const", .@"const" },
    .{ "true", .{ .bool_literal = true } },
    .{ "false", .{ .bool_literal = false } },
    .{ "uint", .{ .uint = 0 } },
    .{ "uint8", .{ .uint = 8 } },
    .{ "uint16", .{ .uint = 16 } },
    .{ "uint32", .{ .uint = 32 } },
    .{ "uint64", .{ .uint = 64 } },
    .{ "int", .{ .int = 0 } },
    .{ "int8", .{ .int = 8 } },
    .{ "int16", .{ .int = 16 } },
    .{ "int32", .{ .int = 32 } },
    .{ "int64", .{ .int = 64 } },
    .{ "float", .{ .float = 32 } },
    .{ "float16", .{ .float = 16 } },
    .{ "float32", .{ .float = 32 } },
    .{ "float64", .{ .float = 64 } },
    .{ "float128", .{ .float = 128 } },
    .{ "export", .@"export" },
    .{ "extern", .@"extern" },
});
