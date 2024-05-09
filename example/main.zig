const std = @import("std");
const server = @import("server.zig");
const router = @import("zig-router");

pub const log_level: std.log.Level = .debug;
const log = std.log.scoped(.main);

const Response = struct {
    body: ?[]const u8 = null,
};

// curl "http://localhost:8000/" -X GET
fn getIndex() !Response {
    return .{ .body = "Hello from zig-router!" };
}

const MyObjectPathParams = struct {
    key: []const u8,
};

// curl "http://localhost:8000/object/..." -X PUT
fn putObject(params: MyObjectPathParams) !Response {
    log.info("key: {s}", .{params.key});
    return .{};
}

const MyJsonBody = struct {
    float: f32,
    text: []const u8,
    number_with_default: u32 = 42,
};

// curl "http://localhost:8000/json" -X PUT --data '{"float":32.0,"text":"lel"}'
fn putJson(body: MyJsonBody) !Response {
    log.info("float: {}", .{body.float});
    log.info("text: {s}", .{body.text});
    log.info("number_with_default: {}", .{body.number_with_default});
    return .{};
}

const MyPathParams = struct {
    id: []const u8,
    bundle: u32,
};

// curl "http://localhost:8000/dynamic/he-man/paths/42" -X GET
fn getDynamic(params: MyPathParams) !Response {
    log.info("id: {s}", .{params.id});
    log.info("bundle: {}", .{params.bundle});
    return .{};
}

const MyQuery = struct {
    id: []const u8 = "plz give me a good paying stable job",
    bundle: u32 = 42,
};

// curl "http://localhost:8000/query?id=denied" -X GET
fn getQuery(query: MyQuery) !Response {
    log.info("id: {s}", .{query.id});
    log.info("bundle: {}", .{query.bundle});
    return .{};
}

// curl "http://localhost:8000/error" -X GET
fn getError() !Response {
    return error.EPIC_FAIL;
}

fn onRequest(arena: *std.heap.ArenaAllocator, request: *std.http.Server.Request) !void {
    defer {
        const builtin = @import("builtin");
        if (builtin.mode == .Debug) {
            if (arena.queryCapacity() >= 1000000.0) {
                log.debug("memory used to process request: {d:.2} MB", .{@as(f64, @floatFromInt(arena.queryCapacity())) / 1000000.0});
            } else {
                log.debug("memory used to process request: {d:.2} KB", .{@as(f64, @floatFromInt(arena.queryCapacity())) / 1000.0});
            }
            _ = arena.reset(.free_all);
        } else {
            _ = arena.reset(.retain_capacity);
        }
    }

    var target_it = std.mem.splitSequence(u8, request.head.target, "?");
    const path = std.mem.trimRight(u8, target_it.first(), "/");

    const res = router.Router(.{
        router.Decoder(.json, router.JsonBodyDecoder(.{}, 4096).decode),
    }, .{
        router.Route(.GET, "/", getIndex, .{}),
        router.Route(.PUT, "/object/:key", putObject, .{ .strict = false }),
        router.Route(.PUT, "/json", putJson, .{}),
        router.Route(.GET, "/dynamic/:id/paths/:bundle", getDynamic, .{}),
        router.Route(.GET, "/query", getQuery, .{}),
        router.Route(.GET, "/error", getError, .{}),
    }).match(arena.allocator(), .{
        .method = request.head.method,
        .path = if (path.len > 0) path else "/",
        .query = target_it.rest(),
        .body = .{ .reader = try request.reader() },
    }, .{ arena.allocator() }) catch |err| switch (err) {
        error.not_found => {
            request.respond("404 Not Found", .{
                .status = .not_found,
                .transfer_encoding = .none,
                .keep_alive = false,
            }) catch {};
            return;
        },
        error.bad_request => {
            request.respond("404 Bad Request", .{
                .status = .bad_request,
                .transfer_encoding = .none,
                .keep_alive = false,
            }) catch {};
            return;
        },
        else => return err,
    };

    try request.respond(res.body orelse "", .{
        .status = .ok,
        .transfer_encoding = .chunked,
        .keep_alive = false,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    try server.run("127.0.0.1", 8000, onRequest, .{&arena});
}
