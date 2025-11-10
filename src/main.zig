const std = @import("std");
const flags = @import("./flags.zig");
const alloc = std.heap.smp_allocator;

const name = "cutcsv";
const version = "0.3.0";

pub fn main() !u8 {
    // set up stdout writer
    var writerBuf = [_]u8{0} ** 1024;
    var stdout = std.fs.File.stdout().writer(&writerBuf);
    var sw = &stdout.interface;
    defer sw.flush() catch {};

    // parse args
    var args = std.process.args();
    var parsed = try flags.parseArgs(alloc, &args);
    defer parsed.deinit(alloc);
    if (parsed == .Err) {
        try parsed.Err.format(sw);
        try flags.writeUsage(sw, name, version);

        return 1;
    }

    // iterate over files and apply transformations
    const fl = parsed.Ok;
    for (fl.files.items) |filename| {
        try executeFile(alloc, sw, fl, filename);
    }

    return 0;
}

const parseState = struct {
    lastByte: ?u8 = null,
};

const readIter = struct {
    buf: [2048]u8 = undefined,
    pos: u16 = 0,
    limit: u16 = 0,
    file: std.fs.File,
    fn next(self: *readIter) std.fs.File.ReadError!?u8 {
        // TODO: utf8 support

        // Refill buffer if needed
        if (self.pos >= self.limit) {
            @branchHint(.unlikely);
            const sz = try self.file.read(&self.buf);
            if (sz == 0) return null; // EOF

            self.pos = 0;
            self.limit = @intCast(sz);
        }

        const byte = self.buf[self.pos];
        self.pos += 1;
        return byte;
    }
};

const stateType = struct {
    lastByte: ?u8 = null,
    fieldBuf: std.ArrayList(u8),
    fieldBitset: std.DynamicBitSetUnmanaged,
    colNum: u64 = 1,
    rowNum: u64 = 1,
    inQuotes: bool = false,
    printedInRow: bool = false,

    fn deinit(self: *stateType, gpa: std.mem.Allocator) void {
        self.fieldBuf.deinit(gpa);
        self.fieldBitset.deinit(gpa);
    }

    fn printField(state: *stateType, gpa: std.mem.Allocator, fl: flags.Flags, sw: *std.io.Writer, isNewline: bool) !void {
        // \n or delim, in any case we are changing field.
        const bitPos: usize = state.colNum - 1;
        if (bitPos >= state.fieldBitset.bit_length) {
            try state.fieldBitset.resize(gpa, bitPos + 1, for (fl.fields.items) |spec| {
                if ((state.rowNum == 1 and spec == .column and std.mem.eql(u8, spec.column, state.fieldBuf.items)) or
                    (spec == .range and
                        (spec.range.min == null or state.colNum >= spec.range.min.?) and
                        (spec.range.max == null or state.colNum <= spec.range.max.?))) break true;
            } else colNotWanted: {
                break :colNotWanted false;
            });
        }
        const shouldPrint = state.rowNum > fl.skipRows and state.fieldBitset.isSet(bitPos);
        if (shouldPrint) {
            if (state.printedInRow) {
                _ = try sw.write(fl.outDelim orelse &[_]u8{fl.delim});
            } else {
                state.printedInRow = true;
            }
            _ = try sw.write(state.fieldBuf.items);
        }
        state.fieldBuf.shrinkRetainingCapacity(0);
        if (isNewline) {
            if (state.printedInRow)
                try sw.writeByte('\n');
            state.rowNum += 1;
            state.colNum = 1;
            state.printedInRow = false;
        } else {
            state.colNum += 1;
        }
        state.lastByte = null;
    }
};

fn executeFile(gpa: std.mem.Allocator, sw: *std.io.Writer, fl: flags.Flags, filename: []const u8) !void {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    var ri: readIter = .{ .file = file };
    var state: stateType = .{
        .fieldBuf = try std.ArrayList(u8).initCapacity(gpa, 1024),
        .fieldBitset = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 0),
    };
    defer state.deinit(gpa);

    while (try ri.next()) |byte| {
        if (byte == '\r') continue; // TODO
        if (byte == '"') {
            if (!state.inQuotes and state.lastByte == '"') {
                // double quotes; was "mistakenly" set to inQuotes = false.
                state.inQuotes = true;
                try state.fieldBuf.append(gpa, '"');
            } else if (state.inQuotes) {
                state.inQuotes = false;
                state.lastByte = '"';
            } else if (state.lastByte != null and
                state.lastByte.? != '\n' and
                state.lastByte.? != fl.delim)
            {
                // not at boundaries of a field, likely literal "
                try state.fieldBuf.append(gpa, '"');
                state.lastByte = '"';
            } else {
                state.inQuotes = true;
                state.lastByte = null;
            }
            continue;
        }
        if (state.inQuotes or (byte != '\n' and byte != fl.delim)) {
            @branchHint(.likely);
            try state.fieldBuf.append(gpa, byte);
            state.lastByte = byte;
            continue;
        }

        // delim or newline, print field.
        try state.printField(gpa, fl, sw, byte == '\n');
    }

    // There's some data left-over without a trailing newline, try to see if
    // we should print it.
    if (state.colNum > 1 or state.fieldBuf.items.len > 0) {
        try state.printField(gpa, fl, sw, true);
    }
    std.Thread.sleep(1e9 * 60);
}
