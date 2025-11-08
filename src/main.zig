const std = @import("std");
const flags = @import("./flags.zig");

pub fn main() !void {
    var buf: [1024]u8 = .{0} ** 1024;
    var stdout = std.fs.File.stdout().writer(&buf);
    try flags.writeUsage(&stdout.interface, "cutcsv", "0.3.0");
}
