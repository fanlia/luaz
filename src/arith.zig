const std = @import("std");
const lib = @import("./lib.zig");

pub fn main() !void {
    const writer = std.io.getStdOut().writer();
    try writer.print("lib name = {s}\n", .{lib.name});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ls = try lib.LuaState.new(allocator);
    try ls.pushInteger(1);
    try ls.pushString("2.0");
    try ls.pushString("3.0");
    try ls.pushNumber(4.0);
    try ls.printStack(writer);

    try ls.arith(.LUA_OPADD);
    try ls.printStack(writer);
    try ls.arith(.LUA_OPBNOT);
    try ls.printStack(writer);
    try ls.len(2);
    try ls.printStack(writer);
    try ls.concat(3);
    try ls.printStack(writer);
    try ls.pushBoolean(ls.compare(1, 2, .LUA_OPEQ));
    try ls.printStack(writer);
}
