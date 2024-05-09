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

fn serve(server_addr: []const u8, server_port: u16, context: anytype) !void {
    const address = try std.net.Address.parseIp(server_addr, server_port);
    var tcp_server = try address.listen(.{
        .reuse_address = true,
        .reuse_port = true,
    });
    defer tcp_server.deinit();

    log.info("Server is running at {s}:{d}", .{ server_addr, server_port });

    accept: while (true) {
        var conn = tcp_server.accept() catch continue;
        defer conn.stream.close();

        var buf: [8192]u8 = undefined;
        var server = std.http.Server.init(conn, &buf);
        while (server.state == .ready) {
            var request = server.receiveHead() catch continue :accept;

            log.info("{s} {s} {s}", .{ @tagName(request.head.method), @tagName(request.head.version), request.head.target });

            context.onRequest.call(.{ &request }, context.userBindings) catch |err| {
                request.respond(@errorName(err), .{
                    .status = .internal_server_error,
                    .transfer_encoding = .none,
                    .keep_alive = false,
                }) catch {};
            };

            continue :accept;
        }
    }
}

pub fn run(address: []const u8, port: u16, comptime onRequest: anytype, bindings: anytype) !void {
    const Context = struct {
        comptime onRequest: CallableType(onRequest) = Callable(onRequest),
        userBindings: @TypeOf(bindings),
    };
    try serve(address, port, Context { .userBindings = bindings });
}
