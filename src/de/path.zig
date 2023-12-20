const std = @import("std");
const getty = @import("getty");

pub const Error = error {
    SyntaxError,
    UnexpectedEndOfInput
};

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
            while (try self.d.next()) |token| {
                if (token[0] == ':') return token[1..];
            }
            return null;
        }

        fn nextValueSeed(self: *Self, ally: Allocator, seed: anytype) Err!@TypeOf(seed).Value {
            return try seed.deserialize(ally, self.d.deserializer());
        }
    };
}

/// Query deserializer
pub fn Deserializer(comptime dbt: anytype) type {
     return struct {
        schema: std.mem.TokenIterator(u8, .sequence),
        path: std.mem.TokenIterator(u8, .sequence),
        value: []const u8 = "",

        const Self = @This();

        pub fn end(self: *Self) Err!void {
            if (try self.next() != null) {
                return error.SyntaxError;
            }
        }

        pub fn next(self: *Self) Error!?[]const u8 {
            if (self.schema.peek() == null) return null;
            self.value = self.path.next() orelse return error.UnexpectedEndOfInput;
            return self.schema.next();
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

        pub fn init(schema: []const u8, path: []const u8) Self {
            return .{
                .schema = std.mem.tokenizeSequence(u8, schema, "/"),
                .path = std.mem.tokenizeSequence(u8, path, "/"),
            };
        }

        fn deserializeIgnored(_: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            return try visitor.visitVoid(ally, De);
        }

        fn deserializeOptional(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            if (std.mem.eql(u8, self.value, "null")) return try visitor.visitNull(ally, De);
            return try visitor.visitSome(ally, self.deserializer());
        }

        fn deserializeStruct(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            var s = StructAccess(Self){ .d = self };
            return try visitor.visitMap(ally, De, s.mapAccess());
        }

        fn deserializeString(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            return (try visitor.visitString(ally, De, self.value, .stack)).value;
        }

        fn deserializeBool(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            if (std.mem.eql(u8, self.value, "true")) return try visitor.visitBool(ally, De, true)
            else if (std.mem.eql(u8, self.value, "false")) return try visitor.visitBool(ally, De, false)
            else return error.InvalidType;
        }

        fn deserializeFloat(self: *Self, ally: Allocator, visitor: anytype) Err!@TypeOf(visitor).Value {
            const Float = switch (@TypeOf(visitor).Value) {
                f16, f32, f64 => |T| T,
                else => f128,
            };
            return try visitor.visitFloat(ally, De, try std.fmt.parseFloat(Float, self.value));
        }
    };
}

/// Deserializes into a value of type `T` from a slice of path.
pub fn fromSlice(
    ally: std.mem.Allocator,
    comptime T: type,
    s: []const u8,
    p: []const u8,
) !getty.de.Result(T) {
    return try fromSliceWith(ally, T, s, p, null);
}

/// Deserializes into a value of type `T` from a slice of path using a
/// deserialization block or tuple.
pub fn fromSliceWith(
    ally: std.mem.Allocator,
    comptime T: type,
    s: []const u8,
    p: []const u8,
    comptime dbt: anytype,
) !getty.de.Result(T) {
    var d = Deserializer(dbt).init(s, p);
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
    const schema = "/foo/bar/:name/:thing/:boolean/:int/:float/:code/:unset/:set";
    const path = "/foo/bar/alice/magician/true/4/2/not_found/null/false";

    const Schema = struct {
        name: []const u8,
        thing: []const u8,
        boolean: bool,
        int: u8,
        float: f32,
        code: std.http.Status,
        unset: ?bool,
        set: ?bool,
    };

    const v = try fromSlice(std.testing.allocator, Schema, schema, path);
    defer v.deinit();

    try std.testing.expectEqualSlices(u8, v.value.name, "alice");
    try std.testing.expectEqualSlices(u8, v.value.thing, "magician");
    try std.testing.expectEqual(v.value.boolean, true);
    try std.testing.expectEqual(v.value.int, 4);
    try std.testing.expectEqual(v.value.float, 2);
    try std.testing.expectEqual(v.value.code, std.http.Status.not_found);
    try std.testing.expectEqual(v.value.unset, null);
    try std.testing.expectEqual(v.value.set, false);
}
