//! Codex's plan limits from the server behind its `/status`, signed in the way Codex is: the ChatGPT login in
//! `<codex home>/auth.json`. Codex's session logs carry the limits too, but only while Codex runs on this machine, so
//! use from elsewhere (the Codex app, the web, another computer) shows here only through the server. The endpoint is
//! undocumented, so any failure leaves the limits as they were.

const std = @import("std");
const rt = @import("../rt.zig");
const json = @import("../core/json.zig");
const fs = @import("../core/fs.zig");
const proc = @import("../core/proc.zig");
const files = @import("files.zig");
const record = @import("record.zig");

const URL = "https://chatgpt.com/backend-api/wham/usage";
/// The server is asked at most this often, whether or not it answered.
const EVERY_MS: i64 = 5 * 60_000;
var last_try: i64 = 0;

pub const Limits = struct { plan: ?[]const u8 = null, windows: []const record.Window = &.{} };

fn authFile() []const u8 {
    return if (rt.getenvNonEmpty("CODEX_HOME")) |d| fs.join(&.{ d, "auth.json" }) else files.home(".codex/auth.json");
}

fn window(o: ?*json.Obj, now: i64) ?record.Window {
    const w = o orelse return null;
    const minutes = if (w.int("limit_window_seconds")) |s| @divTrunc(s, 60) else w.int("window_minutes") orelse return null;
    const pct = w.num("used_percent") orelse return null;
    const resets: ?i64 = if (w.int("reset_at") orelse w.int("resets_at")) |s| s * 1000 else if (w.int("reset_after_seconds")) |s| now + s * 1000 else null;
    return .{ .minutes = minutes, .used_pct = pct, .resets_at_ms = resets };
}

/// `{ plan_type, rate_limit: { primary_window: { used_percent, limit_window_seconds, reset_at, reset_after_seconds }, secondary_window } }`
pub fn parse(body: []const u8, now: i64) Limits {
    const o = (json.parse(body) catch return .{}).asObj() orelse return .{};
    const rl = o.obj("rate_limit") orelse return .{};
    var ws: std.ArrayListUnmanaged(record.Window) = .empty;
    for ([_][]const u8{ "primary_window", "secondary_window" }) |k| if (window(rl.obj(k), now)) |w| ws.append(rt.a, w) catch {};
    return .{ .plan = o.str("plan_type"), .windows = ws.items };
}

/// Asks the server when the limits on file are older than `EVERY_MS`; the token goes to curl on stdin, not argv.
pub fn fetch(now: i64, limits_file: []const u8) Limits {
    if (now - last_try < EVERY_MS) return .{};
    if (fs.readFileOpt(limits_file)) |text| if (json.parse(text) catch null) |v| if (v.asObj()) |o| {
        if (now - (o.int("at") orelse 0) < EVERY_MS) return .{};
    };
    last_try = now;
    const auth = (json.parse(fs.readFileOpt(authFile()) orelse return .{}) catch return .{}).asObj() orelse return .{};
    const tokens = auth.obj("tokens") orelse return .{};
    const token = tokens.strNonEmpty("access_token") orelse return .{};
    const account = tokens.strNonEmpty("account_id") orelse "";
    const headers = rt.concat(&.{ "Authorization: Bearer ", token, "\nChatGPT-Account-Id: ", account, "\nUser-Agent: lodestar\n" });
    const r = proc.run(&.{ "curl", "-sS", "--fail", "-m", "10", "-H", "@-", URL }, .{ .input = headers, .timeout_ms = 15_000, .stdout_limit = 1 << 20 });
    return if (r.ok()) parse(r.stdout, now) else .{};
}

test "parse reads the primary and secondary windows and the plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    const l = parse(
        \\{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":600,"reset_at":1793500000},"secondary_window":{"used_percent":76,"limit_window_seconds":604800,"reset_after_seconds":90000}}}
    , 1_000_000);
    try std.testing.expectEqualStrings("pro", l.plan.?);
    try std.testing.expectEqual(@as(usize, 2), l.windows.len);
    try std.testing.expectEqual(@as(i64, 300), l.windows[0].minutes);
    try std.testing.expectEqual(@as(i64, 1793500000 * 1000), l.windows[0].resets_at_ms.?);
    try std.testing.expectEqual(@as(i64, 10080), l.windows[1].minutes);
    try std.testing.expectEqual(@as(f64, 76), l.windows[1].used_pct);
    try std.testing.expectEqual(@as(i64, 1_000_000 + 90_000_000), l.windows[1].resets_at_ms.?);
    try std.testing.expectEqual(@as(usize, 0), parse("{\"detail\":\"Unauthorized\"}", 0).windows.len);
}
