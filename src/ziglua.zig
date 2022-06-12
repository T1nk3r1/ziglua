//! ziglua.zig: complete bindings around the Lua C API version 5.4.4
//! exposes all Lua functionality, with additional Zig helper functions

const std = @import("std");

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

const panic = std.debug.panic;

const Allocator = std.mem.Allocator;

// Types
//
// Lua constants and types are declared below in alphabetical order
// For constants that have a logical grouping (like Operators), Zig enums are used for type safety

/// The type of function that Lua uses for all internal allocations and frees
/// `data` is an opaque pointer to any data (the allocator), `ptr` is a pointer to the block being alloced/realloced/freed
/// `osize` is the original size or a code, and `nsize` is the new size
///
/// See https://www.lua.org/manual/5.4/manual.html#lua_Alloc for more details
pub const AllocFn = fn (data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque;

/// Operations supported by `Lua.arith()`
/// TODO: use longer names
pub const ArithOperator = enum(u4) {
    add = c.LUA_OPADD,
    sub = c.LUA_OPSUB,
    mul = c.LUA_OPMUL,
    div = c.LUA_OPDIV,
    idiv = c.LUA_OPIDIV,
    mod = c.LUA_OPMOD,
    pow = c.LUA_OPPOW,
    unm = c.LUA_OPUNM,
    bnot = c.LUA_OPBNOT,
    band = c.LUA_OPBAND,
    bor = c.LUA_OPBOR,
    bxor = c.LUA_OPBXOR,
    shl = c.LUA_OPSHL,
    shr = c.LUA_OPSHR,
};

/// Type for C functions
/// See https://www.lua.org/manual/5.4/manual.html#lua_CFunction for the protocol
/// TODO: we really are passing Zig functions, maybe call `Function` and use `func` for params?
pub const CFn = fn (state: ?*LuaState) callconv(.C) c_int;

/// Operations supported by `Lua.compare()`
pub const CompareOperator = enum(u2) {
    eq = c.LUA_OPEQ,
    lt = c.LUA_OPLT,
    le = c.LUA_OPLE,
};

/// The Lua debug interface structure
pub const DebugInfo = c.lua_Debug;

/// The superset of all errors returned from ziglua
pub const Error = error{
    /// A generic failure (used when a function can only fail in one way)
    Fail,
    /// A runtime error
    Runtime,
    /// A syntax error during precompilation
    Syntax,
    /// A memory allocation error
    Memory,
    /// An error while running the message handler
    MsgHandler,
    /// A file-releated error
    File,
};

/// Type for arrays of functions to be registered
pub const FnReg = struct {
    name: [:0]const u8,
    func: ?CFn,
};

/// Actions supported by `Lua.gc()`
pub const GCAction = enum(u5) {
    stop = c.LUA_GCSTOP,
    restart = c.LUA_GCRESTART,
    collect = c.LUA_GCCOLLECT,
    count = c.LUA_GCCOUNT,
    countb = c.LUA_GCCOUNTB,
    step = c.LUA_GCSTEP,
    is_running = c.LUA_GCISRUNNING,
    inc = c.LUA_GCINC,
    gen = c.LUA_GCGEN,
};

/// Type for debugging hook functions
pub const CHookFn = fn (state: ?*LuaState, ar: ?*DebugInfo) callconv(.C) void;

/// Specifies on which events the hook will be called
pub const HookMask = packed struct {
    call: bool = false,
    ret: bool = false,
    line: bool = false,
    count: bool = false,

    /// Converts a HookMask to an integer bitmask
    pub fn toInt(mask: HookMask) i32 {
        var bitmask: i32 = 0;
        if (mask.call) bitmask |= mask_call;
        if (mask.ret) bitmask |= mask_ret;
        if (mask.line) bitmask |= mask_line;
        if (mask.count) bitmask |= mask_count;
        return bitmask;
    }

    /// Converts an integer bitmask into a HookMask
    pub fn fromInt(mask: i32) HookMask {
        return .{
            .call = (mask & mask_call) != 0,
            .ret = (mask & mask_ret) != 0,
            .line = (mask & mask_line) != 0,
            .count = (mask & mask_count) != 0,
        };
    }
};

/// Hook event codes
pub const hook_call = c.LUA_HOOKCALL;
pub const hook_count = c.LUA_HOOKCOUNT;
pub const hook_line = c.LUA_HOOKLINE;
pub const hook_ret = c.LUA_HOOKRET;
pub const hook_tail_call = c.LUA_HOOKTAILCALL;

/// Type of integers in Lua (typically an i64)
pub const Integer = c.lua_Integer;

/// Type for continuation-function contexts (usually isize)
pub const KContext = isize;

/// Type for continuation functions
pub const CContFn = fn (state: ?*LuaState, status: c_int, ctx: KContext) callconv(.C) c_int;

/// Bitflag for the Lua standard libraries
pub const Libs = packed struct {
    base: bool = false,
    coroutine: bool = false,
    package: bool = false,
    string: bool = false,
    utf8: bool = false,
    table: bool = false,
    math: bool = false,
    io: bool = false,
    os: bool = false,
    debug: bool = false,
};

/// The type of the opaque structure that points to a thread and the state of a Lua interpreter
pub const LuaState = c.lua_State;

/// Lua types
/// Must be a signed integer because LuaType.none is -1
pub const LuaType = enum(i5) {
    none = c.LUA_TNONE,
    nil = c.LUA_TNIL,
    boolean = c.LUA_TBOOLEAN,
    light_userdata = c.LUA_TLIGHTUSERDATA,
    number = c.LUA_TNUMBER,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    function = c.LUA_TFUNCTION,
    userdata = c.LUA_TUSERDATA,
    thread = c.LUA_TTHREAD,
};

/// Modes used for `Lua.load()`
pub const Mode = enum(u2) { binary, text, binary_text };

/// Event masks
pub const mask_call = c.LUA_MASKCALL;
pub const mask_count = c.LUA_MASKCOUNT;
pub const mask_line = c.LUA_MASKLINE;
pub const mask_ret = c.LUA_MASKRET;

/// The maximum integer value that `Integer` can store
pub const max_integer = c.LUA_MAXINTEGER;

/// The minimum integer value that `Integer` can store
pub const min_integer = c.LUA_MININTEGER;

/// The minimum Lua stack available to a function
pub const min_stack = c.LUA_MINSTACK;

/// Option for multiple returns in `Lua.protectedCall()` and `Lua.call()`
pub const mult_return = c.LUA_MULTRET;

/// Type of floats in Lua (typically an f64)
pub const Number = c.lua_Number;

/// The type of the reader function used by `Lua.load()`
pub const CReaderFn = fn (state: ?*LuaState, data: ?*anyopaque, size: [*c]usize) callconv(.C) [*c]const u8;

/// Reference constants
pub const ref_nil = c.LUA_REFNIL;
pub const ref_no = c.LUA_NOREF;

/// Index of the regsitry in the stack (pseudo-index)
pub const registry_index = c.LUA_REGISTRYINDEX;

/// Index of globals in the registry
pub const ridx_globals = c.LUA_RIDX_GLOBALS;

/// Index of the main thread in the registry
pub const ridx_mainthread = c.LUA_RIDX_MAINTHREAD;

/// Status codes
/// Not public, because typically Status.ok is returned from a function implicitly;
/// Any function that returns an error usually returns a Zig error, and a void return
/// is an implicit Status.ok.
/// In the rare case that the status code is required from a function, an enum is
/// used for that specific function's return type
const Status = struct {
    pub const ok = c.LUA_OK;
    pub const yield = c.LUA_YIELD;
    pub const err_runtime = c.LUA_ERRRUN;
    pub const err_syntax = c.LUA_ERRSYNTAX;
    pub const err_memory = c.LUA_ERRMEM;
    pub const err_error = c.LUA_ERRERR;

    // Only used in loadFileX
    pub const err_file = c.LUA_ERRFILE;
};

/// The standard representation for file handles used by the standard IO library
pub const Stream = c.luaL_Stream;

/// The unsigned version of Integer
pub const Unsigned = c.lua_Unsigned;

/// The type of warning functions used by Lua to emit warnings
pub const CWarnFn = fn (data: ?*anyopaque, msg: [*c]const u8, to_cont: c_int) callconv(.C) void;

/// The type of the writer function used by `Lua.dump()`
pub const CWriterFn = fn (state: ?*LuaState, buf: ?*const anyopaque, size: usize, data: ?*anyopaque) callconv(.C) c_int;

/// A Zig wrapper around the Lua C API
/// Represents a Lua state or thread and contains the entire state of the Lua interpreter
pub const Lua = struct {
    allocator: ?*Allocator = null,
    state: *LuaState,

    /// Allows Lua to allocate memory using a Zig allocator passed in via data.
    /// See https://www.lua.org/manual/5.4/manual.html#lua_Alloc for more details
    fn alloc(data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
        _ = osize; // unused

        // just like malloc() returns a pointer "which is suitably aligned for any built-in type",
        // the memory allocated by this function should also be aligned for any type that Lua may
        // desire to allocate. use the largest alignment for the target
        const alignment = @alignOf(std.c.max_align_t);

        // the data pointer is an Allocator, so the @alignCast is safe
        const allocator = @ptrCast(*Allocator, @alignCast(@alignOf(Allocator), data));

        if (@ptrCast(?[*]align(alignment) u8, @alignCast(alignment, ptr))) |prev_ptr| {
            const prev_slice = prev_ptr[0..osize];

            // when nsize is zero the allocator must behave like free and return null
            if (nsize == 0) {
                allocator.free(prev_slice);
                return null;
            }

            // when nsize is not zero the allocator must behave like realloc
            const new_ptr = allocator.reallocAdvanced(prev_slice, alignment, nsize, .exact) catch return null;
            return new_ptr.ptr;
        } else {
            // ptr is null, allocate a new block of memory
            const new_ptr = allocator.alignedAlloc(u8, alignment, nsize) catch return null;
            return new_ptr.ptr;
        }
    }

    /// Initialize a Lua state with the given allocator
    pub fn init(allocator: Allocator) !Lua {
        // the userdata passed to alloc needs to be a pointer with a consistent address
        // so we allocate an Allocator struct to hold a copy of the allocator's data
        var allocator_ptr = allocator.create(Allocator) catch return Error.Memory;
        allocator_ptr.* = allocator;

        const state = c.lua_newstate(alloc, allocator_ptr) orelse return Error.Memory;
        return Lua{
            .allocator = allocator_ptr,
            .state = state,
        };
    }

    /// Deinitialize a Lua state and free all memory
    pub fn deinit(lua: *Lua) void {
        lua.close();
        if (lua.allocator) |a| {
            const allocator = a;
            allocator.destroy(a);
            lua.allocator = null;
        }
    }

    // Library functions
    //
    // Library functions are included in alphabetical order.
    // Each is kept similar to the original C API function while also making it easy to use from Zig

    /// Converts the acceptable index `index` into an equivalent absolute index
    pub fn absIndex(lua: *Lua, index: i32) i32 {
        return c.lua_absindex(lua.state, index);
    }

    /// Performs an arithmetic or bitwise operation over the value(s) at the top of the stack
    /// This function follows the semantics of the corresponding Lua operator
    pub fn arith(lua: *Lua, op: ArithOperator) void {
        c.lua_arith(lua.state, @enumToInt(op));
    }

    /// Sets a new panic function and returns the old one
    pub fn atPanic(lua: *Lua, panic_fn: CFn) ?CFn {
        return c.lua_atpanic(lua.state, panic_fn);
    }

    /// Calls a function (or any callable value)
    pub fn call(lua: *Lua, num_args: i32, num_results: i32) void {
        lua.callCont(num_args, num_results, 0, null);
    }

    /// Like `call`, but allows the called function to yield
    pub fn callCont(lua: *Lua, num_args: i32, num_results: i32, ctx: KContext, k: ?CContFn) void {
        c.lua_callk(lua.state, num_args, num_results, ctx, k);
    }

    /// Ensures that the stack has space for at least `n` extra arguments
    /// Returns an error if it cannot fulfil the request
    /// Never shrinks the stack
    pub fn checkStack(lua: *Lua, n: i32) !void {
        if (c.lua_checkstack(lua.state, n) == 0) return Error.Fail;
    }

    /// Release all Lua objects in the state and free all dynamic memory
    pub fn close(lua: *Lua) void {
        c.lua_close(lua.state);
    }

    /// Close the to-be-closed slot at the given `index` and set the value to nil
    pub fn closeSlot(lua: *Lua, index: i32) void {
        c.lua_closeslot(lua.state, index);
    }

    /// Compares two Lua values
    /// Returns true if the value at `index1` satisfies `op` when compared with the value at `index2`
    /// Returns false otherwise, or if any index is not valid
    pub fn compare(lua: *Lua, index1: i32, index2: i32, op: CompareOperator) bool {
        // TODO: perhaps support gt/ge by swapping args...
        return c.lua_compare(lua.state, index1, index2, @enumToInt(op)) != 0;
    }

    /// Concatenates the `n` values at the top of the stack, pops them, and leaves the result at the top
    /// If `n` is 1, the result is a single value on the stack (nothing changes)
    /// If `n` is 0, the result is the empty string
    pub fn concat(lua: *Lua, n: i32) void {
        c.lua_concat(lua.state, n);
    }

    /// Copies the element at `from_index` to the valid index `to_index`, replacing the value at that position
    pub fn copy(lua: *Lua, from_index: i32, to_index: i32) void {
        c.lua_copy(lua.state, from_index, to_index);
    }

    /// Creates a new empty table and pushes onto the stack
    /// `num_arr` is a hint for how many elements the table will have as a sequence
    /// `num_rec` is a hint for how many other elements the table will have
    /// Lua may preallocate memory for the table based on the hints
    pub fn createTable(lua: *Lua, num_arr: i32, num_rec: i32) void {
        c.lua_createtable(lua.state, num_arr, num_rec);
    }

    /// Dumps a function as a binary chunk
    pub fn dump(lua: *Lua, writer: CWriterFn, data: *anyopaque, strip: bool) i32 {
        return c.lua_dump(lua.state, writer, data, @boolToInt(strip));
    }

    /// Raises a Lua error using the value at the top of the stack as the error object
    /// Does a longjump and therefore never returns
    pub fn raiseError(lua: *Lua) noreturn {
        _ = c.lua_error(lua.state);
        unreachable;
    }

    /// Controls the garbage collector
    /// The purpose of the return value is dependent on the given action
    /// TODO: perhaps `action` could be comptime known to enforce specific return types
    pub fn gc(lua: *Lua, action: GCAction, args: anytype) i32 {
        return @call(.{}, c.lua_gc, .{ lua.state, @enumToInt(action) } ++ args);
    }

    /// Returns the memory allocation function of a given state
    /// If `data` is not null, it is set to the opaque pointer given when the allocator function was set
    pub fn getAllocF(lua: *Lua, data: ?**anyopaque) AllocFn {
        // Assert cannot be null because it is impossible (and not useful) to pass null
        // to the functions that set the allocator (setallocf and newstate)
        return c.lua_getallocf(lua.state, @ptrCast([*c]?*anyopaque, data)).?;
    }

    /// Returns a pointer to a raw memory area associated with the given Lua state
    /// The application may use this area for any purpose; Lua does not use it for anything
    pub fn getExtraSpace(lua: *Lua) *anyopaque {
        return c.lua_getextraspace(lua.state).?;
    }

    /// Pushes onto the stack the value t[key] where t is the value at the given `index`
    pub fn getField(lua: *Lua, index: i32, key: [:0]const u8) LuaType {
        return @intToEnum(LuaType, c.lua_getfield(lua.state, index, key));
    }

    /// Pushes onto the stack the value of the global `name`. Returns the type of that value
    pub fn getGlobal(lua: *Lua, name: [:0]const u8) LuaType {
        return @intToEnum(LuaType, c.lua_getglobal(lua.state, name));
    }

    /// Pushes onto the stack the value t[`i`] where t is the value at the given `index`
    /// Returns the type of the pushed value
    /// TODO: rename getIndex
    pub fn getI(lua: *Lua, index: i32, i: Integer) LuaType {
        return @intToEnum(LuaType, c.lua_geti(lua.state, index, i));
    }

    /// Pushes onto the stack the `n`th user value associated with the full userdata at the given `index`
    /// Returns the type of the pushed value
    pub fn getIUserValue(lua: *Lua, index: i32, n: i32) LuaType {
        return @intToEnum(LuaType, c.lua_getiuservalue(lua.state, index, n));
    }

    /// If the value at the given `index` has a metatable, the function pushes that metatable onto the stack and returns true
    /// Otherwise false is returned
    pub fn getMetatable(lua: *Lua, index: i32) bool {
        return c.lua_getmetatable(lua.state, index) != 0;
    }

    /// Pushes onto the stack the value t[k] where t is the value at the given `index` and k is the value on the top of the stack
    /// Returns the type of the pushed value
    pub fn getTable(lua: *Lua, index: i32) LuaType {
        return @intToEnum(LuaType, c.lua_gettable(lua.state, index));
    }

    /// Returns the index of the top element in the stack
    /// Because indices start at 1, the result is also equal to the number of elements in the stack
    pub fn getTop(lua: *Lua) i32 {
        return c.lua_gettop(lua.state);
    }

    /// Moves the top element into the given valid `index` shifting up any elements to make room
    pub fn insert(lua: *Lua, index: i32) void {
        // translate-c cannot translate this macro correctly
        // c.lua_insert(lua.state, index);
        lua.rotate(index, 1);
    }

    /// Returns true if the value at the given `index` is a boolean
    pub fn isBoolean(lua: *Lua, index: i32) bool {
        return c.lua_isboolean(lua.state, index);
    }

    /// Returns true if the value at the given `index` is a CFn
    pub fn isCFunction(lua: *Lua, index: i32) bool {
        return c.lua_iscfunction(lua.state, index) != 0;
    }

    /// Returns true if the value at the given `index` is a function (C or Lua)
    pub fn isFunction(lua: *Lua, index: i32) bool {
        return c.lua_isfunction(lua.state, index);
    }

    /// Returns true if the value at the given `index` is an integer
    pub fn isInteger(lua: *Lua, index: i32) bool {
        return c.lua_isinteger(lua.state, index) != 0;
    }

    /// Returns true if the value at the given `index` is a light userdata
    pub fn isLightUserdata(lua: *Lua, index: i32) bool {
        return c.lua_islightuserdata(lua.state, index);
    }

    /// Returns true if the value at the given `index` is nil
    pub fn isNil(lua: *Lua, index: i32) bool {
        return c.lua_isnil(lua.state, index);
    }

    /// Returns true if the given `index` is not valid
    pub fn isNone(lua: *Lua, index: i32) bool {
        return c.lua_isnone(lua.state, index);
    }

    /// Returns true if the given `index` is not valid or if the value at the `index` is nil
    pub fn isNoneOrNil(lua: *Lua, index: i32) bool {
        return c.lua_isnoneornil(lua.state, index);
    }

    /// Returns true if the value at the given `index` is a number
    pub fn isNumber(lua: *Lua, index: i32) bool {
        return c.lua_isnumber(lua.state, index) != 0;
    }

    /// Returns true if the value at the given `index` is a string
    pub fn isString(lua: *Lua, index: i32) bool {
        return c.lua_isstring(lua.state, index) != 0;
    }

    /// Returns true if the value at the given `index` is a table
    pub fn isTable(lua: *Lua, index: i32) bool {
        return c.lua_istable(lua.state, index);
    }

    /// Returns true if the value at the given `index` is a thread
    pub fn isThread(lua: *Lua, index: i32) bool {
        return c.lua_isthread(lua.state, index);
    }

    /// Returns true if the value at the given `index` is a userdata (full or light)
    pub fn isUserdata(lua: *Lua, index: i32) bool {
        return c.lua_isuserdata(lua.state, index) != 0;
    }

    /// Returns true if the given coroutine can yield
    pub fn isYieldable(lua: *Lua) bool {
        return c.lua_isyieldable(lua.state) != 0;
    }

    /// Pushes the length of the value at the given `index` onto the stack
    /// Equivalent to the `#` operator in Lua
    pub fn len(lua: *Lua, index: i32) void {
        c.lua_len(lua.state, index);
    }

    /// Loads a Lua chunk without running it
    pub fn load(lua: *Lua, reader: CReaderFn, data: *anyopaque, chunk_name: [:0]const u8, mode: ?Mode) !void {
        const mode_str = blk: {
            if (mode == null) break :blk "bt";

            break :blk switch (mode.?) {
                .binary => "b",
                .text => "t",
                .binary_text => "bt",
            };
        };
        const ret = c.lua_load(lua.state, reader, data, chunk_name, mode_str);
        switch (ret) {
            Status.ok => return,
            Status.err_syntax => return Error.Syntax,
            Status.err_memory => return Error.Memory,
            // NOTE: the docs mention possible other return types, but I couldn't figure them out
            else => panic("load returned an unexpected status: `{d}`", .{ret}),
        }
    }

    /// Creates a new independent state and returns its main thread
    pub fn newState(alloc_fn: AllocFn, data: ?*anyopaque) !Lua {
        const state = c.lua_newstate(alloc_fn, data) orelse return Error.Memory;
        return Lua{ .state = state };
    }

    /// Creates a new empty table and pushes it onto the stack
    /// Equivalent to `Lua.createTable(lua, 0, 0)`
    pub fn newTable(lua: *Lua) void {
        c.lua_newtable(lua.state);
    }

    /// Creates a new thread, pushes it on the stack, and returns a `Lua` state that represents the new thread
    /// The new thread shares the global environment but has a separate execution stack
    pub fn newThread(lua: *Lua) Lua {
        const state = c.lua_newthread(lua.state).?;
        return .{ .state = state };
    }

    /// This function creates and pushes a new full userdata onto the stack
    /// with `num_uvalue` associated Lua values, plus an associated block of raw memory with `size` bytes
    /// Returns the address of the block of memory
    /// TODO: use comptime to return the a pointer to a block of type T for safety?
    /// See how this is used if that would be useful
    pub fn newUserdataUV(lua: *Lua, size: usize, new_uvalue: i32) *anyopaque {
        return c.lua_newuserdatauv(lua.state, size, new_uvalue).?;
    }

    /// Pops a key from the stack, and pushes a key-value pair from the table at the given `index`
    pub fn next(lua: *Lua, index: i32) bool {
        return c.lua_next(lua.state, index) != 0;
    }

    /// Tries to convert a Lua float into a Lua integer
    /// Returns an error if the conversion was unsuccessful
    pub fn numberToInteger(n: Number, i: *Integer) !void {
        // translate-c failure
        // return c.lua_numbertointeger(n, i) != 0;
        if (n >= @intToFloat(Number, min_integer) and n < -@intToFloat(Number, min_integer)) {
            i.* = @floatToInt(Integer, n);
        } else return Error.Fail;
    }

    /// Calls a function (or callable object) in protected mode
    pub fn protectedCall(lua: *Lua, num_args: i32, num_results: i32, msg_handler: i32) !void {
        // The translate-c version of lua_pcall does not type-check so we must use this one
        // (macros don't always translate well with translate-c)
        try lua.protectedCallCont(num_args, num_results, msg_handler, 0, null);
    }

    /// Behaves exactly like `Lua.protectedCall()` except that it allows the called function to yield
    pub fn protectedCallCont(lua: *Lua, num_args: i32, num_results: i32, msg_handler: i32, ctx: KContext, k: ?CContFn) !void {
        const ret = c.lua_pcallk(lua.state, num_args, num_results, msg_handler, ctx, k);
        switch (ret) {
            Status.ok => return,
            Status.err_runtime => return Error.Runtime,
            Status.err_memory => return Error.Memory,
            Status.err_error => return Error.MsgHandler,
            else => unreachable,
        }
    }

    /// Pops `n` elements from the top of the stack
    pub fn pop(lua: *Lua, n: i32) void {
        lua.setTop(-n - 1);
    }

    /// Pushes a boolean value with value `b` onto the stack
    pub fn pushBoolean(lua: *Lua, b: bool) void {
        c.lua_pushboolean(lua.state, @boolToInt(b));
    }

    /// Pushes a new C Closure onto the stack
    /// `n` tells how many upvalues this function will have
    /// TODO: add a Zig interface to pass Zig functions wrapped
    pub fn pushCClosure(lua: *Lua, c_fn: CFn, n: i32) void {
        c.lua_pushcclosure(lua.state, c_fn, n);
    }

    /// Pushes a C function onto the stack.
    /// Equivalent to pushCClosure with no upvalues
    pub fn pushCFunction(lua: *Lua, c_fn: CFn) void {
        lua.pushCClosure(c_fn, 0);
    }

    /// Push a formatted string onto the stack and return a pointer to the string
    pub fn pushFString(lua: *Lua, fmt: [:0]const u8, args: anytype) [*]const u8 {
        const ptr = @call(.{}, c.lua_pushfstring, .{ lua.state, fmt } ++ args);
        return @ptrCast([*]const u8, ptr);
    }

    /// Pushes the global environment onto the stack
    pub fn pushGlobalTable(lua: *Lua) void {
        // lua_pushglobaltable is a macro and c-translate assumes it returns opaque
        // so just reimplement the macro here
        // c.lua_pushglobaltable(lua.state);
        _ = lua.rawGetI(registry_index, ridx_globals);
    }

    /// Pushes an integer with value `n` onto the stack
    pub fn pushInteger(lua: *Lua, n: Integer) void {
        c.lua_pushinteger(lua.state, n);
    }

    /// Pushes a light userdata onto the stack
    pub fn pushLightUserdata(lua: *Lua, ptr: *anyopaque) void {
        c.lua_pushlightuserdata(lua.state, ptr);
    }

    /// There is no reason to have a pushLiteral function...
    // pub fn pushLiteral(lua: *Lua, str: []const u8) []const u8 {
    //     c.lua_pushliteral(lua.state, str); // TODO
    // }

    /// Pushes the bytes onto the stack. Returns a slice pointing to Lua's internal copy of the string
    pub fn pushLString(lua: *Lua, str: []const u8) []const u8 {
        return c.lua_pushlstring(lua.state, str.ptr, str.len)[0..str.len];
    }

    /// Pushes a nil value onto the stack
    pub fn pushNil(lua: *Lua) void {
        c.lua_pushnil(lua.state);
    }

    /// Pushes a float with value `n` onto the stack
    pub fn pushNumber(lua: *Lua, n: Number) void {
        c.lua_pushnumber(lua.state, n);
    }

    /// Pushes a zero-terminated string onto the stack
    /// Lua makes a copy of the string so `str` may be freed immediately after return
    /// Returns a pointer to the internal Lua string
    /// If `str` is null pushes nil and returns null
    pub fn pushString(lua: *Lua, str: ?[*:0]const u8) ?[*]const u8 {
        const ptr = c.lua_pushstring(lua.state, str);
        return @ptrCast(?[*]const u8, ptr);
    }

    /// Pushes this thread onto the stack
    /// Returns true if this thread is the main thread of its state
    pub fn pushThread(lua: *Lua) bool {
        return c.lua_pushthread(lua.state) != 0;
    }

    /// Pushes a copy of the element at the given index onto the stack
    pub fn pushValue(lua: *Lua, index: i32) void {
        c.lua_pushvalue(lua.state, index);
    }

    // TODO: pub fn pushVFString is that even worth?

    /// Returns true if the two values in indices `index1` and `index2` are primitively equal
    /// Bypasses __eq metamethods
    /// Returns false if not equal, or if any index is invalid
    pub fn rawEqual(lua: *Lua, index1: i32, index2: i32) bool {
        return c.lua_rawequal(lua.state, index1, index2) != 0;
    }

    /// Similar to `Lua.getTable()` but does a raw access (without metamethods)
    pub fn rawGet(lua: *Lua, index: i32) LuaType {
        return @intToEnum(LuaType, c.lua_rawget(lua.state, index));
    }

    /// Pushes onto the stack the value t[n], where `t` is the table at the given `index`
    /// Returns the `LuaType` of the pushed value
    pub fn rawGetI(lua: *Lua, index: i32, n: Integer) LuaType {
        return @intToEnum(LuaType, c.lua_rawgeti(lua.state, index, n));
    }

    /// Pushes onto the stack the value t[k] where t is the table at the given `index` and
    /// k is the pointer `p` represented as a light userdata
    pub fn rawGetP(lua: *Lua, index: i32, p: *anyopaque) LuaType {
        return @intToEnum(LuaType, c.lua_rawgetp(lua.state, index, p));
    }

    /// Returns the raw length of the value at the given index
    /// For strings it is the length; for tables it is the result of the `#` operator
    /// For userdata it is the size of the block of memory
    /// For other values the call returns 0
    pub fn rawLen(lua: *Lua, index: i32) Unsigned {
        return c.lua_rawlen(lua.state, index);
    }

    /// Similar to `Lua.setTable()` but does a raw assignment (without metamethods)
    pub fn rawSet(lua: *Lua, index: i32) void {
        c.lua_rawset(lua.state, index);
    }

    /// Does the equivalent of t[`i`] = v where t is the table at the given `index`
    /// and v is the value at the top of the stack
    /// Pops the value from the stack. Does not use __newindex metavalue
    pub fn rawSetI(lua: *Lua, index: i32, i: Integer) void {
        c.lua_rawseti(lua.state, index, i);
    }

    /// Does the equivalent of t[p] = v where t is the table at the given `index`
    /// `p` is encoded as a light user data, and v is the value at the top of the stack
    /// Pops the value from the stack. Does not use __newindex metavalue
    pub fn rawSetP(lua: *Lua, index: i32, p: *anyopaque) void {
        c.lua_rawsetp(lua.state, index, p);
    }

    /// Sets the C function f as the new value of global name
    pub fn register(lua: *Lua, name: [:0]const u8, c_fn: CFn) void {
        c.lua_register(lua.state, name, c_fn);
    }

    /// Removes the element at the given valid `index` shifting down elements to fill the gap
    pub fn remove(lua: *Lua, index: i32) void {
        // translate-c cannot translate this macro correctly
        // c.lua_remove(lua.state, index);
        lua.rotate(index, -1);
        lua.pop(1);
    }

    /// Moves the top element into the given valid `index` without shifting any elements,
    /// then pops the top element
    pub fn replace(lua: *Lua, index: i32) void {
        // translate-c cannot translate this macro correctly
        // c.lua_replace(lua.state, index);
        lua.copy(-1, index);
        lua.pop(1);
    }

    /// Resets a thread, cleaning its call stack and closing all pending to-be-closed variables
    /// TODO: look into possible errors
    pub fn resetThread(lua: *Lua) i32 {
        return c.lua_resetthread(lua.state);
    }

    /// Starts and resumes a coroutine in the given thread
    /// TODO: look into possible errors returned
    pub fn resumeThread(lua: *Lua, from: ?Lua, num_args: i32, num_results: *i32) i32 {
        const from_state = if (from) |from_val| from_val.state else null;
        return c.lua_resume(lua.state, from_state, num_args, num_results);
    }

    /// Rotates the stack elements between the valid `index` and the top of the stack
    /// The elements are rotated `n` positions in the direction of the top for positive `n`,
    /// and `n` positions in the direction of the bottom for negative `n`
    pub fn rotate(lua: *Lua, index: i32, n: i32) void {
        c.lua_rotate(lua.state, index, n);
    }

    /// Changes the allocator function of a given state to `alloc_fn` with userdata `data`
    pub fn setAllocF(lua: *Lua, alloc_fn: AllocFn, data: ?*anyopaque) void {
        c.lua_setallocf(lua.state, alloc_fn, data);
    }

    /// Does the equivalent to t[`k`] = v where t is the value at the given `index`
    /// and v is the value on the top of the stack
    pub fn setField(lua: *Lua, index: i32, k: [:0]const u8) void {
        c.lua_setfield(lua.state, index, k);
    }

    /// Pops a value from the stack and sets it as the new value of global `name`
    pub fn setGlobal(lua: *Lua, name: [:0]const u8) void {
        c.lua_setglobal(lua.state, name);
    }

    /// Does the equivalent to t[`n`] = v where t is the value at the given `index`
    /// and v is the value on the top of the stack. Pops the value from the stack
    pub fn setI(lua: *Lua, index: i32, n: Integer) void {
        c.lua_seti(lua.state, index, n);
    }

    /// Pops a value from the stack and sets it as the new `n`th user value associated to
    /// the full userdata at the given index
    /// Returns an error if the userdata does not have that value
    pub fn setIUserValue(lua: *Lua, index: i32, n: i32) !void {
        if (c.lua_setiuservalue(lua.state, index, n) == 0) return Error.Fail;
    }

    /// Pops a table or nil from the stack and sets that value as the new metatable for the
    /// value at the given `index`
    pub fn setMetatable(lua: *Lua, index: i32) void {
        // lua_setmetatable always returns 1 so is safe to ignore
        _ = c.lua_setmetatable(lua.state, index);
    }

    /// Does the equivalent to t[k] = v, where t is the value at the given `index`
    /// v is the value on the top of the stack, and k is the value just below the top
    pub fn setTable(lua: *Lua, index: i32) void {
        c.lua_settable(lua.state, index);
    }

    /// Sets the top of the stack to `index`
    /// If the new top is greater than the old, new elements are filled with nil
    /// If `index` is 0 all stack elements are removed
    pub fn setTop(lua: *Lua, index: i32) void {
        c.lua_settop(lua.state, index);
    }

    /// Sets the warning function to be used by Lua to emit warnings
    /// The `data` parameter sets the value `data` passed to the warning function
    pub fn setWarnF(lua: *Lua, warn_fn: CWarnFn, data: ?*anyopaque) void {
        c.lua_setwarnf(lua.state, warn_fn, data);
    }

    pub const StatusType = enum(u3) {
        ok = Status.ok,
        yield = Status.yield,
        err_runtime = Status.err_runtime,
        err_syntax = Status.err_syntax,
        err_memory = Status.err_memory,
        err_error = Status.err_error,
    };

    /// Returns the status of this thread
    pub fn status(lua: *Lua) StatusType {
        return @intToEnum(StatusType, c.lua_status(lua.state));
    }

    /// Converts the zero-terminated string `str` to a number, pushes that number onto the stack,
    /// and returns the total size of the string (length + 1)
    pub fn stringToNumber(lua: *Lua, str: [:0]const u8) !usize {
        const size = c.lua_stringtonumber(lua.state, str);
        if (size == 0) return Error.Fail;
        return size;
    }

    /// Converts the Lua value at the given `index` into a boolean
    /// The Lua value at the index will be considered true unless it is false or nil
    pub fn toBoolean(lua: *Lua, index: i32) bool {
        return c.lua_toboolean(lua.state, index) != 0;
    }

    /// Converts a value at the given `index` into a CFn
    /// Returns null if the value is not a CFn
    pub fn toCFunction(lua: *Lua, index: i32) ?CFn {
        return c.lua_tocfunction(lua.state, index);
    }

    /// Marks the given index in the stack as a to-be-closed slot
    pub fn toClose(lua: *Lua, index: i32) void {
        c.lua_toclose(lua.state, index);
    }

    /// Equivalent to toIntegerX but does not return errors
    /// TODO: there really isn't a reason to use this...
    /// perhaps combine with toIntegerX and always enforce errors
    /// The caller can always choose to ignore (same for toNumber)
    pub fn toInteger(lua: *Lua, index: i32) Integer {
        return lua.toIntegerX(index) catch return 0;
    }

    /// Converts the Lua value at the given `index` to a signed integer
    /// The Lua value must be an integer, or a number, or a string convertible to an integer otherwise toIntegerX returns 0
    /// Returns an error if the conversion failed
    pub fn toIntegerX(lua: *Lua, index: i32) !Integer {
        var success: c_int = undefined;
        const result = c.lua_tointegerx(lua.state, index, &success);
        if (success == 0) return Error.Fail;
        return result;
    }

    // NOTE: No need to have both toLString and toString for a Zig API
    // pub fn toLString(lua: *Lua, index: i32) []const u8 { ... }

    /// Equivalent to toNumberX but does not return errors
    pub fn toNumber(lua: *Lua, index: i32) Number {
        return lua.toNumberX(index) catch return 0;
    }

    /// Converts the Lua value at the given `index` to a float
    /// The Lua value must be a number or a string convertible to a number otherwise toNumberX returns 0
    /// Returns an error if the conversion failed
    pub fn toNumberX(lua: *Lua, index: i32) !Number {
        var success: c_int = undefined;
        const result = c.lua_tonumberx(lua.state, index, &success);
        if (success == 0) return Error.Fail;
        return result;
    }

    /// Converts the value at the given `index` to an opaque pointer
    pub fn toPointer(lua: *Lua, index: i32) ?*const anyopaque {
        return c.lua_topointer(lua.state, index);
    }

    /// Converts the Lua value at the given `index` to a zero-terminated slice (string)
    /// Returns null if the value was not a string or number
    /// If the value was a number the actual value in the stack will be changed to a string
    pub fn toString(lua: *Lua, index: i32) ?[:0]const u8 {
        var length: usize = undefined;
        if (c.lua_tolstring(lua.state, index, &length)) |str| {
            return str[0..length :0];
        } else return null;
    }

    /// Converts the value at the given `index` to a Lua thread (wrapped with a `Lua` struct)
    /// The thread does _not_ contain an allocator because it is not the main thread and should therefore not be used with `deinit()`
    pub fn toThread(lua: *Lua, index: i32) ?Lua {
        const thread = c.lua_tothread(lua.state, index);
        if (thread) |thread_ptr| return Lua{ .state = thread_ptr };
        return null;
    }

    /// If the value at the given `index` is a full userdata, returns its memory-block address
    /// If the value is a light userdata, returns its value (a pointer)
    /// Otherwise returns null
    pub fn toUserdata(lua: *Lua, index: i32) ?*anyopaque {
        return c.lua_touserdata(lua.state, index);
    }

    /// Returns the `LuaType` of the value at the given index
    /// Note that this is equivalent to lua_type but because type is a Zig primitive it is renamed to `typeOf`
    pub fn typeOf(lua: *Lua, index: i32) LuaType {
        return @intToEnum(LuaType, c.lua_type(lua.state, index));
    }

    /// Returns the name of the given `LuaType` as a null-terminated slice
    pub fn typeName(lua: *Lua, t: LuaType) [:0]const u8 {
        return std.mem.span(c.lua_typename(lua.state, @enumToInt(t)));
    }

    /// Returns the pseudo-index that represents the `i`th upvalue of the running function
    pub fn upvalueIndex(i: i32) i32 {
        return c.lua_upvalueindex(i);
    }

    /// Returns the version number of this core
    pub fn version(lua: *Lua) Number {
        return c.lua_version(lua.state);
    }

    /// Emits a warning with the given `msg`
    /// A message with `to_cont` as true should be continued in a subsequent call to the function
    pub fn warning(lua: *Lua, msg: [:0]const u8, to_cont: bool) void {
        c.lua_warning(lua.state, msg, @boolToInt(to_cont));
    }

    /// Pops `num` values from the current stack and pushes onto the stack of `to`
    pub fn xMove(lua: *Lua, to: Lua, num: i32) void {
        c.lua_xmove(lua.state, to.state, num);
    }

    /// This function is equivalent to `Lua.yieldK()` but has no continuation
    /// TODO: return values?
    pub fn yield(lua: *Lua, num_results: i32) i32 {
        // translate-c failed to pass NULL correctly
        return c.lua_yieldk(lua.state, num_results, 0, null);
    }

    /// Yields this coroutine (thread)
    pub fn yieldCont(lua: *Lua, num_results: i32, ctx: KContext, k: CContFn) i32 {
        return c.lua_yieldk(lua.state, num_results, ctx, k);
    }

    // Debug library functions
    //
    // The debug interface functions are included in alphabetical order
    // Each is kept similar to the original C API function while also making it easy to use from Zig

    /// Returns the current hook function
    pub fn getHook(lua: *Lua) ?CHookFn {
        return c.lua_gethook(lua.state);
    }

    /// Returns the current hook count
    pub fn getHookCount(lua: *Lua) i32 {
        return c.lua_gethookcount(lua.state);
    }

    /// Returns the current hook mask
    pub fn getHookMask(lua: *Lua) HookMask {
        return HookMask.fromInt(c.lua_gethookmask(lua.state));
    }

    /// Gets information about a specific function or function invocation
    /// TODO: look at possible types for what
    pub fn getInfo(lua: *Lua, what: [:0]const u8, ar: *DebugInfo) bool {
        return c.lua_getinfo(lua.state, what, ar) != 0;
    }

    /// Gets information about a local variable
    pub fn getLocal(lua: *Lua, ar: *DebugInfo, n: i32) ![:0]const u8 {
        if (c.lua_getlocal(lua.state, ar, n)) |name| {
            return std.mem.span(name);
        }
        return Error.Fail;
    }

    /// Gets information about the interpreter runtime stack
    pub fn getStack(lua: *Lua, level: i32, ar: *DebugInfo) bool {
        return c.lua_getstack(lua.state, level, ar) != 0;
    }

    /// Gets information about the `n`th upvalue of the closure at index `func_index`
    pub fn getUpvalue(lua: *Lua, func_index: i32, n: i32) ![:0]const u8 {
        if (c.lua_getupvalue(lua.state, func_index, n)) |name| {
            return std.mem.span(name);
        }
        return Error.Fail;
    }

    /// Sets the debugging hook function
    pub fn setHook(lua: *Lua, hook_fn: CHookFn, mask: HookMask, count: i32) void {
        const hook_mask = HookMask.toInt(mask);
        c.lua_sethook(lua.state, hook_fn, hook_mask, count);
    }

    /// Sets the value of a local variable
    /// Returns an error when the index is greater than the number of active locals
    pub fn setLocal(lua: *Lua, ar: *DebugInfo, n: i32) ![:0]const u8 {
        if (c.lua_setlocal(lua.state, ar, n)) |name| {
            return std.mem.span(name);
        }
        return Error.Fail;
    }

    /// Sets the value of a closure's upvalue
    pub fn setUpvalue(lua: *Lua, func_index: i32, n: i32) ![:0]const u8 {
        if (c.lua_setupvalue(lua.state, func_index, n)) |name| {
            return std.mem.span(name);
        }
        return Error.Fail;
    }

    /// Returns a unique identifier for the upvalue numbered `n` from the closure index `func_index`
    pub fn upvalueId(lua: *Lua, func_index: i32, n: i32) ?*anyopaque {
        return c.lua_upvalueid(lua.state, func_index, n);
    }

    /// Make the `n1`th upvalue of the Lua closure at index `func_index1` refer to the `n2`th upvalue
    /// of the Lua closure at index `func_index2`
    pub fn upvalueJoin(lua: *Lua, func_index1: i32, n1: i32, func_index2: i32, n2: i32) void {
        c.lua_upvaluejoin(lua.state, func_index1, n1, func_index2, n2);
    }

    // Auxiliary library functions
    //
    // Auxiliary library functions are included in alphabetical order.
    // Each is kept similar to the original C API function while also making it easy to use from Zig

    /// Checks whether `cond` is true. Raises an error using `Lua.argError()` if not
    /// Possibly never returns
    pub fn argCheck(lua: *Lua, cond: bool, arg: i32, extra_msg: [:0]const u8) void {
        // translate-c failed
        if (cond) lua.typeError(arg, extra_msg);
    }

    /// Raises an error reporting a problem with argument `arg` of the C function that called it
    pub fn argError(lua: *Lua, arg: i32, extra_msg: [:0]const u8) noreturn {
        _ = c.luaL_argerror(lua.state, arg, extra_msg);
        unreachable;
    }

    /// Checks whether `cond` is true. Raises an error using `Lua.typeError()` if not
    /// Possibly never returns
    pub fn argExpected(lua: *Lua, cond: bool, arg: i32, type_name: [:0]const u8) void {
        // translate-c failed
        if (cond) lua.typeError(arg, type_name);
    }

    /// Calls a metamethod
    pub fn callMeta(lua: *Lua, obj: i32, field: [:0]const u8) bool {
        return c.luaL_callmeta(lua.state, obj, field) != 0;
    }

    /// Checks whether the function has an argument of any type at position `arg`
    pub fn checkAny(lua: *Lua, arg: i32) void {
        c.luaL_checkany(lua.state, arg);
    }

    /// Checks whether the function argument `arg` is an integer (or can be converted to an integer) and returns the integer
    pub fn checkInteger(lua: *Lua, arg: i32) Integer {
        return c.luaL_checkinteger(lua.state, arg);
    }

    /// Checks whether the function argument `arg` is a string and returns the string
    pub fn checkLString(lua: *Lua, arg: i32) ?[]const u8 {
        var length: usize = 0;
        if (c.luaL_checklstring(lua.state, arg, @ptrCast([*c]usize, &length))) |str| {
            return str[0..length];
        } else return null;
    }

    /// Checks whether the function argument `arg` is a number and returns the number
    pub fn checkNumber(lua: *Lua, arg: i32) Number {
        return c.luaL_checknumber(lua.state, arg);
    }

    /// Checks whether the function argument `arg` is a string and searches for the string in the null-terminated array `list`
    /// `default` is used as a default value when not null
    /// Returns the index in the array where the string was found
    pub fn checkOption(lua: *Lua, arg: i32, default: ?[:0]const u8, list: [:null]?[:0]const u8) i32 {
        return c.luaL_checkoption(
            lua.state,
            arg,
            if (default != null) default.?.ptr else null,
            // TODO: check this cast
            @ptrCast([*c]const [*c]const u8, list.ptr),
        );
    }

    /// Grows the stack size to top + `size` elements, raising an error if the stack cannot grow to that size
    /// `msg` is an additional text to go into the error message
    pub fn checkStackAux(lua: *Lua, size: i32, msg: ?[*:0]const u8) void {
        c.luaL_checkstack(lua.state, size, msg);
    }

    /// Checks whether the function argument `arg` is a string and returns the string
    /// TODO: check about lua_tolstring for returning the size
    pub fn checkString(lua: *Lua, arg: i32) [*:0]const u8 {
        return c.luaL_checklstring(lua.state, arg, null);
    }

    /// Checks whether the function argument `arg` has type `t`
    pub fn checkType(lua: *Lua, arg: i32, t: LuaType) void {
        c.luaL_checktype(lua.state, arg, @enumToInt(t));
    }

    /// Checks whether the function argument `arg` is a userdata of the type `type_name`
    /// Returns the userdata's memory-block address
    pub fn checkUserdata(lua: *Lua, arg: i32, type_name: [:0]const u8) *anyopaque {
        return c.luaL_checkudata(lua.state, arg, type_name).?;
    }

    /// Checks whether the code making the call and the Lua library being called are using
    /// the same version of Lua and the same numeric types.
    pub fn checkVersion(lua: *Lua) void {
        return c.luaL_checkversion(lua.state);
    }

    /// Loads and runs the given file
    pub fn doFile(lua: *Lua, file_name: [:0]const u8) !void {
        // translate-c failure
        try lua.loadFile(file_name);
        try lua.protectedCall(0, mult_return, 0);
    }

    /// Loads and runs the given string
    pub fn doString(lua: *Lua, str: [:0]const u8) !void {
        // trnaslate-c failure
        try lua.loadString(str);
        try lua.protectedCall(0, mult_return, 0);
    }

    /// Raises an error
    pub fn raiseErrorAux(lua: *Lua, fmt: [:0]const u8, args: anytype) noreturn {
        @call(.{}, c.luaL_error, .{ lua.state, fmt } ++ args);
    }

    /// This function produces the return values for process-related functions in the standard library
    pub fn exeResult(lua: *Lua, stat: i32) i32 {
        return c.luaL_execresult(lua.state, stat);
    }

    /// This function produces the return values for file-related functions in the standard library
    pub fn fileResult(lua: *Lua, stat: i32, file_name: [:0]const u8) i32 {
        return c.luaL_fileresult(lua.state, stat, file_name);
    }

    /// Pushes onto the stack the field `e` from the metatable of the object at index `obj`
    /// and returns the type of the pushed value
    /// TODO: possibly return an error if nil
    pub fn getMetaField(lua: *Lua, obj: i32, field: [:0]const u8) LuaType {
        return @intToEnum(LuaType, c.luaL_getmetafield(lua.state, obj, field));
    }

    /// Pushes onto the stack the metatable associated with the name `type_name` in the registry
    /// or nil if there is no metatable associated with that name. Returns the type of the pushed value
    pub fn getMetatableAux(lua: *Lua, type_name: [:0]const u8) LuaType {
        return @intToEnum(LuaType, c.luaL_getmetatable(lua.state, type_name));
    }

    /// Ensures that the value t[`field`], where t is the value at `index`, is a table, and pushes that table onto the stack.
    pub fn getSubtable(lua: *Lua, index: i32, field: [:0]const u8) bool {
        return c.luaL_getsubtable(lua.state, index, field) != 0;
    }

    /// Creates a copy of string `str`, replacing any occurrence of the string `pat` with the string `rep`
    /// Pushes the resulting string on the stack and returns it.
    pub fn gSub(lua: *Lua, str: [:0]const u8, pat: [:0]const u8, rep: [:0]const u8) [:0]const u8 {
        return std.mem.span(c.luaL_gsub(lua.state, str, pat, rep));
    }

    /// Returns the "length" of the value at the given index as a number
    /// it is equivalent to the '#' operator in Lua
    pub fn lenAux(lua: *Lua, index: i32) i64 {
        return c.luaL_len(lua.state, index);
    }

    /// The same as `Lua.loadBufferX` with `mode` set to null
    pub fn loadBuffer(lua: *Lua, buf: [:0]const u8, size: usize, name: [:0]const u8) i32 {
        // translate-c failure
        return c.luaL_loadbufferx(lua.state, buf, size, name, null);
    }

    /// Loads a buffer as a Lua chunk
    /// TODO: There isn't a real reason to allow null mofe with loadBuffer
    pub fn loadBufferX(lua: *Lua, buf: [:0]const u8, size: usize, name: [:0]const u8, mode: ?Mode) i32 {
        const mode_str = blk: {
            if (mode == null) break :blk "bt";

            break :blk switch (mode.?) {
                .binary => "b",
                .text => "t",
                .binary_text => "bt",
            };
        };
        return c.luaL_loadbufferx(lua.state, buf, size, name, mode_str);
    }

    /// Equivalent to `Lua.loadFileX()` with mode equal to null
    pub fn loadFile(lua: *Lua, file_name: [:0]const u8) !void {
        return loadFileX(lua, file_name, null);
    }

    /// Loads a file as a Lua chunk
    pub fn loadFileX(lua: *Lua, file_name: [:0]const u8, mode: ?Mode) !void {
        const mode_str = blk: {
            if (mode == null) break :blk "bt";

            break :blk switch (mode.?) {
                .binary => "b",
                .text => "t",
                .binary_text => "bt",
            };
        };
        const ret = c.luaL_loadfilex(lua.state, file_name, mode_str);
        switch (ret) {
            Status.ok => return,
            Status.err_syntax => return Error.Syntax,
            Status.err_memory => return Error.Memory,
            Status.err_file => return Error.File,
            // NOTE: the docs mention possible other return types, but I couldn't figure them out
            else => panic("load returned an unexpected status: `{d}`", .{ret}),
        }
    }

    /// Loads a string as a Lua chunk
    /// TODO: investigate what kind of return codes this really can return
    pub fn loadString(lua: *Lua, str: [:0]const u8) !void {
        const ret = c.luaL_loadstring(lua.state, str);
        switch (ret) {
            Status.ok => return,
            Status.err_syntax => return Error.Syntax,
            Status.err_memory => return Error.Memory,
            // NOTE: loadstring calls lua_load which can return more status codes than this?
            else => panic("loadString returned an unexpected status: `{d}`", .{ret}),
        }
    }

    /// Creates a new table and registers there the functions in `list`
    pub fn newLib(lua: *Lua, list: []const FnReg) void {
        // translate-c failure
        lua.checkVersion();
        lua.newLibTable(list);
        lua.setFuncs(list, 0);
    }

    /// Creates a new table with a size optimized to store all entries in the array `list`
    pub fn newLibTable(lua: *Lua, list: []const FnReg) void {
        // translate-c failure
        lua.createTable(0, @intCast(i32, list.len));
    }

    /// If the registry already has the key `key`, returns 0
    /// Otherwise, creates a new table to be used as a metatable for userdata
    pub fn newMetatable(lua: *Lua, key: [:0]const u8) !void {
        if (c.luaL_newmetatable(lua.state, key) == 0) return Error.Fail;
    }

    /// Creates a new Lua state with an allocator using the default libc allocator
    pub fn newStateAux() !Lua {
        const state = c.luaL_newstate() orelse return Error.Memory;
        return Lua{ .state = state };
    }

    // luaL_opt (a macro) really isn't that useful, so not going to implement for now

    /// If the function argument `arg` is an integer, returns the integer
    /// If the argument is absent or nil returns `default`
    pub fn optInteger(lua: *Lua, arg: i32, default: Integer) Integer {
        return c.luaL_optinteger(lua.state, arg, default);
    }

    /// If the function argument `arg` is a string, returns the string
    /// If the argument is absent or nil returns `default`
    pub fn optLString(lua: *Lua, arg: i32, default: [:0]const u8) []const u8 {
        var length: usize = 0;
        // will never return null because default cannot be null
        const ret: [*]const u8 = c.luaL_optlstring(lua.state, arg, default, &length);
        if (ret == default.ptr) return default;
        return ret[0..length];
    }

    /// If the function argument `arg` is a number, returns the number
    /// If the argument is absent or nil returns `default`
    pub fn optNumber(lua: *Lua, arg: i32, default: Number) Number {
        return c.luaL_optnumber(lua.state, arg, default);
    }

    /// If the function argument `arg` is a string, returns the string
    /// If the argment is absent or nil returns `default`
    pub fn optString(lua: *Lua, arg: i32, default: [:0]const u8) [*:0]const u8 {
        // translate-c error
        return c.luaL_optlstring(lua.state, arg, default, null);
    }

    /// Pushes the fail value onto the stack
    pub fn pushFail(lua: *Lua) void {
        c.luaL_pushfail(lua.state);
    }

    /// Creates and returns a reference in the table at index `index` for the object on the top of the stack
    /// Pops the object
    pub fn ref(lua: *Lua, index: i32) ?i32 {
        const ret = c.luaL_ref(lua.state, index);
        return if (ret == ref_nil) null else ret;
    }

    /// If package.loaded[`mod_name`] is not true, calls the function `open_fn` with `mod_name`
    /// as an argument and sets the call result to package.loaded[`mod_name`]
    pub fn requireF(lua: *Lua, mod_name: [:0]const u8, open_fn: CFn, global: bool) void {
        c.luaL_requiref(lua.state, mod_name, open_fn, @boolToInt(global));
    }

    /// Registers all functions in the array `fns` into the table on the top of the stack
    /// All functions are created with `num_upvalues` upvalues
    pub fn setFuncs(lua: *Lua, funcs: []const FnReg, num_upvalues: i32) void {
        lua.checkStackAux(num_upvalues, "too many upvalues");
        for (funcs) |f| {
            if (f.func) |func| {
                var i: i32 = 0;
                // copy upvalues to the top
                while (i < num_upvalues) : (i += 1) lua.pushValue(-num_upvalues);
                lua.pushCClosure(func, num_upvalues);
            } else lua.pushBoolean(false); // register a placeholder
            lua.setField(-(num_upvalues + 2), f.name);
        }
        lua.pop(num_upvalues);
    }

    /// Sets the metatable of the object on the top of the stack as the metatable associated
    /// with `table_name` in the registry
    pub fn setMetatableAux(lua: *Lua, table_name: [:0]const u8) void {
        c.luaL_setmetatable(lua.state, table_name);
    }

    /// This function works like `Lua.checkUserdata()` except it returns null instead of raising an error on fail
    pub fn testUserdata(lua: *Lua, arg: i32, type_name: [:0]const u8) ?*anyopaque {
        return c.luaL_testudata(lua.state, arg, type_name);
    }

    /// Converts any Lua value at the given index into a string in a reasonable format
    pub fn toLStringAux(lua: *Lua, index: i32) []const u8 {
        var length: usize = undefined;
        const ptr = c.luaL_tolstring(lua.state, index, &length);
        return ptr[0..length];
    }

    /// Creates and pushes a traceback of the stack of `other`
    pub fn traceback(lua: *Lua, other: Lua, msg: [:0]const u8, level: i32) void {
        c.luaL_traceback(lua.state, other.state, msg, level);
    }

    /// Raises a type error for the argument `arg` of the C function that called it
    pub fn typeError(lua: *Lua, arg: i32, type_name: [:0]const u8) noreturn {
        _ = c.luaL_typeerror(lua.state, arg, type_name);
        unreachable;
    }

    /// Returns the name of the type of the value at the given `index`
    /// TODO: maybe typeNameIndex?
    pub fn typeNameAux(lua: *Lua, index: i32) [:0]const u8 {
        return std.mem.span(c.luaL_typename(lua.state, index));
    }

    /// Releases the reference `r` from the table at index `index`
    pub fn unref(lua: *Lua, index: i32, r: i32) void {
        c.luaL_unref(lua.state, index, r);
    }

    /// Pushes onto the stack a string identifying the current position of the control
    /// at the call stack `level`
    pub fn where(lua: *Lua, level: i32) void {
        c.luaL_where(lua.state, level);
    }

    // Standard library loading functions
    //
    // TODO: opening libs can run arbitrary Lua code and can throw any error

    /// Opens the specified standard library functions
    /// Behaves like openLibs, but allows specifying which libraries
    /// to expose to the global table rather than all of them
    pub fn open(lua: *Lua, libs: Libs) void {
        if (libs.base) lua.requireF(c.LUA_GNAME, c.luaopen_base, true);
        if (libs.coroutine) lua.requireF(c.LUA_COLIBNAME, c.luaopen_coroutine, true);
        if (libs.package) lua.requireF(c.LUA_LOADLIBNAME, c.luaopen_package, true);
        if (libs.string) lua.requireF(c.LUA_STRLIBNAME, c.luaopen_string, true);
        if (libs.utf8) lua.requireF(c.LUA_UTF8LIBNAME, c.luaopen_utf8, true);
        if (libs.table) lua.requireF(c.LUA_TABLIBNAME, c.luaopen_table, true);
        if (libs.math) lua.requireF(c.LUA_MATHLIBNAME, c.luaopen_math, true);
        if (libs.io) lua.requireF(c.LUA_IOLIBNAME, c.luaopen_io, true);
        if (libs.os) lua.requireF(c.LUA_OSLIBNAME, c.luaopen_os, true);
        if (libs.debug) lua.requireF(c.LUA_DBLIBNAME, c.luaopen_debug, true);
    }

    /// Open all standard libraries
    pub fn openLibs(lua: *Lua) void {
        c.luaL_openlibs(lua.state);
    }

    /// Open the basic standard library
    pub fn openBase(lua: *Lua) void {
        _ = c.luaopen_base(lua.state);
    }

    /// Open the coroutine standard library
    pub fn openCoroutine(lua: *Lua) void {
        _ = c.luaopen_coroutine(lua.state);
    }

    /// Open the package standard library
    pub fn openPackage(lua: *Lua) void {
        _ = c.luaopen_package(lua.state);
    }

    /// Open the string standard library
    pub fn openString(lua: *Lua) void {
        _ = c.luaopen_string(lua.state);
    }

    /// Open the UTF-8 standard library
    pub fn openUtf8(lua: *Lua) void {
        _ = c.luaopen_utf8(lua.state);
    }

    /// Open the table standard library
    pub fn openTable(lua: *Lua) void {
        _ = c.luaopen_table(lua.state);
    }

    /// Open the math standard library
    pub fn openMath(lua: *Lua) void {
        _ = c.luaopen_math(lua.state);
    }

    /// Open the io standard library
    pub fn openIO(lua: *Lua) void {
        _ = c.luaopen_io(lua.state);
    }

    /// Open the os standard library
    pub fn openOS(lua: *Lua) void {
        _ = c.luaopen_os(lua.state);
    }

    /// Open the debug standard library
    pub fn openDebug(lua: *Lua) void {
        _ = c.luaopen_debug(lua.state);
    }
};

/// A string buffer allowing for Zig code to build Lua strings piecemeal
/// All LuaBuffer functions are wrapped in this struct to make the API more convenient to use
pub const Buffer = struct {
    b: LuaBuffer = undefined,

    /// Initialize a Lua string buffer
    pub fn init(buf: *Buffer, lua: Lua) void {
        c.luaL_buffinit(lua.state, &buf.b);
    }

    /// Initialize a Lua string buffer with an initial size
    pub fn initSize(buf: *Buffer, lua: Lua, size: usize) []u8 {
        return c.luaL_buffinitsize(lua.state, &buf.b, size)[0..size];
    }

    /// Internal Lua type for a string buffer
    pub const LuaBuffer = c.luaL_Buffer;

    pub const buffer_size = c.LUAL_BUFFERSIZE;

    /// Adds `byte` to the buffer
    pub fn addChar(buf: *Buffer, byte: u8) void {
        // the postfix inc/dec expression is not yet supported by translate-c
        // c.luaL_addchar(&buf.b, byte);
        // TODO: revisit this once Zig bug is fixed (perhaps fix bug?)
        var lua_buf = &buf.b;
        if (lua_buf.n >= lua_buf.size) _ = buf.prepSize(1);
        lua_buf.b[lua_buf.n] = byte;
        lua_buf.n += 1;
    }

    /// Adds a copy of the string `str` to the buffer
    pub fn addGSub(buf: *Buffer, str: [:0]const u8, pat: [:0]const u8, rep: [:0]const u8) void {
        c.luaL_addgsub(&buf.b, str, pat, rep);
    }

    /// Adds the string to the buffer
    pub fn addLString(buf: *Buffer, str: []const u8) void {
        c.luaL_addlstring(&buf.b, @ptrCast([*c]const u8, str), str.len);
    }

    /// Adds to the buffer a string of `length` previously copied to the buffer area
    pub fn addSize(buf: *Buffer, length: usize) void {
        // another function translate-c couldn't handle
        // c.luaL_addsize(&buf.b, length);
        var lua_buf = &buf.b;
        lua_buf.n += length;
    }

    /// Adds the zero-terminated string pointed to by `str` to the buffer
    pub fn addString(buf: *Buffer, str: [:0]const u8) void {
        c.luaL_addstring(&buf.b, str);
    }

    /// Adds the value on the top of the stack to the buffer
    /// Pops the value
    pub fn addValue(buf: *Buffer) void {
        c.luaL_addvalue(&buf.b);
    }

    /// Returns a slice of the current content of the buffer
    /// Any changes to the buffer may invalidate this slice
    pub fn addr(buf: *Buffer) []u8 {
        const length = buf.b.n;
        return c.luaL_buffaddr(&buf.b)[0..length];
    }

    /// Returns the length of the buffer
    pub fn len(buf: *Buffer) usize {
        return c.luaL_bufflen(&buf.b);
    }

    /// Removes `num` bytes from the buffer
    /// TODO: perhaps error check?
    pub fn sub(buf: *Buffer, num: usize) void {
        // Another bug with translate-c
        // c.luaL_buffsub(&buf.b, num);
        var lua_buf = &buf.b;
        lua_buf.n -= num;
    }

    /// Equivalent to prepSize with a buffer size of Buffer.buffer_size
    pub fn prep(buf: *Buffer) []u8 {
        return buf.prepSize(buffer_size)[0..buffer_size];
    }

    /// Returns an address to a space of `size` where you can copy a string
    /// to be added to the buffer
    /// you must call `Buffer.addSize` to actually add it to the buffer
    pub fn prepSize(buf: *Buffer, size: usize) []u8 {
        return c.luaL_prepbuffsize(&buf.b, size)[0..size];
    }

    /// Finishes the use of the buffer leaving the final string on the top of the stack
    pub fn pushResult(buf: *Buffer) void {
        c.luaL_pushresult(&buf.b);
    }

    /// Equivalent to `Buffer.addSize()` followed by `Buffer.pushResult()`
    pub fn pushResultSize(buf: *Buffer, size: usize) void {
        c.luaL_pushresultsize(&buf.b, size);
    }
};

// Helper functions to make the ziglua API easier to use

pub const ZigFn = fn (lua: *Lua) i32;
pub const ZigHookFn = fn (lua: *Lua, ar: *DebugInfo) void;
pub const ZigContFn = fn (lua: *Lua, status: bool, ctx: KContext) c_int;
pub const ZigReaderFn = fn (lua: *Lua, data: *anyopaque) ?[]const u8;
pub const ZigWarnFn = fn (data: ?*anyopaque, msg: []const u8, to_cont: bool) void;
pub const ZigWriterFn = fn (lua: *Lua, buf: []const u8, data: *anyopaque) bool;

fn TypeOfWrap(comptime T: type) type {
    return switch (T) {
        LuaState => Lua,
        ZigFn => CFn,
        ZigHookFn => CHookFn,
        ZigContFn => CContFn,
        ZigReaderFn => CReaderFn,
        ZigWarnFn => CWarnFn,
        ZigWriterFn => CWriterFn,
        else => @compileError("unsupported type given to wrap: '" ++ @typeName(T) ++ "'"),
    };
}

/// Wraps the given value for use in the Lua API
/// Supports the following:
/// * `LuaState` => `Lua`
pub fn wrap(comptime value: anytype) TypeOfWrap(@TypeOf(value)) {
    const T = @TypeOf(value);
    return switch (T) {
        // NOTE: should most likely be ?*LuaState and value.?
        LuaState => Lua{ .state = value },
        ZigFn => wrapZigFn(value),
        ZigHookFn => wrapZigHookFn(value),
        ZigContFn => wrapZigContFn(value),
        ZigReaderFn => wrapZigReaderFn(value),
        ZigWarnFn => wrapZigWarnFn(value),
        ZigWriterFn => wrapZigWriterFn(value),
        else => @compileError("unsupported type given to wrap: '" ++ @typeName(T) ++ "'"),
    };
}

/// Wrap a ZigFn in a CFn for passing to the API
fn wrapZigFn(comptime f: ZigFn) CFn {
    return struct {
        fn inner(state: ?*LuaState) callconv(.C) c_int {
            // this is called by Lua, state should never be null
            var lua: Lua = .{ .state = state.? };
            // TODO: should we pass a pointer to the lua state? no real reason to
            return @call(.{ .modifier = .always_inline }, f, .{&lua});
        }
    }.inner;
}

/// Wrap a ZigHookFn in a CHookFn for passing to the API
fn wrapZigHookFn(comptime f: ZigHookFn) CHookFn {
    return struct {
        fn inner(state: ?*LuaState, ar: *DebugInfo) callconv(.C) void {
            // this is called by Lua, state should never be null
            var lua: Lua = .{ .state = state.? };
            @call(.{ .modifier = .always_inline }, f, .{ &lua, ar.? });
        }
    }.inner;
}

/// Wrap a ZigContFn in a CContFn for passing to the API
fn wrapZigContFn(comptime f: ZigContFn) CContFn {
    return struct {
        fn inner(state: ?*LuaState, status: c_int, ctx: KContext) callconv(.C) c_int {
            // this is called by Lua, state should never be null
            var lua: Lua = .{ .state = state.? };
            return @call(.{ .modifier = .always_inline }, f, .{ &lua, status != 0, ctx });
        }
    }.inner;
}

/// Wrap a ZigReaderFn in a CReaderFn for passing to the API
fn wrapZigReaderFn(comptime f: ZigReaderFn) CReaderFn {
    return struct {
        fn inner(state: ?*LuaState, data: ?*anyopaque, size: [*c]usize) callconv(.C) [*c]const u8 {
            var lua: Lua = .{ .state = state.? };
            if (@call(.{ .modifier = .always_inline }, f, .{ &lua, data.? })) |buffer| {
                size.* = buffer.len;
                return buffer;
            } else {
                size.* = 0;
                return null;
            }
        }
    }.inner;
}

/// Wrap a ZigWarnFn in a CWarnFn for passing to the API
fn wrapZigWarnFn(comptime f: ZigWarnFn) CWarnFn {
    return struct {
        fn inner(data: ?*anyopaque, msg: [*c]const u8, to_cont: c_int) callconv(.C) void {
            // warning messages emitted from Lua should be null-terminated for display
            var message = std.mem.span(@ptrCast([*:0]const u8, msg));
            @call(.{ .modifier = .always_inline }, f, .{ data, message, to_cont != 0 });
        }
    }.inner;
}

/// Wrap a ZigWriterFn in a CWriterFn for passing to the API
fn wrapZigWriterFn(comptime f: ZigWriterFn) CWriterFn {
    return struct {
        fn inner(state: ?*LuaState, buf: ?*anyopaque, size: usize, data: ?*anyopaque) callconv(.C) c_int {
            // this is called by Lua, state should never be null
            var lua: Lua = .{ .state = state.? };
            const buffer = @ptrCast([*]const u8, buf)[0..size];
            return @boolToInt(@call(
                .{ .modifier = .always_inline },
                f,
                .{ &lua, buffer, data.? },
            ));
        }
    }.inner;
}

// Tests

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;

// until issue #1717 we need to use the struct workaround
const add = struct {
    fn addInner(l: *Lua) i32 {
        const a = l.toInteger(1);
        const b = l.toInteger(2);
        l.pushInteger(a + b);
        return 1;
    }
}.addInner;

const sub = struct {
    fn subInner(l: *Lua) i32 {
        const a = l.toInteger(1);
        const b = l.toInteger(2);
        l.pushInteger(a - b);
        return 1;
    }
}.subInner;

fn failing_alloc(data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    _ = data;
    _ = ptr;
    _ = osize;
    _ = nsize;
    return null;
}

test "initialization" {
    // initialize the Zig wrapper
    var lua = try Lua.init(testing.allocator);
    lua.deinit();

    // attempt to initialize the Zig wrapper with no memory
    try expectError(Error.Memory, Lua.init(testing.failing_allocator));

    // use the library directly
    var allocator = testing.allocator_instance.allocator();
    lua = try Lua.newState(Lua.alloc, &allocator);
    lua.close();

    // use the library with a bad AllocFn
    try expectError(Error.Memory, Lua.newState(failing_alloc, null));

    // use the auxiliary library (uses libc realloc and cannot be checked for leaks!)
    lua = try Lua.newStateAux();
    lua.close();
}

test "alloc functions" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    // get default allocator
    var data: *anyopaque = undefined;
    try expectEqual(Lua.alloc, lua.getAllocF(&data));

    // set a bad allocator
    lua.setAllocF(failing_alloc, null);
    try expectEqual(failing_alloc, lua.getAllocF(&data));

    // reset the good one
    lua.setAllocF(Lua.alloc, lua.allocator);
}

test "standard library loading" {
    // open a subset of standard libraries with Zig wrapper
    {
        var lua = try Lua.init(testing.allocator);
        defer lua.deinit();
        lua.open(.{
            .base = true,
            .coroutine = true,
            .package = true,
            .string = true,
            .utf8 = true,
            .table = true,
            .math = true,
            .io = true,
            .os = true,
            .debug = true,
        });
    }

    // open all standard libraries
    {
        var lua = try Lua.init(testing.allocator);
        defer lua.deinit();
        lua.openLibs();
    }

    // open all standard libraries with individual functions
    // NOTE: these functions are only useful if you want to load the standard
    // packages into a non-standard table
    {
        var lua = try Lua.init(testing.allocator);
        defer lua.deinit();
        lua.openBase();
        lua.openCoroutine();
        lua.openPackage();
        lua.openString();
        lua.openUtf8();
        lua.openTable();
        lua.openMath();
        lua.openIO();
        lua.openOS();
        lua.openDebug();
    }
}

test "arithmetic (lua_arith)" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    lua.pushNumber(10);
    lua.pushNumber(42);

    lua.arith(.add);
    try expectEqual(@as(f64, 52), lua.toNumber(1));

    lua.pushNumber(12);
    lua.arith(.sub);
    try expectEqual(@as(f64, 40), lua.toNumber(1));

    lua.pushNumber(2);
    lua.arith(.mul);
    try expectEqual(@as(f64, 80), lua.toNumber(1));

    lua.pushNumber(8);
    lua.arith(.div);
    try expectEqual(@as(f64, 10), lua.toNumber(1));

    // prep for idiv
    lua.pushNumber(1);
    lua.arith(.add);
    lua.pushNumber(2);
    lua.arith(.idiv);
    try expectEqual(@as(f64, 5), lua.toNumber(1));

    lua.pushNumber(2);
    lua.arith(.mod);
    try expectEqual(@as(f64, 1), lua.toNumber(1));

    lua.arith(.unm);
    try expectEqual(@as(f64, -1), lua.toNumber(1));

    lua.arith(.unm);
    lua.pushNumber(2);
    lua.arith(.shl);
    try expectEqual(@as(i64, 4), lua.toInteger(1));

    lua.pushNumber(1);
    lua.arith(.shr);
    try expectEqual(@as(i64, 2), lua.toInteger(1));

    lua.pushNumber(4);
    lua.arith(.bor);
    try expectEqual(@as(i64, 6), lua.toInteger(1));

    lua.pushNumber(1);
    lua.arith(.band);
    try expectEqual(@as(i64, 0), lua.toInteger(1));

    lua.pushNumber(1);
    lua.arith(.bxor);
    try expectEqual(@as(i64, 1), lua.toInteger(1));

    lua.arith(.bnot); // 0xFFFFFFFFFFFFFFFE which is -2
    try expectEqual(@as(i64, -2), lua.toInteger(1));

    lua.pushNumber(3);
    lua.arith(.pow);
    try expectEqual(@as(i64, -8), lua.toInteger(1));
}

test "type of" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    var value: i32 = 0;

    lua.pushNil();
    try expect(lua.isNil(1));
    try expect(lua.isNoneOrNil(1));
    try expect(lua.isNoneOrNil(2));
    try expect(lua.isNone(2));
    lua.pop(1);

    lua.pushBoolean(true);
    lua.pushGlobalTable();
    lua.pushInteger(1);
    lua.pushLightUserdata(&value);
    lua.pushNil();
    lua.pushNumber(0.1);
    _ = lua.pushThread();
    _ = lua.pushString("all your codebase are belong to us");
    try expectEqual(@as(?[*]const u8, null), lua.pushString(null));
    lua.pushCFunction(wrap(add));
    _ = lua.pushLString("hello world");
    _ = lua.pushFString("%s %s %d", .{ "hello", "world", @as(i32, 10) });
    lua.pushValue(1);

    // test both typeof and is functions
    try expectEqual(LuaType.boolean, lua.typeOf(1));
    try expectEqual(LuaType.table, lua.typeOf(2));
    try expectEqual(LuaType.number, lua.typeOf(3));
    try expectEqual(LuaType.light_userdata, lua.typeOf(4));
    try expectEqual(LuaType.nil, lua.typeOf(5));
    try expectEqual(LuaType.number, lua.typeOf(6));
    try expectEqual(LuaType.thread, lua.typeOf(7));
    try expectEqual(LuaType.string, lua.typeOf(8));
    try expectEqual(LuaType.nil, lua.typeOf(9));
    try expectEqual(LuaType.function, lua.typeOf(10));
    try expectEqual(LuaType.string, lua.typeOf(11));
    try expectEqual(LuaType.string, lua.typeOf(12));
    try expectEqual(LuaType.boolean, lua.typeOf(13));

    try expect(lua.isBoolean(1));
    try expect(lua.isTable(2));
    try expect(lua.isNumber(3));
    try expect(lua.isLightUserdata(4));
    try expect(lua.isNil(5));
    try expect(lua.isNumber(6));
    try expect(lua.isThread(7));
    try expect(lua.isString(8));
    try expect(lua.isNil(9));
    try expect(lua.isCFunction(10));
    try expect(lua.isFunction(10));
    try expect(lua.isString(11));
    try expect(lua.isString(12));
    try expect(lua.isBoolean(13));

    try expectEqualStrings("hello world 10", lua.toString(12).?);
}

test "typenames" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    try expectEqualStrings("no value", lua.typeName(.none));
    try expectEqualStrings("nil", lua.typeName(.nil));
    try expectEqualStrings("boolean", lua.typeName(.boolean));
    try expectEqualStrings("userdata", lua.typeName(.light_userdata));
    try expectEqualStrings("number", lua.typeName(.number));
    try expectEqualStrings("string", lua.typeName(.string));
    try expectEqualStrings("table", lua.typeName(.table));
    try expectEqualStrings("function", lua.typeName(.function));
    try expectEqualStrings("userdata", lua.typeName(.userdata));
    try expectEqualStrings("thread", lua.typeName(.thread));
}

test "executing string contents" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    try lua.loadString("f = function(x) return x + 10 end");
    try lua.protectedCall(0, 0, 0);
    try lua.loadString("a = f(2)");
    try lua.protectedCall(0, 0, 0);

    try expectEqual(LuaType.function, lua.getGlobal("f"));
    lua.pop(1);
    try expectEqual(LuaType.number, lua.getGlobal("a"));
    try expectEqual(@as(i64, 12), lua.toInteger(1));

    try expectError(Error.Syntax, lua.loadString("bad syntax"));
    try lua.loadString("a = g()");
    try expectError(Error.Runtime, lua.protectedCall(0, 0, 0));
}

test "filling and checking the stack" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    try expectEqual(@as(i32, 0), lua.getTop());

    // We want to push 30 values onto the stack
    // this should work without fail
    try lua.checkStack(30);

    var count: i32 = 0;
    while (count < 30) : (count += 1) {
        lua.pushNil();
    }

    try expectEqual(@as(i32, 30), lua.getTop());

    // this should fail (beyond max stack size)
    try expectError(Error.Fail, lua.checkStack(1_000_000));

    // this is small enough it won't fail (would raise an error if it did)
    lua.checkStackAux(40, null);
    while (count < 40) : (count += 1) {
        lua.pushNil();
    }

    try expectEqual(@as(i32, 40), lua.getTop());
}

test "stack manipulation" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    // add some numbers to manipulate
    var num: i32 = 1;
    while (num <= 10) : (num += 1) {
        lua.pushInteger(num);
    }
    try expectEqual(@as(i32, 10), lua.getTop());

    lua.setTop(12);
    try expectEqual(@as(i32, 12), lua.getTop());
    try expect(lua.isNil(-1));

    // rotate the two nils to the bottom of the stack
    lua.rotate(1, 2);
    try expect(lua.isNil(1));
    try expect(lua.isNil(2));

    lua.remove(2);
    try expect(lua.isNil(1));
    try expect(lua.isInteger(2));

    lua.insert(1);
    try expect(lua.isInteger(1));
    try expect(lua.isNil(2));

    lua.replace(2);
    try expect(lua.isInteger(2));
    try expectEqual(@as(i32, 10), lua.getTop());

    lua.copy(1, 2);
    try expectEqual(@as(i64, 10), lua.toInteger(1));
    try expectEqual(@as(i64, 10), lua.toInteger(2));
    try expectEqual(@as(i64, 1), lua.toInteger(3));
    try expectEqual(@as(i64, 8), lua.toInteger(-1));

    lua.setTop(0);
    try expectEqual(@as(i32, 0), lua.getTop());
}

test "calling a function" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    lua.register("zigadd", wrap(add));
    _ = lua.getGlobal("zigadd");
    lua.pushInteger(10);
    lua.pushInteger(32);

    // protectedCall is safer, but we might as well exercise call when
    // we know it should be safe
    lua.call(2, 1);

    try expectEqual(@as(i64, 42), lua.toInteger(1));
}

test "version" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    try expectEqual(@as(f64, 504), lua.version());
}

test "string buffers" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    var buffer: Buffer = undefined;
    buffer.init(lua);
    try expectEqual(@as(usize, 0), buffer.len());

    buffer.addChar('z');
    buffer.addChar('i');
    buffer.addChar('g');
    buffer.addString("lua");
    try expectEqual(@as(usize, 6), buffer.len());

    buffer.sub(3);
    try expectEqual(@as(usize, 3), buffer.len());

    var str = buffer.prepSize(3);
    str[0] = 'l';
    str[1] = 'u';
    str[2] = 'a';
    try expectEqual(@as(usize, 3), buffer.len());
    buffer.addSize(3);
    try expectEqual(@as(usize, 6), buffer.len());
    try expectEqualStrings("ziglua", buffer.addr());

    buffer.addLString(" api ");
    try expectEqualStrings("ziglua api ", buffer.addr());

    lua.pushNumber(5.4);
    buffer.addValue();
    try expectEqual(@as(usize, 14), buffer.len());
    try expectEqualStrings("ziglua api 5.4", buffer.addr());

    buffer.sub(4);
    try expectEqualStrings("ziglua api", buffer.addr());

    buffer.addGSub(" some string here", "string", "text");
    try expectEqualStrings("ziglua api some text here", buffer.addr());

    buffer.pushResult();
    try expectEqualStrings("ziglua api some text here", lua.toString(-1).?);

    // now test a small buffer
    buffer = undefined;
    var b = buffer.initSize(lua, 3);
    b[0] = 'a';
    b[1] = 'b';
    b[2] = 'c';
    buffer.addSize(3);
    b = buffer.prep();
    std.mem.copy(u8, b, "defghijklmnopqrstuvwxyz");
    buffer.pushResultSize(23);
    try expectEqualStrings("abcdefghijklmnopqrstuvwxyz", lua.toString(-1).?);
}

test "global table" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    // open some libs so we can inspect them
    lua.open(.{ .math = true, .base = true });
    lua.openMath();
    lua.pushGlobalTable();

    // find the print function
    _ = lua.pushString("print");
    try expectEqual(LuaType.function, lua.getTable(-2));

    // index the global table in the global table
    try expectEqual(LuaType.table, lua.getField(-2, "_G"));

    // find pi in the math table
    try expectEqual(LuaType.table, lua.getField(-1, "math"));
    try expectEqual(LuaType.number, lua.getField(-1, "pi"));

    // but the string table should be nil
    lua.pop(2);
    try expectEqual(LuaType.nil, lua.getField(-1, "string"));
}

test "function registration" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    // register all functions as part of a table
    const funcs = [_]FnReg{
        .{ .name = "add", .func = wrap(add) },
        .{ .name = "sub", .func = wrap(sub) },
        .{ .name = "placeholder", .func = null },
    };
    lua.newTable();
    lua.setFuncs(&funcs, 0);

    try expectEqual(LuaType.boolean, lua.getField(-1, "placeholder"));
    lua.pop(1);
    try expectEqual(LuaType.function, lua.getField(-1, "add"));
    lua.pop(1);
    try expectEqual(LuaType.function, lua.getField(-1, "sub"));

    // also try calling the sub function sub(42, 40)
    lua.pushInteger(42);
    lua.pushInteger(40);
    try lua.protectedCall(2, 1, 0);
    try expectEqual(@as(Integer, 2), lua.toInteger(-1));

    // now test the newlib variation to build a library from functions
    // indirectly tests newLibTable
    lua.newLib(&funcs);
    // add functions to the global table under "funcs"
    lua.setGlobal("funcs");

    try lua.doString("funcs.add(10, 20)");
    try lua.doString("funcs.sub('10', 20)");
    try expectError(Error.Runtime, lua.doString("funcs.placeholder()"));
}

test "panic fn" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();

    // just test setting up the panic function
    // it uses longjmp so cannot return here to test
    // NOTE: perhaps a later version of zig can test an expected fail
    const panicFn = wrap(struct {
        fn inner(l: *Lua) i32 {
            _ = l;
            return 0;
        }
    }.inner);
    try expectEqual(@as(?CFn, null), lua.atPanic(panicFn));
}

test "refs" {
    // temporary test that includes a reference to all functions so
    // they will be type-checked

    // stdlib
    _ = Lua.absIndex;
    _ = Lua.closeSlot;
    _ = Lua.compare;
    _ = Lua.concat;
    _ = Lua.createTable;
    _ = Lua.dump;
    _ = Lua.raiseError;
    _ = Lua.gc;
    _ = Lua.getExtraSpace;
    _ = Lua.getI;
    _ = Lua.getIUserValue;
    _ = Lua.getMetatable;
    _ = Lua.isUserdata;
    _ = Lua.isYieldable;
    _ = Lua.len;
    _ = Lua.load;
    _ = Lua.newThread;
    _ = Lua.newUserdataUV;
    _ = Lua.next;
    _ = Lua.numberToInteger;
    _ = Lua.rawEqual;
    _ = Lua.rawGet;
    _ = Lua.rawGetP;
    _ = Lua.rawLen;
    _ = Lua.rawSet;
    _ = Lua.rawSetI;
    _ = Lua.rawSetP;
    _ = Lua.resetThread;
    _ = Lua.setField;
    _ = Lua.setI;
    _ = Lua.setIUserValue;
    _ = Lua.setMetatable;
    _ = Lua.setTable;
    _ = Lua.setWarnF;
    _ = Lua.status;
    _ = Lua.stringToNumber;
    _ = Lua.toBoolean;
    _ = Lua.toCFunction;
    _ = Lua.toClose;
    _ = Lua.toIntegerX;
    _ = Lua.toNumberX;
    _ = Lua.toPointer;
    _ = Lua.toThread;
    _ = Lua.toUserdata;
    _ = Lua.upvalueIndex;
    _ = Lua.warning;
    _ = Lua.xMove;
    _ = Lua.yield;
    _ = Lua.yieldCont;

    // debug
    _ = Lua.getHook;
    _ = Lua.getHookCount;
    _ = Lua.getHookMask;
    _ = Lua.getInfo;
    _ = Lua.getLocal;
    _ = Lua.getStack;
    _ = Lua.getUpvalue;
    _ = Lua.setHook;
    _ = Lua.setLocal;
    _ = Lua.setUpvalue;
    _ = Lua.upvalueId;
    _ = Lua.upvalueJoin;

    // auxlib
    _ = Lua.argCheck;
    _ = Lua.argError;
    _ = Lua.argExpected;
    _ = Lua.callMeta;
    _ = Lua.checkAny;
    _ = Lua.checkInteger;
    _ = Lua.checkLString;
    _ = Lua.checkNumber;
    _ = Lua.checkOption;
    _ = Lua.checkString;
    _ = Lua.checkType;
    _ = Lua.checkUserdata;
    _ = Lua.checkVersion;
    _ = Lua.doFile;
    _ = Lua.raiseErrorAux;
    _ = Lua.exeResult;
    _ = Lua.fileResult;
    _ = Lua.getMetaField;
    _ = Lua.getMetatableAux;
    _ = Lua.getSubtable;
    _ = Lua.gSub;
    _ = Lua.lenAux;
    _ = Lua.loadBuffer;
    _ = Lua.loadBufferX;
    _ = Lua.loadFile;
    _ = Lua.loadFileX;
    _ = Lua.newMetatable;
    _ = Lua.optInteger;
    _ = Lua.optLString;
    _ = Lua.optNumber;
    _ = Lua.optString;
    _ = Lua.pushFail;
    _ = Lua.requireF;
    _ = Lua.setMetatableAux;
    _ = Lua.testUserdata;
    _ = Lua.toLStringAux;
    _ = Lua.traceback;
    _ = Lua.typeError;
    _ = Lua.typeNameAux;
    _ = Lua.unref;
    _ = Lua.where;
}
