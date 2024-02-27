//! This module provides functions for routing HTTP style paths to user-defined functions.
//! The router handles automatic decoding of parts of the route request into a user-defined structs.
//! The router also looks for types of each router handler function argument and passes corresponding,
//! value from the provided bindings.
//!
//! This interface gives abstracted way of handling HTTP requests, as seen in many higher-level languages.

const std = @import("std");
const log = std.log.scoped(.router);

/// Additional options for route.
pub const RouteOptions = struct {
    /// When using path parameters the request path must match exactly to the schema
    /// If this is set to false, the request path can have additional components,
    /// In this case the last path parameter will contain rest of the request path.
    strict: bool = true,
};

/// Routing error.
pub const Error = error{
    /// Requested route was not found.
    not_found,
    /// Route was request with malformed content.
    /// This can happen if deserialization of query params, path params, or body fails.
    bad_request,
};

pub const Method = std.http.Method;

/// Body of request.
pub const Body = union(enum) {
    /// Body is stored within a `[]const u8` slice.
    data: []const u8,
    /// Body is backed by a `std.io.AnyReader`
    reader: std.io.AnyReader,
};

/// Helper for decoder implementations in case there is no `std.io.AnyReader support.
/// Reads everything from the AnyReader and then parses using the simpler `[]const u8` decoder.
/// `decoder` must be a function with a signature: `fn decode(std.mem.Allocator, comptime T: type, body: []const u8) !T`
/// In case body is being read from `std.io.AnyReader` the `max_size` argument limits the read.
pub fn FromSliceDecoder(comptime decoder: anytype, comptime max_size: usize) type {
    return struct {
        pub fn decode(allocator: std.mem.Allocator, comptime T: type, body: Body) !T {
            const ret = switch (body) {
                .data => |data| try decoder(allocator, T, data),
                .reader => |reader| try decoder(allocator, T, try reader.readAllAlloc(allocator, max_size)),
            };
            if (@TypeOf(ret) != T) {
                return ret.value; // getty support
            } else {
                return ret;
            }
        }
    };
}

/// Helper for forming a decoder from 2 decoder functions.
/// For example `FromPairDecoder(json.fromSlice, json.fromReader).decode`
/// Gives a valid decoder that uses getty-json.
pub fn FromPairDecoder(comptime slice_decoder: anytype, comptime reader_decoder: anytype) type {
    return struct {
        pub fn decode(allocator: std.mem.Allocator, comptime T: type, body: Body) !T {
            const ret = switch (body) {
                .data => |data| try slice_decoder(allocator, T, data),
                .reader => |reader| try reader_decoder(allocator, T, reader),
            };
            if (@TypeOf(ret) != T) {
                return ret.value; // getty support
            } else {
                return ret;
            }
        }
    };
}

/// Json body decoder using `std.json`
/// In case body is being read from `std.io.AnyReader` the `max_size` argument limits the read.
pub fn JsonBodyDecoder(comptime options: std.json.ParseOptions, comptime max_size: usize) type {
    return FromSliceDecoder((struct {
        pub fn decode(allocator: std.mem.Allocator, comptime T: type, body: []const u8) !T {
            // Router always uses an arena allocator when decoding Body
            // Thus using parseFromSliceLeaky is okay
            return std.json.parseFromSliceLeaky(T, allocator, body, options);
        }
    }).decode, max_size);
}

fn DecoderType(comptime content_type: anytype, comptime decoder: anytype) type {
    return struct {
        comptime content_type: @TypeOf(content_type) = content_type,
        inline fn decode(_: @This(), allocator: std.mem.Allocator, comptime T: type, body: Body) !T {
            return decoder(allocator, T, body);
        }
    };
}

/// Pairs decoder implementation with a content type for the router.
/// `content_type` should be a enum literal.
/// `decoder` should be a function with signature `fn decode(allocator: std.mem.Allocator, comptime T: type, body: Body) !T`
pub inline fn Decoder(comptime content_type: anytype, comptime decoder: anytype) DecoderType(content_type, decoder) {
    return .{};
}

fn RouteType(comptime method: Method, comptime path: []const u8, comptime handler: anytype, comptime opts: RouteOptions) type {
    const handler_info = switch (@typeInfo(@TypeOf(handler))) {
        .Fn => |info| info,
        else => @compileError(std.fmt.comptimePrint("{s} handler is not a function", .{path})),
    };
    if (handler_info.is_generic) @compileError(std.fmt.comptimePrint("{s} handler can't be a generic function", .{path}));
    if (handler_info.is_var_args) @compileError(std.fmt.comptimePrint("{s} handler can't be a variadic function", .{path}));

    const has_dynamic_params = blk: {
        for (handler_info.params) |p| {
            if (std.mem.endsWith(u8, @typeName(p.type.?), "Params") or
                std.mem.endsWith(u8, @typeName(p.type.?), "Query") or
                std.mem.endsWith(u8, @typeName(p.type.?), "Body"))
                break :blk true;
        }
        break :blk false;
    };

    const num_path_components = std.mem.count(u8, path, "/");
    const has_path_params = std.mem.indexOf(u8, path, ":") != null;

    if (num_path_components == 0) {
        @compileError("route must have at least one path component `/`");
    } else if (path.len > 1 and std.mem.endsWith(u8, path, "/")) {
        @compileError(std.fmt.comptimePrint("{s} must not end with an path component `/`", .{path}));
    } else if (std.mem.count(u8, path, "//") > 0) {
        @compileError(std.fmt.comptimePrint("{s} empty path components are not allowed", .{path}));
    }

    _ = std.Uri.parseWithoutScheme(path) catch @compileError(std.fmt.comptimePrint("invalid route path: {s}", .{path}));

    const return_type = switch (@typeInfo(handler_info.return_type.?)) {
        .ErrorUnion => |eu| anyerror!eu.payload,
        else => anyerror!handler_info.return_type.?,
    };

    return struct {
        comptime requires_allocator: bool = has_dynamic_params,
        comptime return_type: type = return_type,

        fn matches(_: @This(), request: anytype) bool {
            if (method != request.method) return false;
            if (comptime has_path_params) {
                if (comptime opts.strict) {
                    if (num_path_components != std.mem.count(u8, request.path, "/")) return false;
                } else {
                    if (num_path_components > std.mem.count(u8, request.path, "/")) return false;
                }
                var ref_tokens = std.mem.tokenizeSequence(u8, path, "/");
                var req_tokens = std.mem.tokenizeSequence(u8, request.path, "/");
                while (true) {
                    const ref_t = ref_tokens.next();
                    const req_t = req_tokens.next();
                    if (comptime opts.strict) {
                        if (ref_t == null and req_t == null) break;
                    } else {
                        if (ref_t == null) break;
                    }
                    if (ref_t == null or req_t == null) return false;
                    if (ref_t.?[0] == ':') continue; // ignore path param
                    if (!std.mem.eql(u8, ref_t.?, req_t.?)) return false;
                }
                return true;
            } else {
                return std.mem.eql(u8, path, request.path);
            }
        }

        fn call(_: @This(), allocator: std.mem.Allocator, maybe_decoder: anytype, request: anytype, bindings: anytype) return_type {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
            inline for (&args, handler_info.params[0..]) |*arg, param| {
                arg.* = blk: {
                    inline for (bindings) |bind| if (@TypeOf(bind) == param.type.?) break :blk bind;
                    if (comptime !has_dynamic_params) {
                        @compileError(std.fmt.comptimePrint("{} is missing a binding for type: {}", .{ @TypeOf(handler), param.type.? }));
                    } else {
                        if (comptime std.mem.endsWith(u8, @typeName(param.type.?), "Params")) {
                            const de_path = @import("de/path.zig");
                            if (de_path.fromSlice(allocator, param.type.?, path, request.path)) |res| {
                                break :blk res.value;
                            } else |err| {
                                log.debug("{} parse failed with error: {}", .{ param.type.?, err });
                            }
                        } else if (comptime std.mem.endsWith(u8, @typeName(param.type.?), "Query")) {
                            const de_query = @import("de/query.zig");
                            if (de_query.fromSlice(allocator, param.type.?, request.query)) |res| {
                                break :blk res.value;
                            } else |err| {
                                log.debug("{} parse failed with error: {}", .{ param.type.?, err });
                            }
                        } else if (comptime std.mem.endsWith(u8, @typeName(param.type.?), "Body")) {
                            if (maybe_decoder) |decoder| {
                                if (decoder.decode(allocator, param.type.?, request.body)) |res| {
                                    break :blk res;
                                } else |err| {
                                    log.debug("{} parse failed with error: {}", .{ param.type.?, err });
                                }
                            } else {
                                log.debug("{} parse failed with error: {s}", .{ param.type.?, "unsupported content-type" });
                            }
                        } else {
                            @compileError(std.fmt.comptimePrint("{} is missing a binding for type: {}", .{ @TypeOf(handler), param.type.? }));
                        }
                        return Error.bad_request;
                    }
                };
            }
            return @call(.auto, handler, args);
        }
    };
}

/// Defines a route.
/// The route responds to `method` on the given `path` by calling the `handler` function.
/// The `path` may be parameterized like so `/foo/:id/path`.
/// The handler will require a struct with suffix `Params` in its type name as a function argument.
/// For example to deserialize the above path succesfully you would use struct like this:
/// `const MyRouteParams = struct { id: u32 };`
/// The deserialization is done using `getty` framework, thus the deserialization can be controlled
/// with struct attributes.
pub inline fn Route(comptime method: Method, comptime path: []const u8, comptime handler: anytype, comptime opts: RouteOptions) RouteType(method, path, handler, opts) {
    return .{};
}

/// Constructs an router.
/// `decoders` is a slice of `Decoder(...)` pairings.
/// `routes` is a slice of `Route(...)` definitions.
pub fn Router(comptime decoders: anytype, comptime routes: anytype) type {
    comptime var content_type_fields: [decoders.len]std.builtin.Type.EnumField = undefined;
    for (decoders, &content_type_fields, 0..) |decoder, *content_type, i| {
        content_type.* = .{ .value = i, .name = @tagName(decoder.content_type) };
    }

    const return_type: type = blk: {
        comptime var rt: ?type = null;
        for (routes) |route| {
            if (rt != null and route.return_type != rt) {
                @compileError("return type for each route handler must be the same");
            }
            rt = route.return_type;
        }
        break :blk rt.?;
    };

    const ContentType = blk: {
        if (content_type_fields.len > 0) {
            break :blk @Type(.{
                .Enum = .{
                    .tag_type = std.math.IntFittingRange(0, content_type_fields.len),
                    .fields = &content_type_fields,
                    .decls = &.{},
                    .is_exhaustive = true,
                },
            });
        } else {
            break :blk void;
        }
    };

    const RequestType = if (content_type_fields.len > 0) struct {
        /// HTTP method.
        method: Method,
        /// Request path.
        /// The router does not strip any trailing slash (/) characters in the path.
        /// If these are a concern, you should use `std.mem.trimRight(u8, path, "/")` for example.
        path: []const u8,
        /// Request query params.
        /// Query params start without the question mark (?) character.
        query: []const u8 = "",
        /// Content type of the body.
        /// Defaults to the first decoder.
        content_type: ContentType = @enumFromInt(content_type_fields[0].value),
        /// Body of the request.
        body: Body = .{ .data = "" },
    } else struct {
        /// HTTP method.
        method: Method,
        /// Request path.
        /// The router does not strip any trailing slash (/) characters in the path.
        /// If these are a concern, you should use `std.mem.trimRight(u8, path, "/")` for example.
        path: []const u8,
        /// Request query params.
        /// Query params start without the question mark (?) character.
        query: []const u8 = "",
    };

    return struct {
        /// Routing request.
        pub const Request = RequestType;

        /// Match router to a request.
        /// Returns `Error.not_found` when route was not found.
        /// Returns `Error.bad_request` when request was not valid.
        pub fn match(allocator: std.mem.Allocator, request: Request, bindings: anytype) return_type {
            const decoder = blk: {
                inline for (decoders) |d| if (d.content_type == request.content_type) break :blk d;
                break :blk null;
            };
            inline for (routes) |route| {
                if (route.matches(request)) {
                    log.info("{} {s}?{s}", .{ request.method, request.path, request.query });
                    if (route.requires_allocator) {
                        var arena = std.heap.ArenaAllocator.init(allocator);
                        defer arena.deinit();
                        return route.call(arena.allocator(), decoder, request, bindings);
                    } else {
                        return route.call(undefined, decoder, request, bindings);
                    }
                }
            }
            return Error.not_found;
        }
    };
}

test "Matching" {
    const fun = struct {
        fn fun() void {}
    }.fun;
    const router = Router(.{}, .{Route(.GET, "/test/route", fun, .{})});
    try router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route" }, .{});
    try std.testing.expectError(Error.not_found, router.match(std.testing.allocator, .{ .method = .GET, .path = "/test" }, .{}));
}

test "Bindings" {
    // To bind custom types into a handler such as this
    const MyThing = struct {
        answer_to_life: u32,
    };

    const router = Router(.{}, .{
        Route(.GET, "/test/route", struct {
            // 1. Have it as a argument to the handler
            fn fun(thing: MyThing) !void {
                try std.testing.expectEqual(thing.answer_to_life, 42);
            }
        }.fun, .{}),
    });

    // 2. Bind value of it in the router.match call
    const thing: MyThing = .{ .answer_to_life = 42 };
    try router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route" }, .{thing});

    // These are compile time checked, no way to test yet
    // https://github.com/ziglang/zig/issues/513
    // const NotMyThing = struct { answer_to_death: u32 };
    // const not_my_thing = NotMyThing { .answer_to_death = 666 };
    // router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route" }, .{});
    // router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route" }, .{not_my_thing});
}

test "Des body" {
    // If you suffix your type with Body then the Router will try to deserialize it from the request body.
    // Router does not come with built-in body decoders so you must provide one with yourself.
    // This example showcases how you can use std.json as a decoder.
    const TestBody = struct {
        foo: []const u8,
        bar: f32,
    };

    const router = Router(.{
        Decoder(.json, JsonBodyDecoder(.{}, 4096).decode),
    }, .{
        Route(.GET, "/test/route", struct {
            fn fun(body: TestBody) !void {
                try std.testing.expectEqualSlices(u8, body.foo, "perkele");
                try std.testing.expectEqual(body.bar, 32.0);
            }
        }.fun, .{}),
    });

    try router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route", .content_type = .json, .body = .{ .data = "{\"foo\":\"perkele\", \"bar\":32.0}" } }, .{});
    try std.testing.expectError(error.bad_request, router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route", .content_type = .json, .body = .{ .data = "{\"foo\":\"perkele\", \"bar\": 32.0, \"weird_field\": true}" } }, .{}));
    try std.testing.expectError(error.bad_request, router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route", .content_type = .json, .body = .{ .data = "{\"foo\":\"perkele\"}" } }, .{}));
}

test "Des query" {
    // If you suffix your type with Query then the Router will try to deserialize it from the request query.
    const TestQuery = struct {
        foo: []const u8,
        bar: f32,
    };

    const router = Router(.{}, .{
        Route(.GET, "/test/route", struct {
            fn fun(query: TestQuery) !void {
                try std.testing.expectEqualSlices(u8, query.foo, "perkele");
                try std.testing.expectEqual(query.bar, 32.0);
            }
        }.fun, .{}),
    });

    try router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route", .query = "foo=perkele&bar=32.0" }, .{});
    try std.testing.expectError(error.bad_request, router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route", .query = "foo=perkele&bar=32.0&weird_field=true" }, .{}));
    try std.testing.expectError(error.bad_request, router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/route", .query = "foo=perkele" }, .{}));
}

test "Des path" {
    // If you suffix your type with Params then the Router will try to deserialize it from the request path.
    const TestParams = struct {
        foo: []const u8,
        bar: f32,
    };

    const router = Router(.{}, .{
        Route(.GET, "/test/:foo/route/:bar", struct {
            fn fun(params: TestParams) !void {
                try std.testing.expectEqualSlices(u8, params.foo, "perkele");
                try std.testing.expectEqual(params.bar, 32.0);
            }
        }.fun, .{}),
        Route(.GET, "/nonstrict/:bar/:foo", struct {
            fn fun(params: TestParams) !void {
                try std.testing.expectEqual(params.bar, 32.0);
                try std.testing.expectEqualSlices(u8, params.foo, "oispa/kaljaa");
            }
        }.fun, .{ .strict = false }),
    });

    try router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/perkele/route/32.0" }, .{});
    try router.match(std.testing.allocator, .{ .method = .GET, .path = "/nonstrict/32.0/oispa/kaljaa" }, .{});
    try std.testing.expectError(error.bad_request, router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/perkele/route/not-bool" }, .{}));
    try std.testing.expectError(error.not_found, router.match(std.testing.allocator, .{ .method = .GET, .path = "/test/perkele/route" }, .{}));
}
