# zig-router

Straightforward HTTP-like request routing.

---

Project is tested against zig 0.13.0

## Sample

```zig
const router = @import("zig-router");

const MyJsonBody = struct {
    float: f32,
    text: []const u8,
    number_with_default: u32 = 42,
};

fn putJson(body: MyJsonBody) !Response {
    log.info("float: {}", .{body.float});
    log.info("text: {s}", .{body.text});
    log.info("number_with_default: {}", .{body.number_with_default});
    return .{ .body = "ok" };
}

const MyPathParams = struct {
    id: []const u8,
    bundle: u32,
};

fn getDynamic(params: MyPathParams) !Response {
    log.info("id: {s}", .{params.id});
    log.info("bundle: {}", .{params.bundle});
    return .{};
}

const MyQuery = struct {
    id: []const u8 = "plz give me a good paying stable job",
    bundle: u32 = 42,
};

fn getQuery(query: MyQuery) !Response {
    log.info("id: {s}", .{query.id});
    log.info("bundle: {}", .{query.bundle});
    return .{};
}

fn getError() !void {
    return error.EPIC_FAIL;
}

fn onRequest(arena: *std.heap.ArenaAllocator, request: Request) !void {
    router.Router(.{
        router.Decoder(.json, router.JsonBodyDecoder(.{}, 4096).decode),
    }, .{
        router.Route(.PUT, "/json", putJson, .{}),
        router.Route(.GET, "/dynamic/:id/paths/:bundle", getDynamic, .{}),
        router.Route(.GET, "/query", getQuery, .{}),
        router.Route(.GET, "/error", getError, .{}),
    }).match(arena.allocator(), .{
        .method = request.method,
        .path = request.path,
        .query = request.query,
        .body = .{ .reader = request.body.reader() }
    }, .{ arena.allocator() }) catch |err| switch (err) {
        error.not_found => return .{ .status = .not_found },
        error.bad_request => return .{ .status = .bad_request },
        else => return err,
    };
}
```

## Depend

Run the following command in zig project root directory.

```sh
zig fetch --save git+https://github.com/Cloudef/zig-router.git
```

In `build.zig` file add the following for whichever modules `zig-router` is required.

```zig
const zig_router = b.dependency("zig-router", .{});
exe.root_module.addImport("zig-router", zig_router.module("zig-router"));
```

You can now import the `zig-router` from zig code.

```zig
const router = @import("zig-router");
```
