const std = @import("std");
const expect = std.testing.expect;
const eql = std.mem.eql;

pub const name = "luaz";

const LUA_SIGNATURE = "\x1bLua";
const LUAC_VERSION = 0x53;
const LUAC_FORMAT = 0;
const LUAC_DATA = "\x19\x93\r\rn\x1a\n";
const CINT_SIZE = 4;
const CSIZET_SIZE = 8;
const INSTURCTION_SIZE = 4;
const LUA_INTEGER_SIZE = 8;
const LUA_NUMBER_SIZE = 8;
const LUAC_INT = 0x5678;
const LUAC_NUM = 370.5;

const TAG_NIL = 0x00;
const TAG_BOOLEAN = 0x01;
const TAG_NUMBER = 0x03;
const TAG_INTEGER = 0x13;
const TAG_SHORT_STR = 0x04;
const TAG_LONG_STR = 0x14;

const BinaryChunk = struct {
    header: Header,
    sizeUpvalues: u8,
    mainFunc: *Prototype,
};

const Header = struct {
    signature: [4]u8,
    version: u8,
    format: u8,
    luacData: [6]u8,
    cintSize: u8,
    sizetSize: u8,
    instructionSize: u8,
    luaIntegerSize: u8,
    luaNumberSize: u8,
    luacInt: i64,
    luacNum: f64,
};

const Prototype = struct {
    source: []const u8,
    lineDefined: u32,
    lastLineDefined: u32,
    numParams: u8,
    isVararg: u8,
    maxStackSize: u8,
    code: []u32,
    constants: []Constant,
    upvalues: []Upvalue,
    protos: []*Prototype,
    lineInfo: []u32,
    locVars: []LocVar,
    upvalueNames: [][]const u8,

    fn undump(data: []const u8) *Prototype {
        var reader = Reader{ .data = data };
        reader.checkHeader();
        reader.readByte();
        return reader.readProto("");
    }
};

const Constant = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    shortStr: []const u8,
    longStr: []const u8,
};

const Upvalue = struct {
    instack: u8,
    idx: u8,
};

const LocVar = struct {
    varName: []const u8,
    startPC: u32,
    endPC: u32,
};

const Reader = struct {
    data: []const u8,

    fn readByte(self: *Reader) u8 {
        const b = self.data[0];
        self.data = self.data[1..];
        return b;
    }

    fn readUint32(self: *Reader) u32 {
        const i = std.mem.readVarInt(u32, self.data, .Little);
        self.data = self.data[4..];
        return i;
    }

    fn readUint64(self: *Reader) u64 {
        const i = std.mem.readVarInt(u64, self.data, .Little);
        self.data = self.data[8..];
        return i;
    }

    fn readLuaInteger(self: *Reader) i64 {
        return @as(i64, @intCast(self.readUint64()));
    }

    fn readLuaNumber(self: *Reader) f64 {
        return @as(f64, @bitCast(self.readUint64()));
    }

    fn readString(self: *Reader) []const u8 {
        var size = @as(usize, @intCast(self.readByte()));
        if (size == 0) {
            return "";
        }
        if (size == 0xFF) {
            size = @as(usize, @intCast(self.readUint64()));
        }
        return self.readBytes(size - 1);
    }

    fn readBytes(self: *Reader, n: usize) []const u8 {
        const bytes = self.data[0..n];
        self.data = self.data[n..];
        return bytes;
    }
};

test "Reader readByte" {
    const data = [_]u8{1};
    var reader = Reader{ .data = &data };
    const byte = reader.readByte();
    try expect(byte == data[0]);
}

test "Reader readUint32" {
    const data = [_]u8{ 1, 0, 0, 0 };
    var reader = Reader{ .data = &data };
    const i = reader.readUint32();
    try expect(i == 1);
}

test "Reader readUint64" {
    const data = [_]u8{ 0x78, 0x56, 0, 0, 0, 0, 0, 0 };
    var reader = Reader{ .data = &data };
    const i = reader.readUint64();
    try expect(i == 0x5678);
}

test "Reader readLuaInteger" {
    const data = [_]u8{ 0x78, 0x56, 0, 0, 0, 0, 0, 0 };
    var reader = Reader{ .data = &data };
    const i = reader.readLuaInteger();
    try expect(i == 0x5678);
}

test "Reader readLuaNumber" {
    const data = [_]u8{ 0, 0, 0, 0, 0, 0x28, 0x77, 0x40 };
    var reader = Reader{ .data = &data };
    const f = reader.readLuaNumber();
    try expect(f == 370.5);
}

test "Reader readString" {
    const data = [_]u8{ 0x06, 0x70, 0x72, 0x69, 0x6E, 0x74 };
    var reader = Reader{ .data = &data };
    const bytes = reader.readString();
    try expect(eql(u8, bytes, "print"));
}

test "Reader readBytes" {
    const data = [_]u8{ 1, 2, 3, 4 };
    var reader = Reader{ .data = &data };
    const bytes = reader.readBytes(2);
    try expect(eql(u8, bytes, &[_]u8{ 1, 2 }));
}
