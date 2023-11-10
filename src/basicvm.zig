const std = @import("std");
const lib = @import("./libvm.zig");

pub fn main() !void {
    const writer = std.io.getStdOut().writer();
    try writer.print("lib name = {s}\n", .{lib.name});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args: [][]const u8 = try std.process.argsAlloc(allocator);
    if (args.len > 1) {
        const file = try std.fs.openFileAbsolute(args[1], .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 1024);
        const proto = try lib.undump(data, allocator);
        try luaMain(proto, writer, allocator);
    }
}

fn luaMain(proto: *lib.Prototype, writer: anytype, alloc: std.mem.Allocator) !void {
    const nRegs = @as(isize, @intCast(proto.maxStackSize));
    var ls = try lib.LuaState.new(@as(usize, @intCast(nRegs + 8)), proto, alloc);

    try ls.setTop(nRegs);
    while (true) {
        const pc = ls.getPC();
        const inst = lib.Instruction{ .data = ls.fetch() };

        if (inst.opEnum() == .OP_RETURN) {
            break;
        }

        try inst.execute(ls);
        try writer.print("[{d:0>2}] {s} ", .{ @as(usize, @intCast(pc + 1)), inst.opName() });
        try ls.printStack(writer);
    }
}
