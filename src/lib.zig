const std = @import("std");
const expect = std.testing.expect;
const eql = std.mem.eql;

pub const name = "luaz";

const LUA_SIGNATURE = "\x1bLua";
const LUAC_VERSION = 0x53;
const LUAC_FORMAT = 0;
const LUAC_DATA = "\x19\x93\r\n\x1a\n";
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

pub const Prototype = struct {
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
};

pub const Constant = union(enum) {
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
        const i = std.mem.readVarInt(u32, self.data[0..4], .Little);
        self.data = self.data[4..];
        return i;
    }

    fn readUint64(self: *Reader) u64 {
        const i = std.mem.readVarInt(u64, self.data[0..8], .Little);
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

    fn checkHeader(self: *Reader) !void {
        if (!eql(u8, self.readBytes(4), LUA_SIGNATURE)) {
            return error.NotAPrecompiledChunk;
        } else if (self.readByte() != LUAC_VERSION) {
            return error.VersionMismatch;
        } else if (self.readByte() != LUAC_FORMAT) {
            return error.FormatMismatch;
        } else if (!eql(u8, self.readBytes(6), LUAC_DATA)) {
            return error.Corrupted;
        } else if (self.readByte() != CINT_SIZE) {
            return error.IntSizeMismatch;
        } else if (self.readByte() != CSIZET_SIZE) {
            return error.SizetSizeMismatch;
        } else if (self.readByte() != INSTURCTION_SIZE) {
            return error.InstructionSizeMismatch;
        } else if (self.readByte() != LUA_INTEGER_SIZE) {
            return error.LuaIntegerSizeMismatch;
        } else if (self.readByte() != LUA_NUMBER_SIZE) {
            return error.LuaNumberSizeMismatch;
        } else if (self.readLuaInteger() != LUAC_INT) {
            return error.EndiannessMismatch;
        } else if (self.readLuaNumber() != LUAC_NUM) {
            return error.FloatFormatMismatch;
        }
    }

    fn readProto(self: *Reader, parentSource: []const u8, alloc: std.mem.Allocator) error{OutOfMemory}!*Prototype {
        var source = self.readString();
        if (eql(u8, source, "")) {
            source = parentSource;
        }

        var proto = try alloc.create(Prototype);
        proto.source = source;
        proto.lineDefined = self.readUint32();
        proto.lastLineDefined = self.readUint32();
        proto.numParams = self.readByte();
        proto.isVararg = self.readByte();
        proto.maxStackSize = self.readByte();
        proto.code = try self.readCode(alloc);
        proto.constants = try self.readConstants(alloc);
        proto.upvalues = try self.readUpvalues(alloc);
        proto.protos = try self.readProtos(source, alloc);
        proto.lineInfo = try self.readLineInfo(alloc);
        proto.locVars = try self.readLocVars(alloc);
        proto.upvalueNames = try self.readUpvalueNames(alloc);

        return proto;
    }

    fn readCode(self: *Reader, alloc: std.mem.Allocator) ![]u32 {
        var code = try alloc.alloc(u32, self.readUint32());
        for (0..code.len) |i| {
            code[i] = self.readUint32();
        }

        return code;
    }

    fn readConstants(self: *Reader, alloc: std.mem.Allocator) ![]Constant {
        var constants = try alloc.alloc(Constant, self.readUint32());
        for (0..constants.len) |i| {
            constants[i] = self.readConstant();
        }

        return constants;
    }

    fn readConstant(self: *Reader) Constant {
        return switch (self.readByte()) {
            TAG_NIL => Constant{ .nil = {} },
            TAG_BOOLEAN => Constant{ .boolean = (self.readByte() != 0) },
            TAG_INTEGER => Constant{ .integer = self.readLuaInteger() },
            TAG_NUMBER => Constant{ .number = self.readLuaNumber() },
            TAG_SHORT_STR => Constant{ .shortStr = self.readString() },
            TAG_LONG_STR => Constant{ .longStr = self.readString() },
            else => unreachable,
        };
    }

    fn readUpvalues(self: *Reader, alloc: std.mem.Allocator) ![]Upvalue {
        var upvalues = try alloc.alloc(Upvalue, self.readUint32());
        for (0..upvalues.len) |i| {
            upvalues[i] = Upvalue{
                .instack = self.readByte(),
                .idx = self.readByte(),
            };
        }

        return upvalues;
    }

    fn readProtos(self: *Reader, parentSource: []const u8, alloc: std.mem.Allocator) ![]*Prototype {
        var protos = try alloc.alloc(*Prototype, self.readUint32());
        for (0..protos.len) |i| {
            protos[i] = try self.readProto(parentSource, alloc);
        }

        return protos;
    }

    fn readLineInfo(self: *Reader, alloc: std.mem.Allocator) ![]u32 {
        var lineInfo = try alloc.alloc(u32, self.readUint32());
        for (0..lineInfo.len) |i| {
            lineInfo[i] = self.readUint32();
        }

        return lineInfo;
    }

    fn readLocVars(self: *Reader, alloc: std.mem.Allocator) ![]LocVar {
        var locVars = try alloc.alloc(LocVar, self.readUint32());
        for (0..locVars.len) |i| {
            locVars[i] = LocVar{
                .varName = self.readString(),
                .startPC = self.readUint32(),
                .endPC = self.readUint32(),
            };
        }

        return locVars;
    }

    fn readUpvalueNames(self: *Reader, alloc: std.mem.Allocator) ![][]const u8 {
        var upvalueNames = try alloc.alloc([]const u8, self.readUint32());
        for (0..upvalueNames.len) |i| {
            upvalueNames[i] = self.readString();
        }

        return upvalueNames;
    }
};

pub fn undump(data: []const u8, alloc: std.mem.Allocator) !*Prototype {
    var reader = Reader{ .data = data };
    try reader.checkHeader();
    _ = reader.readByte();
    return reader.readProto("", alloc);
}

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

const OpCodeMode = enum {
    IABC,
    IABx,
    IAsBx,
    IAx,
};

const OpCodeEnum = enum {
    OP_MOVE,
    OP_LOADK,
    OP_LOADKX,
    OP_LOADBOOL,
    OP_LOADNIL,
    OP_GETUPVAL,
    OP_GETTABUP,
    OP_GETTABLE,
    OP_SETTABUP,
    OP_SETUPVAL,
    OP_SETTABLE,
    OP_NEWTABLE,
    OP_SELF,
    OP_ADD,
    OP_SUB,
    OP_MUL,
    OP_MOD,
    OP_POW,
    OP_DIV,
    OP_IDIV,
    OP_BAND,
    OP_BOR,
    OP_BXOR,
    OP_SHL,
    OP_SHR,
    OP_UNM,
    OP_BNOT,
    OP_NOT,
    OP_LEN,
    OP_CONCAT,
    OP_JMP,
    OP_EQ,
    OP_LT,
    OP_LE,
    OP_TEST,
    OP_TESTSET,
    OP_CALL,
    OP_TAILCALL,
    OP_RETURN,
    OP_FORLOOP,
    OP_FORPREP,
    OP_TFORCALL,
    OP_TFORLOOP,
    OP_SETLIST,
    OP_CLOSURE,
    OP_VARARG,
    OP_EXTRAARG,
};

const OpCodeType = enum {
    OpArgN,
    OpArgU,
    OpArgR,
    OpArgK,
};

pub const Instruction = struct {
    data: u32,

    const MAXARG_Bx: isize = 1 << 18 - 1;
    const MAXARG_sBx: isize = MAXARG_Bx >> 1;

    fn opcode(self: Instruction) usize {
        return @as(usize, @intCast(self.data & 0x3F));
    }

    pub fn opName(self: Instruction) []const u8 {
        return opcodes[self.opcode()].name;
    }

    pub fn opMode(self: Instruction) OpCodeMode {
        return opcodes[self.opcode()].opMode;
    }

    pub fn bMode(self: Instruction) OpCodeType {
        return opcodes[self.opcode()].argBMode;
    }

    pub fn cMode(self: Instruction) OpCodeType {
        return opcodes[self.opcode()].argCMode;
    }

    pub fn ABC(self: Instruction) struct { isize, isize, isize } {
        const a = @as(isize, @intCast(self.data >> 6 & 0xFF));
        const c = @as(isize, @intCast(self.data >> 14 & 0x1FF));
        const b = @as(isize, @intCast(self.data >> 23 & 0x1FF));
        return .{ a, b, c };
    }

    pub fn ABx(self: Instruction) struct { isize, isize } {
        const a = @as(isize, @intCast(self.data >> 6 & 0xFF));
        const bx = @as(isize, @intCast(self.data >> 14));
        return .{ a, bx };
    }

    pub fn AsBx(self: Instruction) struct { isize, isize } {
        const result = self.ABx();
        const a = result[0];
        const bx = result[1] - MAXARG_sBx;
        return .{ a, bx };
    }

    pub fn Ax(self: Instruction) isize {
        return @as(isize, @intCast(self.data >> 6));
    }
};

const OpCode = struct {
    testFlag: bool,
    setAflag: bool,
    argBMode: OpCodeType,
    argCMode: OpCodeType,
    opMode: OpCodeMode,
    name: []const u8,
};

var opcodes = [_]OpCode{
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "MOVE    " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgN, .opMode = .IABx, .name = "LOADK   " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgN, .argCMode = .OpArgN, .opMode = .IABx, .name = "LOADKX  " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "LOADBOOL" },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "LOADNIL " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "GETUPVAL" },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgK, .opMode = .IABC, .name = "GETTABUP" },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgK, .opMode = .IABC, .name = "GETTABLE" },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SETTABUP" },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "SETUPVAL" },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SETTABLE" },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "NEWTABLE" },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgK, .opMode = .IABC, .name = "SELF    " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "ADD     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SUB     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "MUL     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "MOD     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "POW     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "DIV     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "IDIV    " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "BAND    " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "BOR     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "BXOR    " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SHL     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SHR     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "UNM     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "BNOT    " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "NOT     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "LEN     " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgR, .opMode = .IABC, .name = "CONCAT  " },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "JMP     " },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "EQ      " },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "LT      " },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "LE      " },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgN, .argCMode = .OpArgU, .opMode = .IABC, .name = "TEST    " },
    OpCode{ .testFlag = true, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgU, .opMode = .IABC, .name = "TESTSET " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "CALL    " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "TAILCALL" },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "RETURN  " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "FORLOOP " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "FORPREP " },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgN, .argCMode = .OpArgU, .opMode = .IABC, .name = "TFORCALL" },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "TFORLOOP" },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "SETLIST " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABx, .name = "CLOSURE " },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "VARARG  " },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IAx, .name = "EXTRAARG" },
};
