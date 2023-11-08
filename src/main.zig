const std = @import("std");
const lib = @import("./lib.zig");

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
        try list(proto, writer, allocator);
    }
}

fn list(f: *lib.Prototype, writer: anytype, alloc: std.mem.Allocator) !void {
    try printHeader(f, writer);
    try printCode(f, writer, alloc);
    try printDetail(f, writer, alloc);
    for (f.protos) |p| {
        try list(p, writer, alloc);
    }
}

fn printHeader(f: *lib.Prototype, writer: anytype) !void {
    var funcType: []const u8 = "main";
    if (f.lineDefined > 0) {
        funcType = "function";
    }

    var varargFlag: []const u8 = "";
    if (f.isVararg > 0) {
        varargFlag = "+";
    }

    try writer.print("\n{s} <{s}:{d}:{d}> ({d} instructions)\n", .{
        funcType,
        f.source,
        f.lineDefined,
        f.lastLineDefined,
        f.code.len,
    });

    try writer.print("{d}{s} params, {d} slots, {d} upvalues, ", .{
        f.numParams,
        varargFlag,
        f.maxStackSize,
        f.upvalues.len,
    });

    try writer.print("{d} locals, {d} constants, {d} functions\n", .{
        f.locVars.len,
        f.constants.len,
        f.protos.len,
    });
}

fn printCode(f: *lib.Prototype, writer: anytype, alloc: std.mem.Allocator) !void {
    for (f.code, 0..) |c, pc| {
        var line: []const u8 = "-";
        if (f.lineInfo.len > 0) {
            line = try std.fmt.allocPrint(alloc, "{d}", .{f.lineInfo[pc]});
        }
        try writer.print("\t{d}\t[{s}]\t0x{X:0>8}\n", .{
            pc + 1,
            line,
            c,
        });
    }
}

fn printDetail(f: *lib.Prototype, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.print("constants ({d}):\n", .{
        f.constants.len,
    });
    for (f.constants, 0..) |k, i| {
        try writer.print("\t{d}\t{s}\n", .{
            i + 1,
            try constantToString(k, alloc),
        });
    }

    try writer.print("locals ({d}):\n", .{
        f.locVars.len,
    });
    for (f.locVars, 0..) |locVar, i| {
        try writer.print("\t{d}\t{s}\t{d}\t{d}\n", .{
            i,
            locVar.varName,
            locVar.startPC + 1,
            locVar.endPC + 1,
        });
    }

    try writer.print("upvalues ({d}):\n", .{
        f.upvalues.len,
    });
    for (f.upvalues, 0..) |upval, i| {
        try writer.print("\t{d}\t{s}\t{d}\t{d}\n", .{
            i,
            upvalName(f, i),
            upval.instack,
            upval.idx,
        });
    }
}

fn constantToString(k: lib.Constant, alloc: std.mem.Allocator) ![]const u8 {
    return switch (k) {
        .nil => "nil",
        .boolean => |v| try std.fmt.allocPrint(alloc, "{}", .{v}),
        .integer => |v| try std.fmt.allocPrint(alloc, "{d}", .{v}),
        .number => |v| try std.fmt.allocPrint(alloc, "{e}", .{v}),
        .shortStr => |v| try std.fmt.allocPrint(alloc, "\"{s}\"", .{v}),
        .longStr => |v| try std.fmt.allocPrint(alloc, "\"{s}\"", .{v}),
    };
}

fn upvalName(f: *lib.Prototype, idx: usize) []const u8 {
    if (f.upvalueNames.len > 0) {
        return f.upvalueNames[idx];
    }
    return "-";
}
