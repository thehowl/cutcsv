const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const talloc = std.testing.allocator;

/// FieldSpec is a specification of a field, or a range of fields, that should be printed in the result.
pub const FieldSpec = union(enum) {
    range: struct {
        min: ?u64 = null,
        max: ?u64 = null,
    },
    column: []const u8,
};

/// Flags specifies the set of flags used by cutcsv.
pub const Flags = struct {
    // files to be parsed, in order.
    files: std.ArrayList([]const u8),

    // fields to be printed from the files.
    fields: std.ArrayList(FieldSpec),

    // csv field delimiter.
    delim: u8 = ',',

    // delimiter to be used for output;
    // will default to delim if not specified.
    outDelim: ?[]u8 = null,

    // use verbose ouput.
    verbose: bool = false,

    // rows to skip from the top of the file.
    skipRows: u8 = 0, // actually 0 or 1, increase to u64 if expanding feature

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Flags {
        return .{
            .files = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .fields = try std.ArrayList(FieldSpec).initCapacity(allocator, 16),
        };
    }
    pub fn deinit(self: *Flags, allocator: std.mem.Allocator) void {
        for (self.files.items) |file| allocator.free(file);
        for (self.fields.items) |field| if (field == .column) allocator.free(field.column);
        if (self.outDelim) |outDelim| {
            allocator.free(outDelim);
        }
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
        \\  -f <LIST>   Print the specified comma-separated list of fields or ranges
        \\  -c <COLUMN> Select fields whose column name (value of the first line)
        \\              matches COLUMN.
        \\  -d <CHAR>   Use CHAR as a delimiter (defaults to ',')
        \\  -D <STRING> Use STRING as the output separator (in case of multiple fields).
        \\              Defaults to the input delimiter.
        \\  -r          Skip one row from the top of the file (header).
        \\  -h          Show this help message.
        \\  -v          Be verbose
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
        \\Copyright (c) 2021-2025 Morgan Bazalgette <the@howl.moe> under the MIT license
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
    NoFieldSpecProvided,
    InvalidFlag: u8,
    FlagAfterFiles,
    HelpWanted,
    NoFlagArg: u8,
    InvalidDelimLength: []const u8,
    InvalidDelim: u8,
    InvalidFieldSpec: []const u8,

    pub fn format(self: ParseArgsError, writer: anytype) !void {
        switch (self) {
            .Empty => |emptyErr| try writer.print("could not parse argument {d}: is empty\n", .{emptyErr.position}),
            .NoFieldSpecProvided => try writer.print("no field number or column provided\n", .{}),
            .InvalidFlag => |char| try writer.print("unknown flag: -{c}\n", .{char}),
            .FlagAfterFiles => try writer.print("cannot pass a flag after passing files\n", .{}),
            .HelpWanted => {}, // Ignore
            .NoFlagArg => try writer.print("missing argument after flag\n", .{}),
            .InvalidDelimLength => |delim| try writer.print("invalid delimiter: {s}\n", .{delim}),
            .InvalidDelim => |char| try writer.print("invalid delimiter: {c}\n", .{char}),
            .InvalidFieldSpec => |fs| try writer.print("invalid field spec: {s}\n", .{fs}),
        }
    }
};

fn flagArg(flagData: *[:0]const u8, argsIter: anytype) error{NoFlagArg}![]const u8 {
    if (flagData.*.len > 1) {
        const ret = flagData.*[1..];
        flagData.* = "";
        return ret;
    }
    flagData.* = flagData.*[1..];
    const ret = argsIter.next();
    if (ret == null) {
        return error.NoFlagArg;
    }
    return ret.?;
}

fn parseFieldSpec(fs: *[]const u8) error{InvalidFieldSpec}!FieldSpec {
    // TODO: DRY on the return
    var parsed: FieldSpec = .{ .range = .{} };
    var foundDash: bool = false;
    for (fs.*, 0..) |char, i| {
        switch (char) {
            '0'...'9' => {
                if (foundDash) {
                    parsed.range.max = (parsed.range.max orelse 0) * 10 + (char - '0');
                } else {
                    parsed.range.min = (parsed.range.min orelse 0) * 10 + (char - '0');
                }
            },
            '-' => {
                if (foundDash) return error.InvalidFieldSpec;
                foundDash = true;
            },
            ',' => {
                if ((parsed.range.max == null and parsed.range.min == null) or
                    (i + 1 == fs.len)) return error.InvalidFieldSpec;
                fs.* = fs.*[i + 1 ..];
                if (!foundDash and parsed.range.min != null) {
                    parsed.range.max = parsed.range.min;
                }
                return parsed;
            },
            else => return error.InvalidFieldSpec,
        }
    }
    if (parsed.range.max == null and parsed.range.min == null) return error.InvalidFieldSpec;
    fs.* = "";
    if (!foundDash and parsed.range.min != null) {
        parsed.range.max = parsed.range.min;
    }
    return parsed;
}

pub fn parseArgs(alloc: std.mem.Allocator, args: anytype) !ParseArgsResult {
    if (!args.skip()) {
        return .{ .Err = .NoFieldSpecProvided };
    }
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
        pos += 1;

        if (arg.len == 0) {
            return .{ .Err = .{ .Empty = .{ .position = pos } } };
        }

        // file case
        if (arg[0] != '-' or arg.len == 1) {
            parsingFiles = true;
            if (arg.len == 1) {
                try flags.files.append(alloc, try alloc.dupe(u8, "/dev/stdin"));
            } else {
                try flags.files.append(alloc, try alloc.dupe(u8, arg));
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
                'f' => {
                    var fieldSpecs = flagArg(&toConsume, args) catch |err| switch (err) {
                        error.NoFlagArg => return .{ .Err = .{ .NoFlagArg = 'f' } },
                    };
                    while (fieldSpecs.len > 0) {
                        const fs = parseFieldSpec(&fieldSpecs) catch |err| switch (err) {
                            error.InvalidFieldSpec => return .{ .Err = .{ .InvalidFieldSpec = fieldSpecs } },
                        };
                        try flags.fields.append(alloc, fs);
                    }
                },
                'c' => {
                    const columnName = flagArg(&toConsume, args) catch |err| switch (err) {
                        error.NoFlagArg => return .{ .Err = .{ .NoFlagArg = 'f' } },
                    };
                    try flags.fields.append(alloc, FieldSpec{
                        .column = try alloc.dupe(u8, columnName),
                    });
                },
                'd' => {
                    const delim = flagArg(&toConsume, args) catch |err| switch (err) {
                        error.NoFlagArg => return .{ .Err = .{ .NoFlagArg = 'd' } },
                    };
                    if (delim.len != 1) {
                        return .{ .Err = .{ .InvalidDelimLength = delim } };
                    }
                    switch (delim[0]) {
                        '\n', '\r', '"' => return .{ .Err = .{ .InvalidDelim = delim[0] } },
                        else => {},
                    }
                    flags.delim = delim[0];
                },
                'D' => {
                    const outDelimArg = flagArg(&toConsume, args) catch |err| switch (err) {
                        error.NoFlagArg => return .{ .Err = .{ .NoFlagArg = 'D' } },
                    };
                    if (flags.outDelim) |existingOutDelim| {
                        flags.outDelim = try alloc.realloc(existingOutDelim, outDelimArg.len);
                        @memcpy(flags.outDelim.?, outDelimArg);
                    } else {
                        flags.outDelim = try alloc.dupe(u8, outDelimArg);
                    }
                },

                'h' => return .{ .Err = .HelpWanted },
                'v' => {
                    flags.verbose = true;
                    toConsume = toConsume[1..];
                },
                'r' => {
                    flags.skipRows = 1;
                    toConsume = toConsume[1..];
                },
                else => return .{ .Err = .{ .InvalidFlag = toConsume[0] } },
            }
        }
    }

    if (flags.fields.items.len == 0) {
        return .{ .Err = .NoFieldSpecProvided };
    }
    if (flags.files.items.len == 0) {
        try flags.files.append(alloc, try alloc.dupe(u8, "/dev/stdin"));
    }
    if (flags.outDelim == null) {
        flags.outDelim = try alloc.dupe(u8, (&[_]u8{ flags.delim, 0 })[0..1]);
    }

    success = true;
    return .{ .Ok = flags };
}

const testArgIterator = std.process.ArgIteratorGeneral(.{ .single_quotes = true });

fn testParseArgs(comptime input: []const u8) !ParseArgsResult {
    const alloc = talloc;
    var argIterator = try testArgIterator.init(
        alloc,
        "cutcsv " ++ input,
    );
    defer argIterator.deinit();
    return parseArgs(alloc, &argIterator);
}

test "field spec" {
    var result = try testParseArgs("-f1-3");
    defer result.deinit(talloc);
    expect(result == .Ok) catch |err| {
        std.debug.print("Result: {f}\n", .{result.Err});
        return err;
    };

    var flags = try Flags.init(talloc);
    defer flags.deinit(talloc);
    try flags.fields.append(talloc, FieldSpec{ .range = .{ .min = 1, .max = 3 } });
    try flags.files.append(talloc, try talloc.dupe(u8, "/dev/stdin"));
    flags.outDelim = try talloc.dupe(u8, ",");

    try std.testing.expectEqualDeep(ParseArgsResult{
        .Ok = flags,
    }, result);
}

test "column field spec" {
    var result = try testParseArgs("-chello");
    defer result.deinit(talloc);
    expect(result == .Ok) catch |err| {
        std.debug.print("Result: {f}\n", .{result.Err});
        return err;
    };

    var flags = try Flags.init(talloc);
    defer flags.deinit(talloc);
    try flags.fields.append(talloc, FieldSpec{
        .column = try talloc.dupe(u8, "hello"),
    });
    try flags.files.append(talloc, try talloc.dupe(u8, "/dev/stdin"));
    flags.outDelim = try talloc.dupe(u8, ",");

    try std.testing.expectEqualDeep(ParseArgsResult{
        .Ok = flags,
    }, result);
}

test "all together" {
    var result = try testParseArgs("-chello -f1,2-,-5,111-112 -d, -DNOWAY -v -r");
    defer result.deinit(talloc);
    expect(result == .Ok) catch |err| {
        std.debug.print("Result: {f}\n", .{result.Err});
        return err;
    };

    var flags = try Flags.init(talloc);
    defer flags.deinit(talloc);
    try flags.files.append(talloc, try talloc.dupe(u8, "/dev/stdin"));
    try flags.fields.appendSlice(talloc, &[_]FieldSpec{
        .{
            .column = try talloc.dupe(u8, "hello"),
        },
        .{ .range = .{ .min = 1, .max = 1 } },
        .{ .range = .{ .min = 2, .max = null } },
        .{ .range = .{ .min = null, .max = 5 } },
        .{ .range = .{ .min = 111, .max = 112 } },
    });
    flags.delim = ',';
    flags.outDelim = try talloc.dupe(u8, "NOWAY");
    flags.verbose = true;
    flags.skipRows = 1;

    try std.testing.expectEqualDeep(ParseArgsResult{
        .Ok = flags,
    }, result);
}

test "default outDelim" {
    var result = try testParseArgs("-f1 -d. one");
    defer result.deinit(talloc);
    expect(result == .Ok) catch |err| {
        std.debug.print("Result: {f}\n", .{result.Err});
        return err;
    };

    var flags = try Flags.init(talloc);
    defer flags.deinit(talloc);
    try flags.files.append(talloc, try talloc.dupe(u8, "one"));
    try flags.fields.append(talloc, .{ .range = .{ .min = 1, .max = 1 } });
    flags.delim = '.';
    flags.outDelim = try talloc.dupe(u8, ".");

    try std.testing.expectEqualDeep(ParseArgsResult{
        .Ok = flags,
    }, result);
}

test "multiple outDelim" {
    var result = try testParseArgs("-f1 -Dwhat -Dthe -Dhell one");
    defer result.deinit(talloc);
    expect(result == .Ok) catch |err| {
        std.debug.print("Result: {f}\n", .{result.Err});
        return err;
    };

    var flags = try Flags.init(talloc);
    defer flags.deinit(talloc);
    try flags.files.append(talloc, try talloc.dupe(u8, "one"));
    try flags.fields.append(talloc, .{ .range = .{ .min = 1, .max = 1 } });
    flags.outDelim = try talloc.dupe(u8, "hell");

    try std.testing.expectEqualDeep(ParseArgsResult{
        .Ok = flags,
    }, result);
}

test "with files" {
    var result = try testParseArgs("-f1 one two three");
    defer result.deinit(talloc);
    try expect(result == .Ok);

    var flags = try Flags.init(talloc);
    defer flags.deinit(talloc);
    try flags.files.appendSlice(talloc, &[_][]u8{
        try talloc.dupe(u8, "one"),
        try talloc.dupe(u8, "two"),
        try talloc.dupe(u8, "three"),
    });
    try flags.fields.append(talloc, .{ .range = .{ .min = 1, .max = 1 } });
}

test "error: help" {
    var result = try testParseArgs("-h");
    defer result.deinit(talloc);
    try expect(result.Err == .HelpWanted);
}

test "error: empty argument" {
    var result = try testParseArgs("''");
    defer result.deinit(talloc);
    try expect(result.Err.Empty.position == 1);
}

test "error: empty argument in second position" {
    var result = try testParseArgs("sas ''");
    defer result.deinit(talloc);
    try expectEqual(2, result.Err.Empty.position);
}
