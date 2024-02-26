const std = @import("std");
const tokenize = @import("tokenize.zig");
const parser = @import("parser.zig");
const analyze = @import("analyze.zig");
const type_check = @import("typecheck.zig");
const eval = @import("eval.zig");

pub const std_options = .{
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    const start_fmt = switch (level) {
        .err => "\x1b[1;31m",
        .warn => "\x1b[1;33m",
        .info => "\x1b[1;36m",
        .debug => "\x1b[1;35m",
    };

    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    nosuspend {
        writer.print(start_fmt ++ level_txt ++ "\x1b[0m" ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};

    var file = try std.fs.cwd().openFile("test/test.qry", .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    const file_contents = try in_stream.readAllAlloc(alloc.allocator(), std.math.maxInt(usize));

    var lexer = tokenize.Lexer.init(file_contents);
    var prsr = parser.Parser.init(alloc.allocator(), &lexer);
    const ids = try prsr.parse();

    std.debug.print("File items: \n", .{});
    for (ids) |nodeId| {
        const node = prsr.nodes.items[@as(usize, nodeId.index)];
        node.print();
    }

    std.debug.print("\nNode Ranges: \n", .{});
    for (prsr.node_ranges.items) |nodeId| {
        const node = prsr.nodes.items[@as(usize, nodeId.index)];
        node.print();
    }

    std.debug.print("\nAll Nodes: \n", .{});
    for (prsr.nodes.items) |node| {
        node.print();
    }

    var anal = analyze.Analyzer.init(prsr.nodes.items, prsr.node_ranges.items, alloc.allocator());
    try anal.analyze(ids);

    var arena = std.heap.ArenaAllocator.init(alloc.allocator());
    errdefer arena.deinit();

    var tycheck = try type_check.TypeChecker.init(
        prsr.nodes.items,
        prsr.node_ranges.items,
        anal.node_ref,
        alloc.allocator(),
        arena.allocator(),
    );

    const type_info = try tycheck.typeCheck(ids);

    var evaluator = eval.Evaluator.init(
        prsr.nodes.items,
        prsr.node_ranges.items,
        anal.node_ref,
        type_info,
        alloc.allocator(),
        arena.allocator(),
    );
    const instrs = try evaluator.eval(ids);

    std.debug.print("File items: \n", .{});
    for (instrs) |nodeId| {
        const instr = evaluator.instructions.items[@as(usize, nodeId.index)];
        instr.print();
    }

    std.debug.print("\nInstruction Ranges: \n", .{});
    for (evaluator.instruction_ranges.items) |nodeId| {
        const instr = evaluator.instructions.items[@as(usize, nodeId.index)];
        instr.print();
    }

    std.debug.print("\nAll instructions: \n", .{});
    for (evaluator.instructions.items) |instr| {
        instr.print();
    }

    arena.deinit();

    // var asmblr = asmb.Assembler.init(alloc.allocator(), &prsr);
    // _ = try asmblr.assemble(ids);

    // std.debug.print("\nInstructins:\n", .{});
    // for (asmblr.instructions.items) |instr| {
    //     std.debug.print("0x{x:0>8}    ", .{instr});
    //     std.debug.print("{b:0>32}\n", .{instr});
    // }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
