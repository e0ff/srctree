const repos = @This();

const DEBUG = false;

const Visibility = @import("Repo.zig").Visibility;
const Vis = Visibility;

pub var dirs: Dirs = .{};

pub const Dirs = struct {
    public: ?[]const u8 = "./repos",
    private: ?[]const u8 = null,
    secret: ?[]const u8 = null,

    pub fn directory(rds: Dirs, vis: Visibility, io: Io) !std.Io.Dir {
        var cwd = std.Io.Dir.cwd();
        return cwd.openDir(io, switch (vis) {
            .public => rds.public orelse return error.NoDirectory,
            .private => rds.private orelse return error.NoDirectory,
            .secret => rds.secret orelse return error.NoDirectory,
            .unlisted => rds.secret orelse return error.NoDirectory,
        }, .{ .iterate = true });
    }
};

pub fn exists(name: []const u8, vis: Visibility.Select, io: Io) bool {
    // TODO skips non-public dirs
    var dir = dirs.directory(.public, io) catch return false;
    defer dir.close(io);
    var itr = dir.iterate();
    while (itr.next(io) catch return false) |file| {
        if (file.kind != .directory and file.kind != .sym_link) continue;
        if (eql(u8, file.name, name)) {
            // lol, crap, there's a side channel leak no matter where I put
            // this... given near zero thought I've decided this is the better
            // option
            if (!Vis.fromConfig(name).isVisible(vis)) return false;
            return true;
        }
    }
    return false;
}

pub fn containsName(name: []const u8) bool {
    return if (name.len > 0) true else false;
}

const Repo = @import("Repo.zig");
pub const Agent = Repo.Agent;
pub const open = Repo.openGit;

const std = @import("std");
const log = std.log.scoped(.update_thread);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Io = std.Io;
const eql = std.mem.eql;
const findPos = std.mem.findPos;
const parseInt = std.fmt.parseInt;

const Git = @import("git.zig");
const global_config = &@import("Config.zig").global;
