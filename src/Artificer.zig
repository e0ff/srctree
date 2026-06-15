var environ: std.process.Environ.Map = undefined;

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    environ = try init.minimal.environ.createMap(a);

    const io = init.io;
    var args = init.minimal.args.iterate();
    const arg0 = args.next() orelse @panic("impressive, how'd you reach this?");
    _ = arg0;

    var stdout_f: std.Io.File = .stdout();
    var sout_b: [512]u8 = undefined;
    var out_reader = stdout_f.writer(init.io, &sout_b);
    const stdout = &out_reader.interface;

    _ = stdout;

    const env: Env = try .init(&init.minimal.environ, a);

    if (env.datadir) |datadir| try types.init(
        try std.Io.Dir.cwd().createDirPathOpen(io, datadir, .{ .open_options = .{ .iterate = true } }),
        io,
    );

    return 0;
}

const PushMethod = enum {
    unknown,
    http,
    git,
    ssh,
    file,
};

const Env = struct {
    map: std.process.Environ.Map,
    push_options: StringArrayHashMap(void),
    method: PushMethod,
    host: ?[]const u8,
    repo: ?[]const u8,
    datadir: ?[]const u8,

    user: ?[]const u8 = null,
    authenticated: bool = false,

    pub fn init(env: *const std.process.Environ, a: Allocator) !Env {
        var map = try env.createMap(a);
        var method: PushMethod = .unknown;
        const host: ?[]const u8 = map.get("SRCTREE_HOST");
        const repo: ?[]const u8 = map.get("SRCTREE_REPO");
        const user: ?[]const u8 = map.get("SRCTREE_USER");
        var datadir: ?[]const u8 = map.get("SRCTREE_DIRECT_DATADIR");

        if (map.contains("SRCTREE_HTTP")) {
            method = .http;
        } else if (map.contains("SSH_CLIENT")) {
            method = .ssh;
        }

        if (map.contains("SRCTREE_DIRECT_ENABLED")) {
            if (!eql(u8, map.get("SRCTREE_DIRECT_ENABLED").?, "true"))
                datadir = null;
        } else {
            datadir = null;
        }

        var list: StringArrayHashMap(void) = .empty;
        if (map.contains("GIT_PUSH_OPTION_COUNT")) {
            const count = parseInt(usize, map.get("GIT_PUSH_OPTION_COUNT").?, 0) catch return error.BadEnvCount;
            if (count > 0) {
                var b: [64]u8 = undefined;
                for (0..count) |i| {
                    const opt_str = try print(&b, "GIT_PUSH_OPTION_{}", .{i});
                    const opt = map.get(opt_str) orelse return error.ExpectedEnvMissing;
                    try list.put(a, opt, {});
                }
            }
        }

        return .{
            .map = map,
            .push_options = list,
            .method = method,
            .repo = repo,
            .host = host,
            .datadir = datadir,
            .user = user,
            // TODO better authentication
            .authenticated = user != null and !startsWith(u8, user.?, "anon"),
        };
    }

    pub fn raze(env: Env, a: Allocator) void {
        env.map.deinit(a);
        env.push_options.deinit(a);
    }

    pub fn format(env: Env, w: *std.Io.Writer) !void {
        try w.print("Env:\n", .{});
        try w.print("Host: '{s}' Repo: '{s}' User: '{s}'\n", .{
            env.host orelse "null",
            env.repo orelse "null",
            env.user orelse "null",
        });
        for (env.push_options.keys()) |e| {
            try w.print("    push-option: '{s}'\n", .{e});
        }
        for (env.map.keys(), env.map.values()) |k, v| {
            try w.print("    map: k:'{s}' v:'{s}'\n", .{ k, v });
        }
    }
};

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;
const Reader = Io.Reader;
const Writer = Io.Writer;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;
const startsWith = std.mem.startsWith;
const parseInt = std.fmt.parseInt;
const types = @import("types.zig");
const CI = types.CI;
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const print = std.fmt.bufPrint;
const log = std.log;
const system = std.os.linux;
