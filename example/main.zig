const std = @import("std");
const server = @import("server.zig");
const router = @import("zig-router");

pub const log_level: std.log.Level = .debug;
const log = std.log.scoped(.main);

// curl "http://localhost:8000/" -X GET
fn getIndex(response: *std.http.Server.Response) !void {
    response.send() catch {};
    response.writeAll("Hello from zig-router!") catch {};
}

const MyJsonBody = struct {
    float: f32,
    text: []const u8,
    number_with_default: u32 = 42,
};

// curl "http://localhost:8000/json" -X PUT --data '{"float":32.0,"text":"lel"}'
fn putJson(body: MyJsonBody, response: *std.http.Server.Response) !void {
    log.info("float: {}", .{body.float});
    log.info("text: {s}", .{body.text});
    log.info("number_with_default: {}", .{body.number_with_default});
    response.send() catch {};
}

const MyPathParams = struct {
    id: []const u8,
    bundle: u32,
};

// curl "http://localhost:8000/dynamic/he-man/paths/42" -X GET
fn getDynamic(params: MyPathParams, response: *std.http.Server.Response) !void {
    log.info("id: {s}", .{params.id});
    log.info("bundle: {}", .{params.bundle});
    response.send() catch {};
}

const MyQuery = struct {
    id: []const u8 = "plz give me a good paying stable job",
    bundle: u32 = 42,
};

// curl "http://localhost:8000/query?id=denied" -X GET
fn getQuery(query: MyQuery, response: *std.http.Server.Response) !void {
    log.info("id: {s}", .{query.id});
    log.info("bundle: {}", .{query.bundle});
    response.send() catch {};
}

// curl "http://localhost:8000/error" -X GET
fn getError() !void {
    return error.EPIC_FAIL;
}

fn onRequest(arena: *std.heap.ArenaAllocator, response: *std.http.Server.Response) !void {
    var target_it = std.mem.splitSequence(u8, response.request.target, "?");
    const path = std.mem.trimRight(u8, target_it.first(), "/");

    router.Router(.{
        router.Decoder(.json, router.JsonBodyDecoder(.{}, 4096).decode),
    }, .{
        router.Route(.GET, "/", getIndex),
        router.Route(.PUT, "/json", putJson),
        router.Route(.GET, "/dynamic/:id/paths/:bundle", getDynamic),
        router.Route(.GET, "/query", getQuery),
        router.Route(.GET, "/error", getError),
    }).match(arena.allocator(), .{
        .method = response.request.method,
        .path = if (path.len > 0) path else "/",
        .query = target_it.rest(),
        .body = .{ .reader = response.reader().any() }
    }, .{ arena.allocator(), response }) catch |err| switch (err) {
        error.not_found => {
            response.status = .not_found;
            response.send() catch {};
            response.writeAll("404 Not Found") catch {};
        },
        error.bad_request => {
            response.status = .bad_request;
            response.send() catch {};
            response.writeAll("400 Bad Request") catch {};
        },
        else => return err,
    };

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    try server.run(gpa.allocator(), "127.0.0.1", 8000, onRequest, .{ &arena });
}
