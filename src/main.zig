const std = @import("std");
const lib = @import("./lib.zig");

pub fn main() !void {
    std.debug.print("lib name = {s}\n", .{lib.name});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args: [][]const u8 = try std.process.argsAlloc(allocator);
    if (args.len > 1) {
        const file = try std.fs.openFileAbsolute(args[1], .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 1024);
        const proto = try lib.undump(data, allocator);
        try list(proto, allocator);
    }
}

fn list(f: *lib.Prototype, alloc: std.mem.Allocator) !void {
    try printHeader(f);
    try printCode(f, alloc);
    try printDetail(f, alloc);
    for (f.protos) |p| {
        try list(p, alloc);
    }
}

fn printHeader(f: *lib.Prototype) !void {
    var funcType: []const u8 = "main";
    if (f.lineDefined > 0) {
        funcType = "function";
    }

    var varargFlag: []const u8 = "";
    if (f.isVararg > 0) {
        varargFlag = "+";
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n{s} <{s}:{d}:{d}> ({d} instructions)\n", .{
        funcType,
        f.source,
        f.lineDefined,
        f.lastLineDefined,
        f.code.len,
    });

    try stdout.print("{d}{s} params, {d} slots, {d} upvalues, ", .{
        f.numParams,
        varargFlag,
        f.maxStackSize,
        f.upvalues.len,
    });

    try stdout.print("{d} locals, {d} constants, {d} functions, ", .{
        f.locVars.len,
        f.constants.len,
        f.protos.len,
    });
}

fn printCode(f: *lib.Prototype, alloc: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    for (f.code, 0..) |c, pc| {
        var line: []const u8 = "-";
        if (f.lineInfo.len > 0) {
            line = try std.fmt.allocPrint(alloc, "{d}", .{f.lineInfo[pc]});
        }
        try stdout.print("\t{d}\t[{s}]\t0x{X:0>8}\n", .{
            pc + 1,
            line,
            c,
        });
    }
}

fn printDetail(f: *lib.Prototype, alloc: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("constants ({d}):\n", .{
        f.constants.len,
    });
    for (f.constants, 0..) |k, i| {
        try stdout.print("\t{d}\t{s}\n", .{
            i + 1,
            try constantToString(k, alloc),
        });
    }

    try stdout.print("locals ({d}):\n", .{
        f.locVars.len,
    });
    for (f.locVars, 0..) |locVar, i| {
        try stdout.print("\t{d}\t{s}\t{d}\t{d}\n", .{
            i,
            locVar.varName,
            locVar.startPC + 1,
            locVar.endPC + 1,
        });
    }

    try stdout.print("upvalues ({d}):\n", .{
        f.upvalues.len,
    });
    for (f.upvalues, 0..) |upval, i| {
        try stdout.print("\t{d}\t{s}\t{d}\t{d}\n", .{
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
