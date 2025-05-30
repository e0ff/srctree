const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
const AnyReader = std.io.AnyReader;

const Types = @import("../types.zig");
const Thread = Types.Thread;
const Message = Thread.Message;

pub const Delta = @This();

const DELTA_VERSION: usize = 1;
pub const TYPE_PREFIX = "deltas";
var datad: Types.Storage = undefined;

pub fn initType(stor: Types.Storage) !void {
    datad = stor;
}

/// while Zig specifies that the logical order of fields is little endian, I'm
/// not sure that's the layout I want to go use. So don't depend on that yet.
pub const State = packed struct {
    closed: bool = false,
    locked: bool = false,
    embargoed: bool = false,
    padding: u61 = 0,
};

test State {
    try std.testing.expectEqual(@sizeOf(State), @sizeOf(usize));

    const state = State{};
    const zero: usize = 0;
    const ptr: *const usize = @ptrCast(&state);
    try std.testing.expectEqual(zero, ptr.*);
}

fn readVersioned(a: Allocator, idx: usize, reader: *AnyReader) !Delta {
    const ver: usize = try reader.readInt(usize, endian);
    return switch (ver) {
        0 => Delta{
            .index = idx,
            .state = try reader.readStruct(State),
            .created = try reader.readInt(i64, endian),
            .updated = try reader.readInt(i64, endian),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .title = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .message = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            //.author = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .author = null,
            .thread_id = try reader.readInt(usize, endian),
            .attach = switch (Attach.fromInt(try reader.readInt(u8, endian))) {
                .nos => .{ .nos = try reader.readInt(usize, endian) },
                .diff => .{ .diff = try reader.readInt(usize, endian) },
                .issue => .{ .issue = try reader.readInt(usize, endian) },
                .commit => .{ .issue = try reader.readInt(usize, endian) },
                .line => .{ .issue = try reader.readInt(usize, endian) },
            },
            .tags_id = try reader.readInt(usize, endian),
        },
        1 => Delta{
            .index = idx,
            .state = try reader.readStruct(State),
            .created = try reader.readInt(i64, endian),
            .updated = try reader.readInt(i64, endian),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .title = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .message = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .author = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .thread_id = try reader.readInt(usize, endian),
            .attach = switch (Attach.fromInt(try reader.readInt(u8, endian))) {
                .nos => .{ .nos = try reader.readInt(usize, endian) },
                .diff => .{ .diff = try reader.readInt(usize, endian) },
                .issue => .{ .issue = try reader.readInt(usize, endian) },
                .commit => .{ .issue = try reader.readInt(usize, endian) },
                .line => .{ .issue = try reader.readInt(usize, endian) },
            },
            .tags_id = try reader.readInt(usize, endian),
        },
        else => return error.UnsupportedVersion,
    };
}

pub const Attach = enum(u8) {
    nos = 0,
    diff = 1,
    issue = 2,
    commit = 3,
    line = 4,

    pub fn fromInt(int: u8) Attach {
        return switch (int) {
            1 => .diff,
            2 => .issue,
            3 => .commit,
            4 => .line,
            else => .nos,
        };
    }
};

index: usize,
state: State = .{},
created: i64 = 0,
updated: i64 = 0,
repo: []const u8,
title: []const u8,
message: []const u8,
author: ?[]const u8 = null,
thread_id: usize = 0,
tags_id: usize = 0,

attach: union(Attach) {
    nos: usize,
    diff: usize,
    issue: usize,
    commit: usize,
    line: usize,
} = .{ .nos = 0 },
hash: [32]u8 = [_]u8{0} ** 32,
thread: ?*Thread = null,

pub fn commit(self: Delta) !void {
    if (self.thread) |thr| thr.commit() catch {}; // Save thread as best effort

    const file = try openFile(self.repo);
    defer file.close();
    var writer = file.writer().any();
    return self.writeOut(&writer);
}

fn writeOut(self: Delta, writer: *std.io.AnyWriter) !void {
    try writer.writeInt(usize, DELTA_VERSION, endian);
    try writer.writeStruct(self.state);
    try writer.writeInt(i64, self.created, endian);
    try writer.writeInt(i64, self.updated, endian);
    try writer.writeAll(self.repo);
    try writer.writeAll("\x00");
    try writer.writeAll(self.title);
    try writer.writeAll("\x00");
    try writer.writeAll(self.message);
    try writer.writeAll("\x00");
    try writer.writeAll(self.author orelse "Unknown");
    try writer.writeAll("\x00");
    try writer.writeInt(usize, self.thread_id, endian);

    try writer.writeInt(u8, @intFromEnum(self.attach), endian);
    switch (self.attach) {
        .nos => |att| try writer.writeInt(usize, att, endian),
        .diff => |att| try writer.writeInt(usize, att, endian),
        .issue => |att| try writer.writeInt(usize, att, endian),
        .commit => |att| try writer.writeInt(usize, att, endian),
        .line => |att| try writer.writeInt(usize, att, endian),
    }
    try writer.writeInt(usize, self.tags_id, endian);
    // FIXME write 32 not a maybe
    if (self.thread) |thread| {
        try writer.writeAll(&thread.hash);
    }
    //try writer.writeAll("\x00");
}

pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Delta {
    var reader = file.reader().any();
    const delta: Delta = try readVersioned(a, idx, &reader);
    return delta;
}

pub fn loadThread(self: *Delta, a: Allocator) !*Thread {
    if (self.thread != null) return error.MemoryAlreadyLoaded;
    const t = try a.create(Thread);
    t.* = Thread.open(a, self.thread_id) catch |err| t: {
        std.debug.print("Error loading thread!! {}", .{err});
        std.debug.print(" old thread_id {};", .{self.thread_id});
        const thread = Thread.new(self.*) catch |err2| {
            std.debug.print(" unable to create new {}\n", .{err2});
            return error.UnableToLoadThread;
        };
        std.debug.print("new thread_id {}\n", .{thread.index});
        self.thread_id = thread.index;
        try self.commit();
        break :t thread;
    };

    self.thread = t;
    return t;
}

pub fn getMessages(self: *Delta, a: Allocator) ![]Message {
    if (self.thread) |thread| {
        if (thread.getMessages()) |msgs| {
            return msgs;
        } else |_| {
            try thread.loadMessages(a);
            return try thread.getMessages();
        }
    }
    return error.ThreadNotLoaded;
}

//pub fn addComment(self: *Delta, a: Allocator, c: Comment) !void {
//    if (self.thread) |thread| {
//        return thread.addComment(a, c);
//    }
//    return error.ThreadNotLoaded;
//}

pub fn countComments(self: Delta) struct { count: usize, new: bool } {
    if (self.thread) |thread| {
        if (thread.getMessages()) |msgs| {
            const ts = std.time.timestamp() - 86400;
            var cmtnew: bool = false;
            var cmtlen: usize = 0;
            for (msgs) |m| switch (m.kind) {
                .comment => {
                    cmtnew = cmtnew or m.updated > ts;
                    cmtlen += 1;
                },
                else => {},
            };
            return .{ .count = cmtlen, .new = cmtnew };
        } else |_| {}
    }
    return .{ .count = 0, .new = false };
}

pub fn raze(_: Delta, _: std.mem.Allocator) void {
    // TODO implement raze
}

fn currMaxSet(repo: []const u8, count: usize) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_{s}_count", .{repo});
    var cnt_file = try datad.createFile(filename, .{ .truncate = false });
    defer cnt_file.close();
    var writer = cnt_file.writer();
    _ = try writer.writeInt(usize, count, endian);
}

fn currMax(repo: []const u8) !usize {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_{s}_count", .{repo});
    var cnt_file = try datad.openFile(filename, .{ .mode = .read_write });
    defer cnt_file.close();
    var reader = cnt_file.reader();
    const count: usize = try reader.readInt(usize, endian);
    return count;
}

pub const Iterator = struct {
    alloc: Allocator,
    index: usize = 0,
    last: usize = 0,
    repo: []const u8,

    pub fn next(self: *Iterator) ?Delta {
        var buf: [2048]u8 = undefined;
        while (self.index <= self.last) {
            defer self.index +|= 1;
            const filename = std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ self.repo, self.index }) catch unreachable;
            const file = datad.openFile(filename, .{ .mode = .read_only }) catch continue;
            defer file.close();
            return Delta.readFile(self.alloc, self.index, file) catch continue;
        }
        return null;
    }
};

pub fn iterator(a: Allocator, repo: []const u8) Iterator {
    return .{
        .alloc = a,
        .repo = repo,
        .last = last(repo),
    };
}

pub fn last(repo: []const u8) usize {
    return currMax(repo) catch 0;
}

fn openFile(repo: []const u8) !std.fs.File {
    const max: usize = currMax(repo) catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ repo, max + 1 });
    return try datad.openFile(filename, .{ .mode = .read_write });
}

pub fn new(repo: []const u8, title: []const u8, msg: []const u8, author: []const u8) !Delta {
    // TODO this is probably a bug
    const max: usize = currMax(repo) catch 0;

    var d = Delta{
        .index = max + 1,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .repo = repo,
        .title = title,
        .message = msg,
        .author = author,
    };

    var thread = try Thread.new(d);
    try currMaxSet(repo, max + 1);
    try thread.commit();
    d.thread_id = thread.index;

    return d;
}

pub fn open(a: std.mem.Allocator, repo: []const u8, index: usize) !?Delta {
    const max = currMax(repo) catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ repo, index }) catch return error.InvalidTarget;
    const file = datad.openFile(filename, .{ .mode = .read_write }) catch return error.Other;
    return try Delta.readFile(a, index, file);
}

/// By assumption, a subject of len 0 will search across anything
pub const SearchRule = struct {
    subject: []const u8,
    match: []const u8,
    inverse: bool = false,
    around: bool = false,
};

pub fn SearchList(T: type) type {
    return struct {
        rules: []const SearchRule,

        // TODO better ABI
        iterable: std.fs.Dir.Iterator,

        const Self = @This();

        pub fn next(self: *Self, a: Allocator) anyerror!?T {
            const line = (try self.iterable.next()) orelse return null;
            if (line.kind == .file and std.mem.endsWith(u8, line.name, ".delta")) {
                if (std.mem.lastIndexOf(u8, line.name[0 .. line.name.len - 6], ".")) |i| {
                    const num = std.fmt.parseInt(
                        usize,
                        line.name[i + 1 .. line.name.len - 6],
                        16,
                    ) catch return self.next(a);
                    const file = try datad.openFile(line.name, .{});
                    const current: T = Delta.readFile(a, num, file) catch {
                        file.close();
                        return self.next(a);
                    };

                    if (!self.evalRules(current)) {
                        file.close();
                        return self.next(a);
                    }

                    return current;
                } else {}
            }
            return self.next(a);
        }

        fn evalRules(self: Self, target: T) bool {
            for (self.rules) |rule| {
                if (!self.eval(rule, target)) return false;
            } else return true;
        }

        /// TODO: I think this function might overrun for some inputs
        /// TODO: add support for int types
        fn eval(_: Self, rule: SearchRule, target: T) bool {
            if (comptime std.meta.hasMethod(T, "searchEval")) {
                return target.searchEval(rule);
            }

            const any = rule.subject.len == 0;

            inline for (comptime std.meta.fieldNames(T)) |name| {
                if (any or std.mem.eql(u8, rule.subject, name)) {
                    if (@TypeOf(@field(target, name)) == []const u8) {
                        const found = if (rule.around or any)
                            std.mem.count(u8, @field(target, name), rule.match) > 0
                        else
                            std.mem.eql(u8, @field(target, name), rule.match);
                        if (found) {
                            return true;
                        } else if (!any) {
                            return false;
                        }
                    }
                }
            }
            return true and !any;
        }

        pub fn raze(_: Self) void {}
    };
}

pub fn searchRepo(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const SearchRule,
) SearchList(Delta) {
    unreachable;
}

pub fn search(_: std.mem.Allocator, rules: []const SearchRule) SearchList(Delta) {
    return .{
        .rules = rules,
        .iterable = datad.iterate(),
    };
}

test Delta {
    const a = std.testing.allocator;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true }));

    var d = try Delta.new("repo_name", "title", "message", "author");

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0xffffff);
    d.created = std.time.timestamp() & mask;
    d.updated = std.time.timestamp() & mask;

    var out = std.ArrayList(u8).init(a);
    defer out.clearAndFree();
    var outw = out.writer().any();
    try d.writeOut(&outw);

    const v0: Delta = undefined;
    const v0_bin: []const u8 = undefined;
    const v1: Delta = undefined;
    // TODO... eventually
    _ = v0;
    _ = v0_bin;
    _ = v1;

    const v1_bin: []const u8 = &[_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00,
        0x72, 0x65, 0x70, 0x6F, 0x5F, 0x6E, 0x61, 0x6D, 0x65, 0x00, 0x74, 0x69, 0x74, 0x6C, 0x65, 0x00,
        0x6D, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x00, 0x61, 0x75, 0x74, 0x68, 0x6F, 0x72, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqualSlices(u8, out.items, v1_bin);
}
