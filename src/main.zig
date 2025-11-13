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

const readIter = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    limit: u16 = 0,
    err: ?std.fs.File.ReadError = null,
    file: std.fs.File,
    fn next(self: *readIter) ?u8 {
        // TODO: utf8 support

        // Refill buffer if needed
        if (self.pos >= self.limit) {
            @branchHint(.unlikely);
            if (self.err != null) {
                return null;
            }
            const sz = self.file.read(&self.buf) catch |err| {
                self.err = err;
                return null;
            };
            if (sz == 0) return null; // EOF

            self.pos = 0;
            self.limit = @intCast(sz);
        }

        const byte = self.buf[self.pos];
        self.pos += 1;
        return byte;
    }
    // Consume until any of the bytes in `until` are found, or the buffer reaches
    // the end. May return 0 bytes if a read is necessary.
    // If a byte in `until` is found, it is not included in the returned slice.
    fn consumeGreedy(self: *readIter, until: []const u8) ?[]u8 {
        if (self.pos >= self.limit) {
            return null;
        }
        const pos = std.mem.indexOfAny(u8, self.buf[self.pos..self.limit], until);
        if (pos == null) {
            self.pos = self.limit;
            // always at least 1 byte returned
            return self.buf[self.pos..self.limit];
        }
        const sl = self.buf[self.pos .. self.pos + pos.?];
        self.pos += pos.?;
        return if (sl.len > 0) sl else null;
    }
};

const stateType = struct {
    fsm: enum {
        // ExpectField ---> Field        ---> ExpectField
        //             \
        //              --> QuotedField  ---> ExpectQuoteDelim ---> (QuotedField|ExpectField)
        ExpectField, // Beginning of field state
        QuotedField,
        Field,
        ExpectQuoteDelim,
    } = .ExpectField,
    fieldBuf: []u8,
    fieldBufCap: usize,

    fieldBitset: std.DynamicBitSetUnmanaged,
    colNum: u64 = 1,
    rowNum: u64 = 1,
    printedInRow: bool = false,

    fn fieldAppend(self: *stateType, gpa: std.mem.Allocator, b: u8) !void {
        if (self.fieldBuf.len == self.fieldBufCap) {
            @branchHint(.unlikely);
            const newCap = self.fieldBufCap + 1024;
            self.fieldBuf = (try gpa.realloc(self.fieldBuf, newCap))[0..self.fieldBufCap];
            self.fieldBufCap = newCap;
        }
        self.fieldBuf.len += 1;
        self.fieldBuf[self.fieldBuf.len - 1] = b;
    }
    fn fieldAppendMany(self: *stateType, gpa: std.mem.Allocator, bytes: []const u8) !void {
        if ((self.fieldBuf.len + bytes.len) >= self.fieldBufCap) {
            @branchHint(.unlikely);
            const oldLen = self.fieldBuf.len;
            const newCap = @max(self.fieldBufCap + 1024, self.fieldBuf.len + bytes.len);
            self.fieldBuf = (try gpa.realloc(self.fieldBuf, newCap))[0..oldLen];
            self.fieldBufCap = newCap;
        }
        self.fieldBuf.len += bytes.len;
        @memcpy(self.fieldBuf[self.fieldBuf.len - bytes.len .. self.fieldBuf.len], bytes);
    }

    fn deinit(self: *stateType, gpa: std.mem.Allocator) void {
        gpa.free(self.fieldBuf);
        self.fieldBitset.deinit(gpa);
    }

    inline fn printField(state: *stateType, gpa: std.mem.Allocator, fl: flags.Flags, sw: *std.io.Writer, isNewline: bool) !void {
        // \n or delim, in any case we are changing field.
        const bitPos: usize = state.colNum - 1;

        if (bitPos >= state.fieldBitset.bit_length) {
            try state.fieldBitset.resize(gpa, bitPos + 1, for (fl.fields.items) |spec| {
                if ((state.rowNum == 1 and spec == .column and std.mem.eql(u8, spec.column, state.fieldBuf)) or
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
                _ = try sw.write(fl.outDelim.?);
            } else {
                state.printedInRow = true;
            }
            _ = try sw.write(state.fieldBuf);
        }
        state.fieldBuf.len = 0;
        if (isNewline) {
            if (state.printedInRow)
                try sw.writeByte('\n');
            state.rowNum += 1;
            state.colNum = 1;
            state.printedInRow = false;
        } else {
            state.colNum += 1;
        }
    }
};

const executeFileError = error{
    InvalidCSV,
};

fn executeFile(gpa: std.mem.Allocator, sw: *std.io.Writer, fl: flags.Flags, filename: []const u8) !void {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    var ri: readIter = .{ .file = file };
    var state: stateType = .{
        .fieldBuf = (try gpa.alloc(u8, 1024))[0..0],
        .fieldBufCap = 1024,
        .fieldBitset = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 0),
    };
    defer state.deinit(gpa);

    while (ri.next()) |byte| {
        switch (state.fsm) {
            .Field => {
                if (byte == fl.delim or byte == '\n') {
                    try state.printField(gpa, fl, sw, byte == '\n');
                    state.fsm = .ExpectField;
                } else {
                    @branchHint(.likely);
                    try state.fieldAppend(gpa, byte);
                }
            },
            .QuotedField => {
                if (byte == '"') {
                    state.fsm = .ExpectQuoteDelim;
                } else {
                    @branchHint(.likely);
                    try state.fieldAppend(gpa, byte);
                }
            },
            .ExpectField => {
                if (byte == '"') {
                    state.fsm = .QuotedField;
                    if (ri.consumeGreedy("\"")) |bytes| {
                        try state.fieldAppendMany(gpa, bytes);
                    }
                } else {
                    try state.fieldAppend(gpa, byte);
                    state.fsm = .Field;
                    if (ri.consumeGreedy(&[_]u8{ fl.delim, '\n' })) |bytes| {
                        try state.fieldAppendMany(gpa, bytes);
                    }
                }
            },
            .ExpectQuoteDelim => {
                if (byte == '"') {
                    try state.fieldAppend(gpa, '"');
                    state.fsm = .QuotedField;
                } else if (byte == fl.delim or byte == '\n') {
                    try state.printField(gpa, fl, sw, byte == '\n');
                    state.fsm = .ExpectField;
                }
            },
        }
    }
    if (ri.err != null)
        return ri.err.?;

    // There's some data left-over without a trailing newline, try to see if
    // we should print it.
    if (state.colNum > 1 or state.fieldBuf.len > 0) {
        try state.printField(gpa, fl, sw, true);
    }
}
