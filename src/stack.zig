const std = @import("std");
const lib = @import("./lib.zig");

pub fn main() !void {
    const writer = std.io.getStdOut().writer();
    try writer.print("lib name = {s}\n", .{lib.name});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ls = try lib.LuaState.new(allocator);
    try ls.pushBoolean(true);
    try ls.printStack(writer);
    try ls.pushInteger(10);
    try ls.printStack(writer);
    try ls.pushNil();
    try ls.printStack(writer);
    try ls.pushString("hello");
    try ls.printStack(writer);
    try ls.pushValue(-4);
    try ls.printStack(writer);
    try ls.replace(3);
    try ls.printStack(writer);
    try ls.setTop(6);
    try ls.printStack(writer);
    try ls.remove(-3);
    try ls.printStack(writer);
    try ls.setTop(-5);
    try ls.printStack(writer);
}
