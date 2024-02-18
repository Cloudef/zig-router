const std = @import("std");
const getty = @import("getty");

pub const Error = error{ SyntaxError, UnexpectedEndOfInput };

const Allocator = std.mem.Allocator;

fn StructAccess(comptime D: type) type {
    return struct {
        d: *D,
        const Self = @This();

        pub usingnamespace getty.de.MapAccess(
            *Self,
            Err,
            .{
                .nextKeySeed = nextKeySeed,
                .nextValueSeed = nextValueSeed,
            },
        );

        const De = D.@"getty.Deserializer";
        const Err = De.Err;

        fn nextKeySeed(self: *Self, _: Allocator, seed: anytype) Err!?@TypeOf(seed).Value {
            if (@TypeOf(seed).Value != []const u8) {
                @compileError("expected key type to be `[]const u8`");
            }
            return self.d.tokens.next();
        }

        fn nextValueSeed(self: *Self, ally: Allocator, seed: anytype) Err!@TypeOf(seed).Value {
            return try seed.deserialize(ally, self.d.deserializer());
        }
    };
}

/// Query deserializer
pub fn Deserializer(comptime dbt: anytype) type {
    return struct {
        tokens: std.mem.SplitIterator(u8, .any),

        const Self = @This();

        pub fn end(self: *Self) Err!void {
            if (self.tokens.next() != null) {
                return error.SyntaxError;
            }
        }

        pub usingnamespace getty.Deserializer(
            *Self,
            Err,
            dbt,
            null,
            .{
                .deserializeIgnored = deserializeIgnored,
                .deserializeVoid = deserializeIgnored,
                .deserializeOptional = deserializeOptional,
                .deserializeStruct = deserializeStruct,
                .deserializeString = deserializeString,
                .deserializeInt = deserializeString,
                .deserializeEnum = deserializeString,
                .deserializeBool = deserializeBool,
                .deserializeFloat = deserializeFloat,
            },
        );

        const Err = getty.de.Error ||
            std.fmt.ParseIntError ||
            std.fmt.ParseFloatError ||
            Error;

        const De = Self.@"getty.Deserializer";

        pub fn init(query: []const u8) Self {
            var self: Self = .{ .tokens = std.mem.splitAny(u8, query, "&=") };
            if (query.len == 0) _ = self.tokens.next();
            return self;
        }

        fn deserializeIgnored(_: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            return try visitor.visitVoid(ally, De);
        }

        fn deserializeOptional(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            if (self.tokens.peek()) |token| {
                if (std.mem.eql(u8, token, "null")) {
                    _ = self.tokens.next();
                    return try visitor.visitNull(ally, De);
                }
            }
            return try visitor.visitSome(ally, self.deserializer());
        }

        fn deserializeStruct(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            var s = StructAccess(Self){ .d = self };
            return try visitor.visitMap(ally, De, s.mapAccess());
        }

        fn deserializeString(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            const token = self.tokens.next() orelse return error.UnexpectedEndOfInput;
            return (try visitor.visitString(ally, De, token, .stack)).value;
        }

        fn deserializeBool(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            const token = self.tokens.next() orelse return error.UnexpectedEndOfInput;
            if (std.mem.eql(u8, token, "true")) return try visitor.visitBool(ally, De, true) else if (std.mem.eql(u8, token, "false")) return try visitor.visitBool(ally, De, false) else return error.InvalidType;
        }

        fn deserializeFloat(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            const Float = switch (@TypeOf(visitor).Value) {
                f16, f32, f64 => |T| T,
                else => f128,
            };
            const token = self.tokens.next() orelse return error.UnexpectedEndOfInput;
            return try visitor.visitFloat(ally, De, try std.fmt.parseFloat(Float, token));
        }
    };
}

/// Deserializes into a value of type `T` from a slice of query.
pub fn fromSlice(
    ally: std.mem.Allocator,
    comptime T: type,
    s: []const u8,
) !getty.de.Result(T) {
    return try fromSliceWith(ally, T, s, null);
}

/// Deserializes into a value of type `T` from a slice of query using a
/// deserialization block or tuple.
pub fn fromSliceWith(
    ally: std.mem.Allocator,
    comptime T: type,
    s: []const u8,
    comptime dbt: anytype,
) !getty.de.Result(T) {
    var d = Deserializer(dbt).init(s);
    return try fromDeserializer(ally, T, &d);
}

/// Deserializes into a value of type `T` from the deserializer `d`.
pub fn fromDeserializer(ally: std.mem.Allocator, comptime T: type, d: anytype) !getty.de.Result(T) {
    var result = try getty.deserialize(ally, T, d.deserializer());
    errdefer result.deinit();
    try d.end();
    return result;
}

test "des" {
    const ser = "foo=bar&bar=foo&boolean=false&int=4&float=2&code=not_found&unset=null&set=true&singleton";

    const Schema = struct {
        foo: []const u8,
        bar: []const u8,
        boolean: bool,
        int: u8,
        float: f32,
        code: std.http.Status,
        unset: ?bool,
        set: ?bool,
        singleton: ?void,
    };

    const v = try fromSlice(std.testing.allocator, Schema, ser);
    defer v.deinit();

    try std.testing.expectEqualSlices(u8, v.value.foo, "bar");
    try std.testing.expectEqualSlices(u8, v.value.bar, "foo");
    try std.testing.expectEqual(v.value.boolean, false);
    try std.testing.expectEqual(v.value.int, 4);
    try std.testing.expectEqual(v.value.float, 2);
    try std.testing.expectEqual(v.value.code, std.http.Status.not_found);
    try std.testing.expectEqual(v.value.unset, null);
    try std.testing.expectEqual(v.value.set, true);
    try std.testing.expectEqual(v.value.singleton, {});
}
