pub const endpoints = [_]Router.Match{
    Router.ALL("", gitHttp),
    Router.ALL("objects", gitHttp),
    Router.ROUTE("info", &[_]Router.Match{
        Router.ALL("", gitHttp),
        Router.ALL("refs", gitHttp),
    }),
    Router.ALL("git-upload-pack", uploadPack),
};

pub fn router(ctx: *Frame) Router.RoutingError!Router.BuildFn {
    std.debug.print("gitweb router {any} {s}\n", .{ ctx.request.method, ctx.uri.peek().? });
    return gitHttp;
}

// TODO
// https://git-scm.com/docs/git-config#Documentation/git-config.txt-receivemaxInputSize
// https://git-scm.com/docs/git-config#Documentation/git-config.txt-receivedenyDeletes

fn gitHttp(f: *Frame) Error!void {
    const qstr = f.request.data.query.bytes;
    if (eql(u8, qstr, "service=git-receive-pack"))
        return receivePack(f);

    return uploadPack(f);
}

fn prepareEnv(f: *const Frame) !std.process.Environ.Map {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const method = @tagName(f.request.method);

    var map = std.process.Environ.Map.init(f.alloc);
    errdefer map.deinit();

    switch (f.downstream.gateway) {
        .zwsgi => |z| for (z.vars.items) |vars| {
            if (eql(u8, vars.key, "HTTP_GIT_PROTOCOL")) {
                std.debug.assert(eql(u8, vars.val, "version=2"));
                try map.put("GIT_PROTOCOL", "version=2");
            }
        },
        else => @panic("not implemented"),
    }
    try map.put("GIT_HTTP_EXPORT_ALL", "true");
    try map.put("REMOTE_ADDR", f.request.remote_addr);
    try map.put("REQUEST_METHOD", method);
    try map.put("QUERY_STRING", "");

    const username = if (f.user) |usr| usr.username orelse "anon" else "anon";

    try map.put("REMOTE_USER", username);

    try map.put("SRCTREE_DIRECT_ENABLED", "true");
    try map.put("SRCTREE_DIRECT_DATADIR", "data/");
    try map.put("SRCTREE_HTTP", "true");
    try map.put("SRCTREE_HOST", try (f.request.host orelse return error.DataMissing).valid());
    try map.put("SRCTREE_REPO", rd.name);

    const qstr = f.request.data.query.bytes;
    if (startsWith(u8, qstr, "service=git-")) {
        if (eql(u8, qstr, "service=git-upload-pack")) {
            try map.put("QUERY_STRING", "service=git-upload-pack");
        } else if (eql(u8, qstr, "service=git-receive-pack")) {
            try map.put("QUERY_STRING", "service=git-receive-pack");
        } else log.warn("query string '{s}'", .{qstr});
    } else log.warn("query string '{s}'", .{qstr});

    if (f.request.headers.getCustom("HTTP_CONTENT_TYPE")) |ct| {
        try map.put("CONTENT_TYPE", ct.list.items[0]);
    } else {
        try map.put("CONTENT_TYPE", "");
    }

    var uri = f.uri;
    uri.reset();
    _ = uri.first();
    _ = uri.next();
    const path_tr = allocPrint(f.alloc, "repos/{s}/{s}", .{ rd.name, uri.rest() }) catch unreachable;
    log.warn("pathtr {s}", .{path_tr});
    try map.put("PATH_TRANSLATED", path_tr);

    return map;
}

fn gzipEncoded(f: *const Frame) bool {
    switch (f.downstream.gateway) {
        .zwsgi => |z| {
            for (z.vars.items) |vars| {
                log.debug("each {s} {s}", .{ vars.key, vars.val });
                if (eql(u8, vars.key, "HTTP_CONTENT_ENCODING")) {
                    if (eql(u8, vars.val, "gzip"))
                        return true;
                    log.err("unexpected encoding", .{});

                    return false;
                }
            }
        },
        else => @panic("not implemented"),
    }
    return false;
}

fn spawn(f: *const Frame) !std.process.Child {
    var map = try prepareEnv(f);
    defer map.deinit();

    return std.process.spawn(f.io, .{
        .argv = &.{ "git", "http-backend" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &map,
    }) catch |err| {
        log.err("Unable to spawn for gitweb {}", .{err});
        return error.ServerFault;
    };
}

fn receivePack(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    if (!rd.exists(.all, f.io)) {
        if (f.user) |_| return try receivePackInternal(f);
        return error.Unrouteable;
    }
    return try receivePackExternal(f);
}

fn autoCreateSkel(f: *Frame) Error!void {
    f.downstream.writer.writeAll("HTTP/1.1 200 OK\r\n" ++
        "Expires: Fri, 01 Jan 1980 00:00:00 GMT\r\n" ++
        "Pragma: no-cache\r\n" ++
        "Cache-Control: no-cache, max-age=0, must-revalidate\r\n" ++
        "Content-Type: application/x-git-receive-pack-advertisement\r\n" ++
        "\r\n") catch
        return log.err("unable to start headers for fake repo", .{});

    try git.protocol.announce(.default, f.downstream.writer);
}

fn receivePackInternal(f: *Frame) Error!void {
    return try autoCreateSkel(f);
}

fn receivePackExternal(f: *Frame) Error!void {
    const gz_encoding = gzipEncoded(f);
    var child = try spawn(f);
    const stdin = child.stdin orelse return error.ServerFault;
    if (f.request.data.post) |pd| {
        var w_b: [6400]u8 = undefined; // This is what I saw while debugging
        var stdin_w = stdin.writer(f.io, &w_b);
        if (gz_encoding) {
            var post_reader: Reader = .fixed(pd.bytes);
            var gz_b: [std.compress.flate.max_window_len]u8 = undefined;
            var gzip: std.compress.flate.Decompress = .init(&post_reader, .gzip, &gz_b);
            _ = gzip.reader.streamRemaining(&stdin_w.interface) catch |err| {
                log.err("gz stream error {}", .{err});
                return error.ServerFault;
            };
        } else {
            try stdin_w.interface.writeAll(pd.bytes);
        }
        try stdin_w.interface.flush();
    }
    child.stdin = null;
    stdin.close(f.io);

    const stdout = child.stdout orelse return error.ServerFault;
    var r_b: [6400]u8 = undefined; // This is what I saw while debugging
    var stdout_r = stdout.reader(f.io, &r_b);

    // we just guess and assume it'll return 200
    // checking would be better
    f.downstream.writer.writeAll("HTTP/1.1 200 OK\r\n") catch
        return debugStderr("unable to start headers", &child, f.io);

    _ = stdout_r.interface.streamRemaining(f.downstream.writer) catch
        return debugStderr("unable to stream body", &child, f.io);

    if (child.wait(f.io)) |chld| {
        log.debug("child {}", .{chld});
        if (chld.exited != 0) return debugStderr("unable to stream body", &child, f.io);
    } else |err| {
        log.err("Error waiting for child {}", .{err});
        return error.ServerFault;
    }
    f.downstream.writer.flush() catch log.err("final flush failed", .{});
}

fn uploadPack(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    if (!rd.exists(.all, f.io) and f.user != null) {
        return try uploadPackInternal(f);
    }
    return try uploadPackExternal(f);
}

const uploadPackExternal = uploadPackInternal;

fn uploadPackInternal(f: *Frame) Error!void {
    const gz_encoding = gzipEncoded(f);
    var child = try spawn(f);
    if (f.request.data.post) |pd| {
        const stdin = child.stdin orelse return error.ServerFault;
        var w_b: [6400]u8 = undefined; // This is what I saw while debugging
        var stdin_w = stdin.writer(f.io, &w_b);
        if (gz_encoding) {
            var post_reader: Reader = .fixed(pd.bytes);
            var gz_b: [std.compress.flate.max_window_len]u8 = undefined;
            var gzip: std.compress.flate.Decompress = .init(&post_reader, .gzip, &gz_b);
            _ = gzip.reader.streamRemaining(&stdin_w.interface) catch |err| {
                log.err("gz stream error {}", .{err});
                return error.ServerFault;
            };
        } else {
            std.debug.print("{s}\n", .{pd.bytes[0..@min(2000, pd.bytes.len)]});
            try stdin_w.interface.writeAll(pd.bytes);
        }
        try stdin_w.interface.flush();
    }
    if (child.stdin) |stdin| stdin.close(f.io);
    child.stdin = null;

    const stdout = child.stdout orelse return error.ServerFault;
    var r_b: [6400]u8 = undefined; // This is what I saw while debugging
    var stdout_r = stdout.reader(f.io, &r_b);

    // we just guess and assume it'll return 200
    // checking would be better
    f.downstream.writer.writeAll("HTTP/1.1 200 OK\r\n") catch
        return debugStderr("unable to start headers", &child, f.io);

    _ = stdout_r.interface.streamRemaining(f.downstream.writer) catch
        return debugStderr("unable to stream body", &child, f.io);

    if (child.wait(f.io)) |chld| {
        log.info("child {}", .{chld});
        if (chld.exited != 0) {
            return debugStderr("unable to stream body", &child, f.io);
        }
    } else |err| {
        log.err("Error waiting for child {}", .{err});
        return error.ServerFault;
    }
    f.downstream.writer.flush() catch log.err("final flush failed", .{});
}

fn debugStderr(comptime msg: []const u8, child: *std.process.Child, io: std.Io) !void {
    log.err(msg, .{});
    if (child.stderr) |stderr| {
        var b: [2048]u8 = undefined;
        var stderr_r = stderr.reader(io, &b);
        while (stderr_r.interface.takeDelimiter('\n') catch null) |line| {
            log.err("stderr {s}", .{line});
        }
    }
    _ = child.wait(io) catch unreachable;
    return error.ServerFault;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const POLL = std.posix.POLL;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const log = std.log.scoped(.gitweb);
const allocPrint = std.fmt.allocPrint;
const RouteData = @import("endpoints/repos.zig").RouteData;

const main = @import("main.zig");

const verse = @import("verse");
const Frame = verse.Frame;
const Request = verse.Request;
const Router = verse.Router;
const Error = Router.Error;

const git = @import("git.zig");
