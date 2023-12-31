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

pub const Constant = LuaValue;

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
            TAG_NUMBER => Constant{ .float = self.readLuaNumber() },
            TAG_SHORT_STR => Constant{ .string = self.readString() },
            TAG_LONG_STR => Constant{ .string = self.readString() },
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

    const MAXARG_Bx = (1 << 18) - 1;
    const MAXARG_sBx = MAXARG_Bx >> 1;

    fn opcode(self: Instruction) usize {
        return @as(usize, @intCast(self.data & 0x3F));
    }

    pub fn opEnum(self: Instruction) OpCodeEnum {
        return @enumFromInt(self.opcode());
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

    pub fn execute(self: Instruction, vm: *LuaVM) !void {
        const maybeAction = opcodes[self.opcode()].action;
        if (maybeAction) |action| {
            try action(self, vm);
        } else {
            std.debug.print("instruction with no action, ${s}\n", .{self.opName()});
            return error.UnknownInstruction;
        }
    }
};

const VMError = error{
    ToDo,
    OutOfMemory,
    StackOverflow,
    StackUnderflow,
    InvalidIndex,
    ArithmeticError,
    LengthError,
    NotATable,
    TableIndexIsNil,
    TableIndexIsNan,
};

const OpCode = struct {
    testFlag: bool,
    setAflag: bool,
    argBMode: OpCodeType,
    argCMode: OpCodeType,
    opMode: OpCodeMode,
    name: []const u8,
    action: ?*const fn (i: Instruction, vm: *LuaVM) VMError!void,
};

var opcodes = [_]OpCode{
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "MOVE    ", .action = VMInstuction.move },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgN, .opMode = .IABx, .name = "LOADK   ", .action = VMInstuction.loadK },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgN, .argCMode = .OpArgN, .opMode = .IABx, .name = "LOADKX  ", .action = VMInstuction.loadKx },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "LOADBOOL", .action = VMInstuction.loadBool },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "LOADNIL ", .action = VMInstuction.loadNil },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "GETUPVAL", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgK, .opMode = .IABC, .name = "GETTABUP", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgK, .opMode = .IABC, .name = "GETTABLE", .action = VMInstuction.getTable },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SETTABUP", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "SETUPVAL", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SETTABLE", .action = VMInstuction.setTable },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "NEWTABLE", .action = VMInstuction.newTable },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgK, .opMode = .IABC, .name = "SELF    ", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "ADD     ", .action = VMInstuction.add },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SUB     ", .action = VMInstuction.sub },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "MUL     ", .action = VMInstuction.mul },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "MOD     ", .action = VMInstuction.mod },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "POW     ", .action = VMInstuction.pow },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "DIV     ", .action = VMInstuction.div },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "IDIV    ", .action = VMInstuction.idiv },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "BAND    ", .action = VMInstuction.band },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "BOR     ", .action = VMInstuction.bor },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "BXOR    ", .action = VMInstuction.bxor },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SHL     ", .action = VMInstuction.shl },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "SHR     ", .action = VMInstuction.shr },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "UNM     ", .action = VMInstuction.unm },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "BNOT    ", .action = VMInstuction.bnot },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "NOT     ", .action = VMInstuction._not },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IABC, .name = "LEN     ", .action = VMInstuction._len },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgR, .opMode = .IABC, .name = "CONCAT  ", .action = VMInstuction.concat },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "JMP     ", .action = VMInstuction.jmp },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "EQ      ", .action = VMInstuction.eq },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "LT      ", .action = VMInstuction.lt },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgK, .argCMode = .OpArgK, .opMode = .IABC, .name = "LE      ", .action = VMInstuction.le },
    OpCode{ .testFlag = true, .setAflag = false, .argBMode = .OpArgN, .argCMode = .OpArgU, .opMode = .IABC, .name = "TEST    ", .action = VMInstuction._test },
    OpCode{ .testFlag = true, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgU, .opMode = .IABC, .name = "TESTSET ", .action = VMInstuction.testSet },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "CALL    ", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "TAILCALL", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "RETURN  ", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "FORLOOP ", .action = VMInstuction.forLoop },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "FORPREP ", .action = VMInstuction.forPrep },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgN, .argCMode = .OpArgU, .opMode = .IABC, .name = "TFORCALL", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgR, .argCMode = .OpArgN, .opMode = .IAsBx, .name = "TFORLOOP", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IABC, .name = "SETLIST ", .action = VMInstuction.setList },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABx, .name = "CLOSURE ", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = true, .argBMode = .OpArgU, .argCMode = .OpArgN, .opMode = .IABC, .name = "VARARG  ", .action = VMInstuction.todo },
    OpCode{ .testFlag = false, .setAflag = false, .argBMode = .OpArgU, .argCMode = .OpArgU, .opMode = .IAx, .name = "EXTRAARG", .action = VMInstuction.todo },
};

const LuaType = enum(i8) {
    LUA_TNONE = -1,
    LUA_TNIL,
    LUA_TBOOLEAN,
    LUA_TLIGHTUSERDATA,
    LUA_TNUMBER,
    LUA_TSTRING,
    LUA_TTABLE,
    LUA_TFUNCTION,
    LUA_TUSERDATA,
    LUA_TTHREAD,
};

pub const LuaValue = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    table: *LuaTable,

    fn isNil(self: LuaValue) bool {
        return switch (self) {
            .nil => true,
            else => false,
        };
    }

    fn isNan(self: LuaValue) bool {
        return switch (self) {
            .float => |f| std.math.isNan(f),
            else => false,
        };
    }
};

fn typeOf(val: LuaValue) LuaType {
    return switch (val) {
        .nil => .LUA_TNIL,
        .boolean => .LUA_TBOOLEAN,
        .integer => .LUA_TNUMBER,
        .float => .LUA_TNUMBER,
        .string => .LUA_TSTRING,
        .table => .LUA_TTABLE,
    };
}

const LuaStack = struct {
    slots: std.ArrayList(LuaValue),
    top: usize,

    fn new(size: usize, alloc: std.mem.Allocator) !*LuaStack {
        var stack = try alloc.create(LuaStack);
        var slots = try std.ArrayList(LuaValue).initCapacity(alloc, size);
        stack.slots = slots;
        stack.top = 0;
        return stack;
    }

    fn check(self: *LuaStack, n: usize) !void {
        const free = self.slots.capacity - self.top;
        var i = free;
        while (i < n) : (i += 1) {
            try self.slots.append(LuaValue{ .nil = {} });
        }
    }

    fn push(self: *LuaStack, val: LuaValue) !void {
        if (self.top == self.slots.capacity) {
            return error.StackOverflow;
        }
        try self.slots.insert(self.top, val);
        self.top += 1;
    }

    fn pop(self: *LuaStack) !LuaValue {
        if (self.top < 1) {
            return error.StackUnderflow;
        }
        self.top -= 1;
        const val = self.slots.items[self.top];
        self.slots.items[self.top] = LuaValue{ .nil = {} };
        return val;
    }

    fn absIndex(self: *LuaStack, idx: isize) usize {
        if (idx >= 0) {
            return @as(usize, @intCast(idx));
        }
        return @as(usize, @intCast(idx + @as(isize, @intCast(self.top)) + 1));
    }

    fn isValid(self: *LuaStack, idx: isize) bool {
        const absIdx = self.absIndex(idx);
        return absIdx > 0 and absIdx <= self.top;
    }

    fn get(self: *LuaStack, idx: isize) LuaValue {
        const absIdx = self.absIndex(idx);
        if (absIdx > 0 and absIdx <= self.top) {
            return self.slots.items[absIdx - 1];
        }
        return LuaValue{ .nil = {} };
    }

    fn set(self: *LuaStack, idx: isize, val: LuaValue) !void {
        const absIdx = self.absIndex(idx);
        if (absIdx > 0 and absIdx <= self.top) {
            self.slots.items[absIdx - 1] = val;
            return;
        }
        return error.InvalidIndex;
    }

    fn reverse(self: *LuaStack, start: usize, end: usize) void {
        var slots = self.slots.items;
        var from = start;
        var to = end;
        while (from < to) {
            const tmp = slots[from];
            slots[from] = slots[to];
            slots[to] = tmp;
            from += 1;
            to -= 1;
        }
    }
};

pub const LuaState = struct {
    alloc: std.mem.Allocator,
    stack: *LuaStack,
    proto: *Prototype,
    pc: isize,

    pub fn new(stackSize: usize, proto: *Prototype, alloc: std.mem.Allocator) !*LuaState {
        var state = try alloc.create(LuaState);
        var stack = try LuaStack.new(stackSize, alloc);
        state.alloc = alloc;
        state.stack = stack;
        state.proto = proto;
        state.pc = 0;
        return state;
    }

    pub fn getTop(self: *LuaState) usize {
        return self.stack.top;
    }

    pub fn absIndex(self: *LuaState, idx: isize) usize {
        return self.stack.absIndex(idx);
    }

    pub fn checkStack(self: *LuaState, n: usize) !bool {
        try self.stack.check(n);
        return true;
    }

    pub fn pop(self: *LuaState, n: isize) !void {
        try self.setTop(-n - 1);
    }

    pub fn copy(self: *LuaState, fromIdx: isize, toIdx: isize) !void {
        const val = self.stack.get(fromIdx);
        try self.stack.set(toIdx, val);
    }

    pub fn pushValue(self: *LuaState, idx: isize) !void {
        const val = self.stack.get(idx);
        try self.stack.push(val);
    }

    pub fn replace(self: *LuaState, idx: isize) !void {
        const val = try self.stack.pop();
        try self.stack.set(idx, val);
    }

    pub fn insert(self: *LuaState, idx: isize) void {
        self.rotate(idx, 1);
    }

    pub fn remove(self: *LuaState, idx: isize) !void {
        self.rotate(idx, -1);
        try self.pop(1);
    }

    pub fn rotate(self: *LuaState, idx: isize, n: isize) void {
        const t = self.stack.top - 1;
        const p = self.stack.absIndex(idx) - 1;

        var m = if (n >= 0) t - @as(usize, @intCast(n)) else p + @as(usize, @intCast(-n)) - 1;
        self.stack.reverse(p, m);
        self.stack.reverse(m + 1, t);
        self.stack.reverse(p, t);
    }

    pub fn setTop(self: *LuaState, idx: isize) !void {
        const newTop = self.stack.absIndex(idx);
        if (newTop < 0) {
            return error.StackUnderflow;
        }
        var n = @as(isize, @intCast(self.stack.top)) - @as(isize, @intCast(newTop));
        if (n > 0) {
            var i: isize = 0;
            while (i < n) : (i += 1) {
                _ = try self.stack.pop();
            }
        } else if (n < 0) {
            var i: isize = 0;
            while (i > n) : (i -= 1) {
                try self.stack.push(LuaValue{ .nil = {} });
            }
        }
    }

    pub fn pushNil(self: *LuaState) !void {
        try self.stack.push(LuaValue{ .nil = {} });
    }

    pub fn pushBoolean(self: *LuaState, b: bool) !void {
        try self.stack.push(LuaValue{ .boolean = b });
    }

    pub fn pushInteger(self: *LuaState, n: i64) !void {
        try self.stack.push(LuaValue{ .integer = n });
    }

    pub fn pushNumber(self: *LuaState, n: f64) !void {
        try self.stack.push(LuaValue{ .float = n });
    }

    pub fn pushString(self: *LuaState, s: []const u8) !void {
        try self.stack.push(LuaValue{ .string = s });
    }

    pub fn typeName(self: *LuaState, tp: LuaType) []const u8 {
        _ = self;
        return switch (tp) {
            .LUA_TNONE => "no value",
            .LUA_TNIL => "nil",
            .LUA_TBOOLEAN => "boolean",
            .LUA_TLIGHTUSERDATA => "userdata",
            .LUA_TNUMBER => "number",
            .LUA_TSTRING => "string",
            .LUA_TTABLE => "table",
            .LUA_TFUNCTION => "function",
            .LUA_TUSERDATA => "thread",
            .LUA_TTHREAD => "userdata",
        };
    }

    pub fn getType(self: *LuaState, idx: isize) LuaType {
        if (self.stack.isValid(idx)) {
            const val = self.stack.get(idx);
            return typeOf(val);
        }

        return .LUA_TNONE;
    }

    pub fn isNone(self: *LuaState, idx: isize) bool {
        return self.getType(idx) == .LUA_TNONE;
    }

    pub fn isNil(self: *LuaState, idx: isize) bool {
        return self.getType(idx) == .LUA_TNIL;
    }

    pub fn isNoneOrNil(self: *LuaState, idx: isize) bool {
        const t = self.getType(idx);
        return t == .LUA_TNONE or t == .LUA_TNIL;
    }

    pub fn isBoolean(self: *LuaState, idx: isize) bool {
        return self.getType(idx) == .LUA_TBOOLEAN;
    }

    pub fn isString(self: *LuaState, idx: isize) bool {
        const t = self.getType(idx);
        return t == .LUA_TSTRING or t == .LUA_TNUMBER;
    }

    pub fn isNumber(self: *LuaState, idx: isize) bool {
        const result = self.toNumberX(idx);
        return result[1];
    }

    pub fn isInteger(self: *LuaState, idx: isize) bool {
        const val = self.stack.get(idx);
        return switch (val) {
            .integer => true,
            else => false,
        };
    }

    pub fn toBoolean(self: *LuaState, idx: isize) bool {
        const val = self.stack.get(idx);
        return convertToBoolean(val);
    }

    pub fn toNumber(self: *LuaState, idx: isize) f64 {
        const result = self.toNumberX(idx);
        return result[0];
    }

    pub fn toNumberX(self: *LuaState, idx: isize) struct { f64, bool } {
        const val = self.stack.get(idx);
        return convertToFloat(val);
    }

    pub fn toInteger(self: *LuaState, idx: isize) f64 {
        const result = self.toIntegerX(idx);
        return result[0];
    }

    pub fn toIntegerX(self: *LuaState, idx: isize) struct { f64, bool } {
        const val = self.stack.get(idx);
        return convertToInteger(val);
    }

    pub fn toString(self: *LuaState, idx: isize) []const u8 {
        const result = self.toStringX(idx);
        return result[0];
    }

    pub fn toStringX(self: *LuaState, idx: isize) struct { []const u8, bool } {
        const val = self.stack.get(idx);
        return switch (val) {
            .string => |s| .{ s, true },
            .integer => |n| blk: {
                const s = std.fmt.allocPrint(self.alloc, "{d}", .{n}) catch break :blk .{ "", false };
                break :blk .{ s, true };
            },
            .float => |n| blk: {
                const s = std.fmt.allocPrint(self.alloc, "{d}", .{n}) catch break :blk .{ "", false };
                break :blk .{ s, true };
            },
            else => .{ "", false },
        };
    }

    pub fn arith(self: *LuaState, op: ArithOp) !void {
        var a: LuaValue = undefined;
        var b: LuaValue = undefined;

        b = try self.stack.pop();
        if (op != .LUA_OPUNM and op != .LUA_OPBNOT) {
            a = try self.stack.pop();
        } else {
            a = b;
        }

        const operator = operators[@as(usize, @intFromEnum(op))];
        const result = _arith(a, b, operator);
        if (result) |val| {
            try self.stack.push(val);
        } else {
            return error.ArithmeticError;
        }
    }

    pub fn compare(self: *LuaState, idx1: isize, idx2: isize, op: CompareOp) bool {
        const a = self.stack.get(idx1);
        const b = self.stack.get(idx2);

        return switch (op) {
            .LUA_OPEQ => _eq(a, b),
            .LUA_OPLT => _lt(a, b),
            .LUA_OPLE => _le(a, b),
        };
    }

    pub fn len(self: *LuaState, idx: isize) !void {
        const val = self.stack.get(idx);
        switch (val) {
            .string => |s| {
                try self.stack.push(LuaValue{ .integer = @as(i64, @intCast(s.len)) });
            },
            .table => |t| {
                try self.stack.push(LuaValue{ .integer = @as(i64, @intCast(t.len())) });
            },
            else => return error.LengthError,
        }
    }

    pub fn concat(self: *LuaState, n: isize) !void {
        if (n == 0) {
            try self.stack.push(LuaValue{ .string = "" });
        } else if (n >= 2) {
            var i: isize = 1;
            while (i < n) : (i += 1) {
                if (self.isString(-1) and self.isString(-2)) {
                    const s2 = self.toString(-1);
                    const s1 = self.toString(-2);
                    _ = try self.stack.pop();
                    _ = try self.stack.pop();
                    const s = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ s1, s2 });
                    try self.stack.push(LuaValue{ .string = s });
                    continue;
                }
            }
        }
        // n = 1, do nothing
    }

    pub fn printStack(self: *LuaState, writer: anytype) !void {
        var top = self.getTop();
        var i: isize = 1;
        while (i <= top) : (i += 1) {
            const t = self.getType(i);
            switch (t) {
                .LUA_TBOOLEAN => try writer.print("[{any}]", .{self.toBoolean(i)}),
                .LUA_TNUMBER => try writer.print("[{d}]", .{self.toNumber(i)}),
                .LUA_TSTRING => try writer.print("[\"{s}\"]", .{self.toString(i)}),
                else => try writer.print("[{s}]", .{self.typeName(t)}),
            }
        }
        try writer.print("\n", .{});
    }

    pub fn getPC(self: *LuaState) isize {
        return self.pc;
    }

    fn addPC(self: *LuaState, n: isize) !void {
        self.pc += n;
    }

    pub fn fetch(self: *LuaState) u32 {
        const i = self.proto.code[@as(usize, @intCast(self.pc))];
        self.pc += 1;
        return i;
    }

    fn getConst(self: *LuaState, idx: isize) !void {
        const c = self.proto.constants[@as(usize, @intCast(idx))];
        try self.stack.push(c);
    }

    fn getRK(self: *LuaState, idx: isize) !void {
        if (idx > 0xFF) {
            try self.getConst(idx & 0xFF);
        } else {
            try self.pushValue(idx + 1);
        }
    }

    pub fn createTable(self: *LuaState, nArr: usize, nRec: usize) !void {
        const t = try LuaTable.new(nArr, nRec, self.alloc);
        try self.stack.push(LuaValue{ .table = t });
    }

    pub fn newTable(self: *LuaState) !void {
        try self.createTable(0, 0);
    }

    pub fn _getTable(self: *LuaState, t: LuaValue, k: LuaValue) !LuaType {
        switch (t) {
            .table => |tbl| {
                const v = tbl.get(k);
                try self.stack.push(v);
                return typeOf(v);
            },
            else => {
                return error.NotATable;
            },
        }
    }

    pub fn getTable(self: *LuaState, idx: isize) !void {
        const t = self.stack.get(idx);
        const k = try self.stack.pop();
        _ = try self._getTable(t, k);
    }

    pub fn getField(self: *LuaState, idx: isize, k: []const u8) !LuaType {
        const t = self.stack.get(idx);
        return self._getTable(t, LuaValue{ .string = k });
    }

    pub fn getI(self: *LuaState, idx: isize, i: i64) !LuaType {
        const t = self.stack.get(idx);
        return self._getTable(t, LuaValue{ .integer = i });
    }

    pub fn setTable(self: *LuaState, idx: isize) !void {
        const t = self.stack.get(idx);
        const v = try self.stack.pop();
        const k = try self.stack.pop();
        return self._setTable(t, k, v);
    }

    pub fn _setTable(self: *LuaState, t: LuaValue, k: LuaValue, v: LuaValue) !void {
        _ = self;
        switch (t) {
            .table => |tbl| {
                try tbl.put(k, v);
                return;
            },
            else => {
                return error.NotATable;
            },
        }
    }

    pub fn setField(self: *LuaState, idx: isize, k: []const u8) !void {
        const t = self.stack.get(idx);
        const v = try self.stack.pop();
        return self._setTable(t, LuaValue{ .string = k }, v);
    }

    pub fn setI(self: *LuaState, idx: isize, i: i64) !void {
        const t = self.stack.get(idx);
        const v = try self.stack.pop();
        return self._setTable(t, LuaValue{ .integer = i }, v);
    }
};

fn convertToBoolean(val: LuaValue) bool {
    return switch (val) {
        .nil => false,
        .boolean => |b| b,
        else => true,
    };
}

fn iFloorDiv(a: i64, b: i64) i64 {
    return @divFloor(a, b);
}

fn fFloorDiv(a: f64, b: f64) f64 {
    return @divFloor(a, b);
}

test "div" {
    try expect(iFloorDiv(5, 3) == 1);
    try expect(iFloorDiv(-5, 3) == -2);
    try expect(fFloorDiv(5, -3.0) == -2.0);
    try expect(fFloorDiv(-5.0, -3.0) == 1.0);
}

fn iMod(a: i64, b: i64) i64 {
    return @mod(a, b);
}

fn fMod(a: f64, b: f64) f64 {
    return @mod(a, b);
}

test "mod" {
    try expect(iMod(5, 3) == 2);
    try expect(iMod(-5, 3) == 1);
    try expect(fMod(5, -3.0) == 2.0);
    try expect(fMod(-5.0, -3.0) == -2.0);
}

fn shiftLeft(a: i64, n: i64) i64 {
    if (n >= 0) {
        return a << @as(u6, @intCast(n));
    } else {
        return shiftRight(a, -n);
    }
}

fn shiftRight(a: i64, n: i64) i64 {
    if (n >= 0) {
        return @as(i64, @intCast(@as(u64, @bitCast(a)) >> @as(u6, @intCast(n))));
    } else {
        return shiftLeft(a, -n);
    }
}

test "shift" {
    try expect(shiftRight(-1, 63) == 1);
    try expect(shiftLeft(2, -1) == 1);
}

fn floatToInteger(f: f64) struct { i64, bool } {
    const i = @as(i64, @intFromFloat(f));
    return .{ i, @as(f64, @floatFromInt(i)) == f };
}

fn parseInteger(str: []const u8) struct { i64, bool } {
    const i = std.fmt.parseInt(i64, str, 10) catch return .{ 0, false };
    return .{ i, true };
}

fn parseFloat(str: []const u8) struct { f64, bool } {
    const f = std.fmt.parseFloat(f64, str) catch return .{ 0, false };
    return .{ f, true };
}

fn convertToFloat(val: LuaValue) struct { f64, bool } {
    return switch (val) {
        .float => |n| .{ n, true },
        .integer => |n| .{ @as(f64, @floatFromInt(n)), true },
        .string => |s| parseFloat(s),
        else => .{ 0, false },
    };
}

fn convertToInteger(val: LuaValue) struct { i64, bool } {
    return switch (val) {
        .integer => |n| .{ n, true },
        .float => |n| .{ @as(i64, @intFromFloat(n)), true },
        .string => |s| _stringToInteger(s),
        else => .{ 0, false },
    };
}

fn _stringToInteger(s: []const u8) struct { i64, bool } {
    const iResult = parseInteger(s);
    if (iResult[1]) {
        return iResult;
    }
    const fResult = parseFloat(s);
    if (fResult[1]) {
        return floatToInteger(fResult[0]);
    }
    return .{ 0, false };
}

const ArithOp = enum {
    LUA_OPADD,
    LUA_OPSUB,
    LUA_OPMUL,
    LUA_OPMOD,
    LUA_OPPOW,
    LUA_OPDIV,
    LUA_OPIDIV,
    LUA_OPBAND,
    LUA_OPBOR,
    LUA_OPBXOR,
    LUA_OPSHL,
    LUA_OPSHR,
    LUA_OPUNM,
    LUA_OPBNOT,
};

const CompareOp = enum {
    LUA_OPEQ,
    LUA_OPLT,
    LUA_OPLE,
};

fn iadd(a: i64, b: i64) i64 {
    return a + b;
}

fn fadd(a: f64, b: f64) f64 {
    return a + b;
}

fn isub(a: i64, b: i64) i64 {
    return a - b;
}

fn fsub(a: f64, b: f64) f64 {
    return a - b;
}

fn imul(a: i64, b: i64) i64 {
    return a * b;
}

fn fmul(a: f64, b: f64) f64 {
    return a * b;
}

fn imod(a: i64, b: i64) i64 {
    return iMod(a, b);
}

fn fmod(a: f64, b: f64) f64 {
    return fMod(a, b);
}

fn pow(a: f64, b: f64) f64 {
    return std.math.pow(f64, a, b);
}

fn div(a: f64, b: f64) f64 {
    return a / b;
}

fn iidiv(a: i64, b: i64) i64 {
    return iFloorDiv(a, b);
}

fn fidiv(a: f64, b: f64) f64 {
    return fFloorDiv(a, b);
}

fn band(a: i64, b: i64) i64 {
    return a & b;
}

fn bor(a: i64, b: i64) i64 {
    return a | b;
}

fn bxor(a: i64, b: i64) i64 {
    return a ^ b;
}

fn shl(a: i64, b: i64) i64 {
    return shiftLeft(a, b);
}

fn shr(a: i64, b: i64) i64 {
    return shiftRight(a, b);
}

fn iunm(a: i64, _: i64) i64 {
    return -a;
}

fn funm(a: f64, _: f64) f64 {
    return -a;
}

fn bnot(a: i64, _: i64) i64 {
    return ~a;
}

const Operator = struct {
    integerFunc: ?*const fn (i64, i64) i64,
    floatFunc: ?*const fn (f64, f64) f64,
};

const operators = [_]Operator{
    Operator{ .integerFunc = iadd, .floatFunc = fadd },
    Operator{ .integerFunc = isub, .floatFunc = fsub },
    Operator{ .integerFunc = imul, .floatFunc = fmul },
    Operator{ .integerFunc = imod, .floatFunc = fmod },
    Operator{ .integerFunc = null, .floatFunc = pow },
    Operator{ .integerFunc = null, .floatFunc = div },
    Operator{ .integerFunc = iidiv, .floatFunc = fidiv },
    Operator{ .integerFunc = band, .floatFunc = null },
    Operator{ .integerFunc = bor, .floatFunc = null },
    Operator{ .integerFunc = bxor, .floatFunc = null },
    Operator{ .integerFunc = shl, .floatFunc = null },
    Operator{ .integerFunc = shr, .floatFunc = null },
    Operator{ .integerFunc = iunm, .floatFunc = null },
    Operator{ .integerFunc = bnot, .floatFunc = null },
};

fn _arith(a: LuaValue, b: LuaValue, op: Operator) ?LuaValue {
    if (op.floatFunc == null) { // bitwise
        if (op.integerFunc) |integerFunc| {
            const aResult = convertToInteger(a);
            if (aResult[1]) {
                const x = aResult[0];
                const bResult = convertToInteger(b);
                if (bResult[1]) {
                    const y = bResult[0];
                    return LuaValue{ .integer = integerFunc(x, y) };
                }
            }
        }
    } else { // arith
        if (op.integerFunc) |integerFunc| { // add, sub, mul, mod, idiv, unm
            const aResult = convertToInteger(a);
            if (aResult[1]) {
                const x = aResult[0];
                const bResult = convertToInteger(b);
                if (bResult[1]) {
                    const y = bResult[0];
                    return LuaValue{ .integer = integerFunc(x, y) };
                }
            }
        }
        if (op.floatFunc) |floatFunc| {
            const aResult = convertToFloat(a);
            if (aResult[1]) {
                const x = aResult[0];
                const bResult = convertToFloat(b);
                if (bResult[1]) {
                    const y = bResult[0];
                    return LuaValue{ .float = floatFunc(x, y) };
                }
            }
        }
    }
    return null;
}

fn _eq(a: LuaValue, b: LuaValue) bool {
    return eqlLuaValue(a, b);
}

fn _lt(a: LuaValue, b: LuaValue) bool {
    switch (a) {
        .integer => |x| {
            return switch (b) {
                .integer => |y| x < y,
                .float => |y| @as(f64, @floatFromInt(x)) < y,
                else => false,
            };
        },
        .float => |x| {
            return switch (b) {
                .float => |y| x < y,
                .integer => |y| x < @as(f64, @floatFromInt(y)),
                else => false,
            };
        },
        .string => |x| {
            return switch (b) {
                .string => |y| _lt_string(x, y),
                else => false,
            };
        },
        else => return false,
    }
}

fn _le(a: LuaValue, b: LuaValue) bool {
    switch (a) {
        .integer => |x| {
            return switch (b) {
                .integer => |y| x <= y,
                .float => |y| @as(f64, @floatFromInt(x)) <= y,
                else => false,
            };
        },
        .float => |x| {
            return switch (b) {
                .float => |y| x <= y,
                .integer => |y| x <= @as(f64, @floatFromInt(y)),
                else => false,
            };
        },
        .string => |x| {
            return switch (b) {
                .string => |y| _le_string(x, y),
                else => false,
            };
        },
        else => return false,
    }
}

fn _lt_string(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }

    for (a, b) |x, y| {
        if (x >= y) {
            return false;
        }
    }

    return true;
}

fn _le_string(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }

    for (a, b) |x, y| {
        if (x > y) {
            return false;
        }
    }

    return true;
}

const LuaVM = LuaState;

const VMInstuction = struct {
    const todo = null;

    fn move(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1] + 1;
        try vm.copy(b, a);
    }

    fn jmp(i: Instruction, vm: *LuaVM) !void {
        const result = i.AsBx();
        const a = result[0];
        const sBx = result[1];
        try vm.addPC(sBx);
        if (a != 0) {
            return error.ToDo;
        }
    }

    fn loadNil(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1];
        try vm.pushNil();
        var ii: isize = a;
        while (ii <= a + b) : (ii += 1) {
            try vm.copy(-1, ii);
        }
        try vm.pop(1);
    }

    fn loadBool(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1];
        const c = result[2];
        try vm.pushBoolean(b != 0);
        try vm.replace(a);
        if (c != 0) {
            try vm.addPC(1);
        }
    }

    fn loadK(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABx();
        const a = result[0] + 1;
        const bx = result[1];
        try vm.getConst(bx);
        try vm.replace(a);
    }

    fn loadKx(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABx();
        const a = result[0] + 1;
        const ni = Instruction{ .data = vm.fetch() };
        const ax = ni.Ax();

        try vm.getConst(ax);
        try vm.replace(a);
    }

    fn _binaryArith(i: Instruction, vm: *LuaVM, op: ArithOp) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1];
        const c = result[2];

        try vm.getRK(b);
        try vm.getRK(c);
        try vm.arith(op);
        try vm.replace(a);
    }

    fn _unaryArith(i: Instruction, vm: *LuaVM, op: ArithOp) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1] + 1;

        try vm.pushValue(b);
        try vm.arith(op);
        try vm.replace(a);
    }

    fn add(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPADD);
    }

    fn sub(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPSUB);
    }

    fn mul(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPMUL);
    }

    fn mod(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPMOD);
    }

    fn pow(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPPOW);
    }

    fn div(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPDIV);
    }

    fn idiv(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPIDIV);
    }

    fn band(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPBAND);
    }

    fn bor(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPBOR);
    }

    fn bxor(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPBXOR);
    }

    fn shl(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPSHL);
    }

    fn shr(i: Instruction, vm: *LuaVM) !void {
        return _binaryArith(i, vm, .LUA_OPSHR);
    }

    fn unm(i: Instruction, vm: *LuaVM) !void {
        return _unaryArith(i, vm, .LUA_OPUNM);
    }

    fn bnot(i: Instruction, vm: *LuaVM) !void {
        return _unaryArith(i, vm, .LUA_OPBNOT);
    }

    fn _len(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1] + 1;
        try vm.len(b);
        try vm.replace(a);
    }

    fn concat(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1] + 1;
        const c = result[2] + 1;

        const n = c - b + 1;
        _ = try vm.checkStack(@as(usize, @intCast(n)));

        var ii: isize = b;
        while (ii <= c) : (ii += 1) {
            try vm.pushValue(ii);
        }
        try vm.concat(n);
        try vm.replace(a);
    }

    fn _compare(i: Instruction, vm: *LuaVM, op: CompareOp) !void {
        const result = i.ABC();
        const a = result[0];
        const b = result[1];
        const c = result[2];

        try vm.getRK(b);
        try vm.getRK(c);

        if (vm.compare(-2, -1, op) != (a != 0)) {
            try vm.addPC(1);
        }
        try vm.pop(2);
    }

    fn eq(i: Instruction, vm: *LuaVM) !void {
        return _compare(i, vm, .LUA_OPEQ);
    }

    fn lt(i: Instruction, vm: *LuaVM) !void {
        return _compare(i, vm, .LUA_OPLT);
    }

    fn le(i: Instruction, vm: *LuaVM) !void {
        return _compare(i, vm, .LUA_OPLE);
    }

    fn _not(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1] + 1;

        try vm.pushBoolean(!vm.toBoolean(b));
        try vm.replace(a);
    }

    fn testSet(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1] + 1;
        const c = result[1];

        if (vm.toBoolean(b) == (c != 0)) {
            try vm.copy(a, b);
        } else {
            try vm.addPC(1);
        }
    }

    fn _test(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const c = result[1];

        if (vm.toBoolean(a) != (c != 0)) {
            try vm.addPC(1);
        }
    }

    fn forPrep(i: Instruction, vm: *LuaVM) !void {
        const result = i.AsBx();
        const a = result[0] + 1;
        const sBx = result[1];

        // R(A) -= R(A+2);
        try vm.pushValue(a);
        try vm.pushValue(a + 2);
        try vm.arith(.LUA_OPSUB);
        try vm.replace(a);

        // pc += sBx
        try vm.addPC(sBx);
    }

    fn forLoop(i: Instruction, vm: *LuaVM) !void {
        const result = i.AsBx();
        const a = result[0] + 1;
        const sBx = result[1];

        // R(A) += R(A+2);
        try vm.pushValue(a);
        try vm.pushValue(a + 2);
        try vm.arith(.LUA_OPADD);
        try vm.replace(a);

        // R(A) <?= R(A+1)
        const isPositiveStep = vm.toNumber(a + 2) >= 0;
        if ((isPositiveStep and vm.compare(a, a + 1, .LUA_OPLE)) or (!isPositiveStep and vm.compare(a + 1, a, .LUA_OPLE))) {
            // pc += sBx
            try vm.addPC(sBx);
            // R(A+3) = R(A)
            try vm.copy(a, a + 3);
        }
    }

    fn newTable(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1];
        const c = result[2];

        try vm.createTable(fb2int(b), fb2int(c));
        try vm.replace(a);
    }

    fn getTable(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1] + 1;
        const c = result[2];

        try vm.getRK(c);
        try vm.getTable(b);
        try vm.replace(a);
    }

    fn setTable(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1];
        const c = result[2];

        try vm.getRK(b);
        try vm.getRK(c);
        try vm.setTable(a);
    }

    fn setList(i: Instruction, vm: *LuaVM) !void {
        const result = i.ABC();
        const a = result[0] + 1;
        const b = result[1];
        var c = result[2];

        if (c > 0) {
            c = c - 1;
        } else {
            const inst = Instruction{ .data = vm.fetch() };
            c = inst.Ax();
        }

        var idx: i64 = @as(i64, @intCast(c * LFIELDS_PER_FLUSH));
        var j: isize = 1;
        while (j <= b) : (j += 1) {
            idx += 1;
            try vm.pushValue(a + j);
            try vm.setI(a, idx);
        }
    }
};

const LFIELDS_PER_FLUSH = 50;

pub fn int2fb(_x: usize) usize {
    var x = @as(isize, @intCast(_x));
    var e: usize = 0;
    if (x < 8) {
        return x;
    }

    while (x >= (8 << 4)) {
        x = (x + 0xf) >> 4;
        e += 4;
    }

    while (x >= (8 << 1)) {
        x = (x + 1) >> 1;
        e += 1;
    }

    return ((e + 1) << 3) | (x - 8);
}

pub fn fb2int(_x: isize) usize {
    var x = @as(usize, @intCast(_x));
    if (x < 8) {
        return x;
    } else {
        return ((x & 7) + 8) << @as(u6, @intCast((x >> 3) - 1));
    }
}

test "fb2int, int2fb" {
    const int: isize = 200;
    const fb = int2fb(int);
    try expect(int == fb2int(fb));
}

const LuaValueContext = struct {
    pub fn hash(self: @This(), l: LuaValue) u64 {
        _ = self;
        return hashLuaValue(l);
    }
    pub fn eql(self: @This(), a: LuaValue, b: LuaValue) bool {
        _ = self;
        return eqlLuaValue(a, b);
    }
};

pub fn eqlLuaValue(a: LuaValue, b: LuaValue) bool {
    return switch (a) {
        .nil => {
            return switch (b) {
                .nil => true,
                else => false,
            };
        },
        .boolean => |x| {
            return switch (b) {
                .boolean => |y| x == y,
                else => false,
            };
        },
        .integer => |x| {
            return switch (b) {
                .integer => |y| x == y,
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                else => false,
            };
        },
        .float => |x| {
            return switch (b) {
                .float => |y| x == y,
                .integer => |y| x == @as(f64, @floatFromInt(y)),
                else => false,
            };
        },
        .string => |x| {
            return switch (b) {
                .string => |y| std.mem.eql(u8, x, y),
                else => false,
            };
        },
        .table => |x| {
            return switch (b) {
                .table => |y| x == y,
                else => false,
            };
        },
    };
}

pub fn hashLuaValue(l: LuaValue) u64 {
    return switch (l) {
        .nil => std.hash.Wyhash.hash(0, "nil"),
        .boolean => |b| std.hash.Wyhash.hash(0, std.mem.asBytes(&b)),
        .integer => |i| std.hash.Wyhash.hash(0, std.mem.asBytes(&i)),
        .float => |f| std.hash.Wyhash.hash(0, std.mem.asBytes(&f)),
        .string => |s| std.hash.Wyhash.hash(0, s),
        .table => |t| std.hash.Wyhash.hash(0, std.mem.asBytes(t)),
    };
}

pub fn LuaValueHashMap(comptime T: type) type {
    return std.HashMap(LuaValue, T, LuaValueContext, std.hash_map.default_max_load_percentage);
}

test "LuaValueHashMap" {
    var map = LuaValueHashMap(LuaValue).init(std.testing.allocator);
    defer map.deinit();

    try map.put(LuaValue{ .nil = {} }, LuaValue{ .integer = 12 });
    try map.put(LuaValue{ .boolean = true }, LuaValue{ .integer = 12 });
    try map.put(LuaValue{ .integer = 12 }, LuaValue{ .integer = 12 });
    try map.put(LuaValue{ .float = 12.34 }, LuaValue{ .integer = 12 });
    try map.put(LuaValue{ .string = "ok" }, LuaValue{ .integer = 12 });

    try map.put(LuaValue{ .string = "ok" }, LuaValue{ .integer = 13 });

    if (map.get(LuaValue{ .nil = {} })) |v| {
        try expect(eqlLuaValue(v, LuaValue{ .integer = 12 }));
    }
    if (map.get(LuaValue{ .boolean = true })) |v| {
        try expect(eqlLuaValue(v, LuaValue{ .integer = 12 }));
    }
    if (map.get(LuaValue{ .integer = 12 })) |v| {
        try expect(eqlLuaValue(v, LuaValue{ .integer = 12 }));
    }
    if (map.get(LuaValue{ .float = 12.34 })) |v| {
        try expect(eqlLuaValue(v, LuaValue{ .integer = 12 }));
    }
    if (map.get(LuaValue{ .string = "ok" })) |v| {
        try expect(eqlLuaValue(v, LuaValue{ .integer = 13 }));
    }
}

pub const LuaTable = struct {
    arr: std.ArrayList(LuaValue),
    _map: LuaValueHashMap(LuaValue),

    fn new(nArr: usize, nRec: usize, alloc: std.mem.Allocator) !*LuaTable {
        var t = try alloc.create(LuaTable);
        t.arr = std.ArrayList(LuaValue).init(alloc);
        if (nArr > 0) {
            try t.arr.ensureTotalCapacity(@as(u32, @intCast(nArr)));
        }
        t._map = LuaValueHashMap(LuaValue).init(alloc);
        if (nRec > 0) {
            try t._map.ensureTotalCapacity(@as(u32, @intCast(nRec)));
        }

        return t;
    }

    fn get(self: *LuaTable, _key: LuaValue) LuaValue {
        const key = _floatToInteger(_key);
        switch (key) {
            .integer => |i| {
                const idx = @as(usize, @intCast(i));
                if (idx >= 1 and idx <= self.arr.items.len) {
                    return self.arr.items[idx - 1];
                }
            },
            else => {},
        }
        const v = if (self._map.get(key)) |val| val else LuaValue{ .nil = {} };
        return v;
    }

    fn put(self: *LuaTable, _key: LuaValue, val: LuaValue) !void {
        if (_key.isNil()) {
            return error.TableIndexIsNil;
        }
        if (_key.isNan()) {
            return error.TableIndexIsNan;
        }
        const key = _floatToInteger(_key);

        switch (key) {
            .integer => |i| {
                const idx = @as(usize, @intCast(i));
                if (idx >= 1) {
                    const arrLen = self.arr.items.len;
                    if (idx <= arrLen) {
                        self.arr.items[idx - 1] = val;
                        if (idx == arrLen and val.isNil()) {
                            try self._shrinkArray();
                        }
                        return;
                    }
                    if (idx == arrLen + 1) {
                        _ = self._map.remove(key);
                        if (!val.isNil()) {
                            try self.arr.append(val);
                            try self._expandArray();
                        }
                    }
                }
            },
            else => {},
        }

        if (!val.isNil()) {
            try self._map.put(key, val);
        } else {
            _ = self._map.remove(key);
        }
    }

    fn len(self: *LuaTable) usize {
        return self.arr.items.len;
    }

    fn _shrinkArray(self: *LuaTable) !void {
        var i: usize = self.arr.items.len - 1;
        while (i >= 0) : (i -= 1) {
            if (self.arr.items[i].isNil()) {
                _ = self.arr.pop();
            }
        }
    }

    fn _expandArray(self: *LuaTable) !void {
        var i: i64 = @as(i64, @intCast(self.arr.items.len)) + 1;
        while (true) : (i += 1) {
            const idx = LuaValue{ .integer = i };
            if (self._map.get(idx)) |val| {
                _ = self._map.remove(idx);
                try self.arr.append(val);
            } else {
                break;
            }
        }
    }
};

fn _floatToInteger(key: LuaValue) LuaValue {
    switch (key) {
        .float => |f| {
            const result = floatToInteger(f);
            if (result[1]) {
                return LuaValue{ .integer = result[0] };
            }
        },
        else => {},
    }
    return key;
}
