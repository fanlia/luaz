const std = @import("std");
const lib = @import("./lib.zig");

pub fn main() !void {
    std.debug.print("lib name = {s}\n", .{lib.name});
}
