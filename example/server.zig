const std = @import("std");
const log = std.log.scoped(.server);

fn CallableType(comptime handler: anytype) type {
    const handler_info = switch (@typeInfo(@TypeOf(handler))) {
        .Fn => |info| info,
        else => @compileError("handler is not a function"),
    };
    const return_type = switch(@typeInfo(handler_info.return_type.?)) {
        .ErrorUnion => |eu| anyerror!eu.payload,
        else => anyerror!handler_info.return_type.?,
    };
    return struct {
        comptime handler: @TypeOf(handler) = handler,
        pub inline fn call(self: @This(), systemBindings: anytype, userBindings: anytype) return_type {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;
            inline for (&args, @typeInfo(@TypeOf(handler)).Fn.params[0..]) |*arg, info| {
                arg.* = blk: {
                    inline for (systemBindings) |bind| if (@TypeOf(bind) == info.type.?) break :blk bind;
                    inline for (userBindings) |bind| if (@TypeOf(bind) == info.type.?) break :blk bind;
                    @compileError(std.fmt.comptimePrint("{} is missing a binding for type: {}", .{@TypeOf(handler), info.type.?}));
                };
            }
            return @call(.auto, self.handler, args);
        }
    };
}

inline fn Callable(comptime handler: anytype) CallableType(handler) {
    return .{};
}

fn serve(allocator: std.mem.Allocator, server_addr: []const u8, server_port: u16, context: anytype) !void {
    var server = std.http.Server.init(allocator, .{ .reuse_address = true });
    defer server.deinit();

    const address = std.net.Address.parseIp(server_addr, server_port) catch unreachable;
    try server.listen(address);

    log.info("Server is running at {s}:{d}", .{ server_addr, server_port });

    outer: while (true) {
        var response = try server.accept(.{ .allocator = allocator });
        defer response.deinit();

        while (response.reset() != .closing) {
            response.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue :outer,
                error.EndOfStream => continue,
                else => return err,
            };

            log.info("{s} {s} {s}", .{ @tagName(response.request.method), @tagName(response.request.version), response.request.target });

            response.status = .ok;
            response.transfer_encoding = .chunked;
            try response.headers.append("connection", "close");

            context.onRequest.call(.{ &response }, context.userBindings) catch |err| {
                response.status = .internal_server_error;
                response.transfer_encoding = .chunked;
                try response.headers.append("connection", "close");
                try response.send();
                response.writeAll(@errorName(err)) catch {};
            };

            try response.finish();
        }
    }
}

pub fn run(allocator: std.mem.Allocator, address: []const u8, port: u16, comptime onRequest: anytype, bindings: anytype) !void {
    const Context = struct {
        comptime onRequest: CallableType(onRequest) = Callable(onRequest),
        userBindings: @TypeOf(bindings),
    };
    try serve(allocator, address, port, Context { .userBindings = bindings });
}
