io: Io,
config: Config,
thread: ?std.Thread = null,
enabled: bool = false,

const Agent = @This();

pub const Config = struct {
    enabled: bool,
    sleep_for: usize = 60 * 60 * SECONDS,
    upstream: Direction = .both,
    downstream: Direction = .both,
    skips: ?[]const u8,

    pub const Direction = packed struct(u2) {
        push: bool,
        pull: bool,

        pub const none: Direction = .{ .push = false, .pull = false };
        pub const push_only: Direction = .{ .push = true, .pull = false };
        pub const pull_only: Direction = .{ .push = false, .pull = true };
        pub const both: Direction = .{ .push = true, .pull = true };
    };

    const SECONDS = 1000 * 1000 * 1000;
};

const Updated = struct {
    upstream_push: i64 = 0,
    upstream_pull: i64 = 0,
    downstream_push: i64 = 0,
    downstream_pull: i64 = 0,

    pub fn format(u: Updated, w: *Writer) !void {
        try w.print(
            \\upstream_push {}
            \\upstream_pull {}
            \\downstream_push {}
            \\downstream_pull {}
            \\
        , .{ u.upstream_push, u.upstream_pull, u.downstream_push, u.downstream_pull });
    }
};

pub fn init(cfg: Config, io: Io) Agent {
    return .{
        .io = io,
        .config = cfg,
    };
}

pub fn startThread(a: *Agent) !void {
    if (a.config.enabled) {
        a.enabled = true;
        a.thread = try std.Thread.spawn(.{}, updateThread, .{a});
    }
}

pub fn joinThread(a: *Agent) void {
    a.enabled = false;
    if (a.thread) |thr| {
        thr.join();
    }
    a.thread = null;
}

fn setUpdated(dir: Io.Dir, update: Updated, io: Io) void {
    const file = dir.createFile(io, "srctree_sync", .{}) catch return;
    defer file.close(io);
    var w_b: [1024]u8 = undefined;
    var writer = file.writer(io, &w_b);
    writer.interface.print("{f}", .{update}) catch return;
    writer.interface.flush() catch return;
}

fn getUpdated(dir: Io.Dir, io: Io) !Updated {
    var update: Updated = .{};
    var rbuf: [1024]u8 = undefined;
    const sync_str = dir.readFile(io, "srctree_sync", &rbuf) catch return .{};
    if (findPos(u8, sync_str, 0, "upstream_push ")) |i| {
        if (findPos(u8, sync_str, i, "\n")) |j| {
            update.upstream_push = parseInt(i64, sync_str[i + 14 .. j], 10) catch 0;
        }
    }
    if (findPos(u8, sync_str, 0, "upstream_pull ")) |i| {
        if (findPos(u8, sync_str, i, "\n")) |j| {
            update.upstream_pull = parseInt(i64, sync_str[i + 14 .. j], 10) catch 0;
        }
    }
    if (findPos(u8, sync_str, 0, "downstream_push ")) |i| {
        if (findPos(u8, sync_str, i, "\n")) |j| {
            update.downstream_push = parseInt(i64, sync_str[i + 16 .. j], 10) catch 0;
        }
    }
    if (findPos(u8, sync_str, 0, "downstream_pull ")) |i| {
        if (findPos(u8, sync_str, i, "\n")) |j| {
            update.downstream_pull = parseInt(i64, sync_str[i + 16 .. j], 10) catch 0;
        }
    }

    return update;
}

fn pullUpstream(name: []const u8, repo: *Git.Repo, a: Allocator, io: Io) !void {
    if (repo.findRemote("upstream")) |_| {
        var update = try getUpdated(repo.dir, io);
        const ref = repo.refs.get("HEAD") orelse return {};
        const head = switch (ref) {
            .ref => |r| r,
            else => return error.InvalidRepoHead,
        };

        var gitagent = repo.agent(a);
        if (gitagent.pullUpstream(head, io)) {
            log.debug("Update Successful on repo {s}", .{name});
        } else |err| switch (err) {
            error.NonAncestor => log.warn("{s} was skipped", .{name}),
            else => log.warn("Warning upstream pull failed repo {s} {}", .{ name, err }),
        }
        update.upstream_pull = Io.Clock.real.now(io).toSeconds();
        setUpdated(repo.dir, update, io);
    } else log.debug("repo {s} doesn't have an upstream peer", .{name});
}

fn pushDownstream(name: []const u8, repo: *Git.Repo, a: Allocator, io: Io) !void {
    var update = try getUpdated(repo.dir, io);
    //const repo_update = repo.updatedAt(a, io) catch 0;
    const repo_update = 0;

    if (repo_update > update.downstream_push) {
        if (repo.findRemote("downstream")) |_| {
            var gitagent = repo.agent(a);
            const updated = gitagent.pushDownstream(io) catch er: {
                log.warn("Warning, unable to push to downstream repo {s}", .{name});
                break :er false;
            };
            update.downstream_push = Io.Clock.real.now(io).toSeconds();
            setUpdated(repo.dir, update, io);
            if (!updated) log.warn("Warning downstream push failed repo {s}", .{name});
        } else log.debug("repo {s} doesn't have any downstream peers", .{name});
    } else {
        log.debug("Skipping for {s} no new branches {} {}", .{ name, repo_update, update.downstream_push });
    }
}

pub fn skipRepo(skips: []const u8, name: []const u8) bool {
    // if you actually use null, I hate you!
    var skippable = std.mem.tokenizeAny(u8, skips, "\x00|;, \t");
    while (skippable.next()) |skip| {
        if (eql(u8, skip, name))
            return true;
    } else return false;
}

pub fn updateThread(a: *Agent) void {
    const posix = std.posix;
    var sigset: posix.sigset_t = posix.sigemptyset();
    posix.sigaddset(&sigset, .INT);
    posix.sigprocmask(posix.SIG.BLOCK, &sigset, null);
    log.info("Spawning update thread", .{});
    // TODO past me is evil for doing this (replace with sane alloc source)
    const alloc = std.heap.page_allocator;
    var n_array = allNames(alloc, a.io) catch unreachable;
    // TODO drop skipped repos here
    const names = n_array.toOwnedSlice(alloc) catch @panic("OOM");
    defer alloc.free(names);
    defer for (names) |n| alloc.free(n);

    a.io.sleep(.fromSeconds(20), .real) catch return;
    running: while (a.enabled) {
        log.info("Starting sync for {} repos", .{names.len});
        for (names) |rname| {
            if (a.config.skips) |skips|
                if (skipRepo(skips, rname)) continue;

            log.debug("starting update for {s}", .{rname});
            var repo: Git.Repo = openGit(rname, .all, a.io) catch {
                log.warn("unable to load public repo {s}", .{rname});
                continue;
            } orelse {
                log.warn("unable to find repo {s}", .{rname});
                continue;
            };
            defer repo.raze(alloc, a.io);

            repo.loadData(alloc, a.io) catch {
                log.err("Warning, unable to load data for repo {s}", .{rname});
                continue;
            };

            if (a.config.upstream.pull) {
                pullUpstream(rname, &repo, alloc, a.io) catch |err| {
                    log.err("Error ({}) when trying to pull on {s}", .{ err, rname });
                    continue;
                };
            }
            if (a.config.downstream.push) {
                pushDownstream(rname, &repo, alloc, a.io) catch |err| {
                    log.err("Error ({}) when trying to push on {s}", .{ err, rname });
                    continue;
                };
            }
        }
        log.debug("update cycle complete", .{});
        var qi: usize = 60 * 60;
        while (qi > 0) {
            qi -|= 1;
            a.io.sleep(.fromSeconds(@intCast(a.config.sleep_for / 60 / 60)), .real) catch
                return;
            if (!a.enabled) break :running;
        }
    }
    log.info("Update thread complete!", .{});
}

const std = @import("std");
const log = std.log.scoped(.update_thread);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Io = std.Io;
const eql = std.mem.eql;
const findPos = std.mem.findPos;
const parseInt = std.fmt.parseInt;

const Repo = @import("../Repo.zig");
const allNames = Repo.allNames;
const openGit = Repo.openGit;

const Git = @import("../git.zig");
