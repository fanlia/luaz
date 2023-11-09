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
    try printStack(ls, writer);
    try ls.pushInteger(10);
    try printStack(ls, writer);
    try ls.pushNil();
    try printStack(ls, writer);
    try ls.pushString("hello");
    try printStack(ls, writer);
    try ls.pushValue(-4);
    try printStack(ls, writer);
    try ls.replace(3);
    try printStack(ls, writer);
    try ls.setTop(6);
    try printStack(ls, writer);
    try ls.remove(-3);
    try printStack(ls, writer);
    try ls.setTop(-5);
    try printStack(ls, writer);
}

fn printStack(ls: *lib.LuaState, writer: anytype) !void {
    var top = ls.getTop();
    var i: isize = 1;
    while (i <= top) : (i += 1) {
        const t = ls.getType(i);
        switch (t) {
            .LUA_TBOOLEAN => try writer.print("[{any}]", .{ls.toBoolean(i)}),
            .LUA_TNUMBER => try writer.print("[{d}]", .{ls.toNumber(i)}),
            .LUA_TSTRING => try writer.print("[{s}]", .{ls.toString(i)}),
            else => try writer.print("[{s}]", .{ls.typeName(t)}),
        }
    }
    try writer.print("\n", .{});
}
