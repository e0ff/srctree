const root = @This();

pub const verse_name = .root;
pub const verse_routes = [_]Match{
    verse.robotsTxt(&.{
        .{ .name = "GoogleOther", .allow = false }, // aggressive genai bot
        .{ .name = "SiteAuditBot", .allow = false }, // selfish bot
        .{ .name = "DataForSeoBot", .allow = false }, // selfish bot
        .{ .name = "BacklinksExtendedBot", .allow = false }, // selfish bot
        .{ .name = "barkrowler", .allow = false }, // selfish bot
    }, .{ .extra_rules = "Disallow: /*?*\n" }),
    GET("debug", debug),
    ROUTE("user", commitFlex),
    STATIC("static"),
};
pub const verse_builder = &builder;
pub const index = commitFlex;

pub const endpoints = verse.Endpoints(.{
    root,
    @import("api.zig"),
    @import("endpoints/admin.zig"),
    @import("endpoints/gist.zig"),
    @import("endpoints/network.zig"),
    @import("endpoints/repos.zig"),
    @import("endpoints/search.zig"),
    @import("endpoints/settings.zig"),
});

const E404Page = template.PageData("4XX.html");

fn notFound(vrs: *Frame) Router.Error!void {
    std.debug.print("404 for route\n", .{});
    vrs.status = .not_found;
    var page = E404Page.init(.{});
    vrs.sendPage(&page) catch unreachable;
}

fn debug(_: *Frame) Router.Error!void {
    return error.Abusive;
}

fn builder(fr: *Frame, call: BuildFn) void {
    if (fr.request.user_agent) |ua| {
        if (ua.resolved != .bot or ua.resolved.bot.name != .googlebot) {
            fr.dumpDebugData();
            ua.botDetectionDump(fr.request);
        }
    } else {
        std.debug.print("No User agent for request\n\n\n\n", .{});
        fr.dumpDebugData();
    }

    const btns = [1]S.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};
    var bh: S.BodyHeaderHtml = fr.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{
        .nav_auth = "Error",
        .nav_buttons = &btns,
    } };

    bh.nav.nav_auth = if (fr.user) |usr| n: {
        break :n if (usr.username) |un| un else "Error No Username";
    } else "Public";
    fr.response_data.add(bh) catch {};
    return call(fr) catch |err| switch (err) {
        error.InvalidURI => builder(fr, notFound), // TODO catch inline
        error.BrokenPipe => std.debug.print("client disconnect", .{}),
        error.IOWriteFailure => @panic("Unexpected IOWrite"),
        error.Unrouteable => {
            std.debug.print("Unrouteable", .{});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        },
        error.NotImplemented,
        error.Unknown,
        error.OutOfMemory,
        error.NoSpaceLeft,
        => {
            std.debug.print("Unexpected error '{}'", .{err});
            @panic("not implemented");
        },
        error.Abusive,
        error.Unauthenticated,
        error.BadData,
        error.DataMissing,
        => {
            std.debug.print("Abusive {} because {}\n", .{ fr.request, err });
            fr.dumpDebugData();
            if (fr.request.data.post) |post_data| {
                std.debug.print("post data => '''{s}'''\n", .{post_data.rawpost});
            }
        },
    };
}

const std = @import("std");
const eql = std.mem.eql;
const verse = @import("verse");
const Frame = verse.Frame;

const Router = verse.Router;
const template = verse.template;
const S = template.Structs;

const ROUTE = Router.ROUTE;
const GET = Router.GET;
const STATIC = Router.STATIC;
const Match = Router.Match;
const BuildFn = Router.BuildFn;

const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;
