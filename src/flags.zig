const std = @import("std");
const expect = std.testing.expect;

/// FieldSpec is a specification of a field, or a range of fields, that should be printed in the result.
pub const FieldSpec = union(enum) {
    range: struct {
        min: ?u64,
        max: ?u64,
    },
    column: []u8,
};

/// Flags specifies the set of flags used by cutcsv.
pub const Flags = struct {
    // files to be parsed, in order.
    files: std.ArrayList([]const u8),

    // fields to be printed from the files.
    fields: std.ArrayList([]FieldSpec),

    // csv field delimiter.
    delim: u8 = ',',

    // delimiter to be used for output;
    // will default to delim if not specified.
    outDelim: ?[:0]const u8 = null,

    // use verbose ouput.
    verbose: bool = false,

    // rows to skip from the top of the file.
    skipRows: u8 = 0, // actually 0 or 1, increase if necessary

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Flags {
        return .{
            .files = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .fields = try std.ArrayList([]FieldSpec).initCapacity(allocator, 16),
        };
    }
    pub fn deinit(self: *Flags, allocator: std.mem.Allocator) void {
        self.files.deinit(allocator);
        self.fields.deinit(allocator);
    }
};

pub fn writeUsage(writer: *std.Io.Writer, name: []const u8, version: []const u8) !void {
    const usageFormat =
        \\{s} - the csv swiss army knife (version {s})
        \\
        \\Usage: {0s} OPTION... [FILE...]
        \\Print selected CSV fields from each specified FILE to standard output.
        \\Select one or more fields using -c and/or -f. At least one must be selected.
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\    -f <LIST>   Print the specified comma-separated list of fields or ranges
        \\    -c <COLUMN> Select fields whose column name (value of the first line)
        \\                matches COLUMN.
        \\    -d <CHAR>   Use CHAR as a delimiter (defaults to ',')
        \\    -D <STRING> Use STRING as the output separator (in case of multiple fields).
        \\                Defaults to the input delimiter.
        \\    -r          Skip one row from the top of the file (header).
        \\    -h          Show this help message.
        \\    -v          Be verbose
        \\
        \\Each LIST is made up of one range, or many ranges separated by commas,
        \\in a similar fashion to the UNIX 'cut' program.
        \\Selected input is written in the same order that it is read, and is written
        \\exactly once. Each range is one of:
        \\
        \\  N     N'th field, counted from 1
        \\  N-    from N'th field, to end of line
        \\  N-M   from N'th to M'th (included) field
        \\  -M    from first to M'th (included) field
        \\
        \\https://zxq.co/rosa/cutcsv
        \\Copyright (c) 2021-2024 Morgan Bazalgette <the@howl.moe> under the MIT license
        \\
    ;
    return writer.print(usageFormat, .{ name, version });
}

pub const ParseArgsResult = union(enum) {
    Ok: Flags,
    Err: ParseArgsError,

    pub fn deinit(self: *ParseArgsResult, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .Ok => self.Ok.deinit(alloc),
            else => {},
        }
    }
};

pub const ParseArgsError = union(enum) {
    Empty: struct {
        position: u32,
    },
    InvalidFlag: u8,
    FlagAfterFiles,
    HelpWanted,
    NoFlagArg: u8,

    pub fn format(self: ParseArgsError, writer: anytype) !void {
        return switch (self) {
            .Empty => |emptyErr| writer.print("could not parse argument {d}: is empty", emptyErr.position),
            .FlagAfterFiles => writer.print("cannot pass a flag after passing files"),
            .InvalidFlag => |char| writer.print("unknown flag: -{c}", char),
        };
    }
};

const flagArgError = error{
    NoFlagArg,
};

fn flagArg(flagData: *[:0]const u8, argsIter: anytype) flagArgError![:0]const u8 {
    if (flagData.*.len > 1) {
        const ret = flagData.*[1..];
        flagData.* = "";
        return ret;
    }
    const ret = argsIter.next();
    if (ret == null) {
        return flagArgError.NoFlagArg;
    }
    return ret.?;
}

pub fn parseArgs(alloc: std.mem.Allocator, args: anytype) !ParseArgsResult {
    var pos: u32 = 0;
    var flags: Flags = try Flags.init(alloc);
    var success = false;
    defer {
        if (!success) {
            flags.deinit(alloc);
        }
    }
    var parsingFiles = false;

    while (args.next()) |arg| {
        defer pos += 1;

        if (arg.len == 0) {
            return .{ .Err = .{ .Empty = .{ .position = pos } } };
        }

        // file case
        if (arg[0] != '-' or arg.len == 1) {
            parsingFiles = true;
            if (arg.len == 1) {
                try flags.files.append(alloc, "/dev/stdin");
            } else {
                try flags.files.append(alloc, arg);
            }
            continue;
        }

        // flag case
        if (parsingFiles) {
            return .{ .Err = .FlagAfterFiles };
        }

        var toConsume = arg[1..];
        while (toConsume.len > 0) {
            switch (toConsume[0]) {
                'f' => {},
                'c' => {},
                'd' => {},
                'D' => {
                    flags.outDelim = try flagArg(&toConsume, args);
                },

                'h' => return .{ .Err = .HelpWanted },
                'v' => flags.verbose = true,
                'r' => flags.skipRows = 1,
                else => {},
            }
        }
    }
    flags.verbose = false;
    success = true;
    return .{ .Ok = flags };
}

const testArgIterator = std.process.ArgIteratorGeneral(.{ .single_quotes = true });

test "empty argument" {
    const alloc = std.testing.allocator;
    var argIterator = try testArgIterator.init(
        alloc,
        "''",
    );
    defer argIterator.deinit();
    var result = try parseArgs(alloc, &argIterator);
    defer result.deinit(alloc);
    try expect(result.Err.Empty.position == 0);
}

test "empty argument in second position" {
    const alloc = std.testing.allocator;
    var argIterator = try testArgIterator.init(
        alloc,
        "sas ''",
    );
    defer argIterator.deinit();
    var result = try parseArgs(alloc, &argIterator);
    defer result.deinit(alloc);
    try std.testing.expectEqual(1, result.Err.Empty.position);
}

test "with files" {
    const alloc = std.testing.allocator;
    var argIterator = try testArgIterator.init(
        alloc,
        "one two three",
    );
    defer argIterator.deinit();
    var result = try parseArgs(alloc, &argIterator);
    defer result.deinit(alloc);
    try std.testing.expectEqual(3, result.Ok.files.items.len);
    try std.testing.expectEqualStrings(result.Ok.files.items[0], "one");
    try std.testing.expectEqualStrings(result.Ok.files.items[1], "two");
    try std.testing.expectEqualStrings(result.Ok.files.items[2], "three");
}
