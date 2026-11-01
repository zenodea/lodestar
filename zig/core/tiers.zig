//! Lodestar's own routing profiles, for a harness the routing configuration has none for: four tiers with the task
//! descriptions written, each on the newest model of a family. Claude Code takes the family's alias, which always
//! means its newest model; the GPT harnesses (Codex, fx, pi) get the highest version of the family they list.

const std = @import("std");
const rt = @import("../rt.zig");
const json = @import("json.zig");

pub const Tier = struct { name: []const u8, claude: []const u8, gpt: []const u8, thinking: []const u8, description: []const u8 };

pub const TIERS = [_]Tier{
    .{ .name = "quick", .claude = "haiku", .gpt = "luna", .thinking = "low", .description = "Small, well-specified changes: a rename, a docs or comment edit, a config value, a simple test, a mechanical edit that follows an exact pattern." },
    .{ .name = "standard", .claude = "sonnet", .gpt = "terra", .thinking = "medium", .description = "Ordinary features and bug fixes with a clear scope, in code the task names, where the approach is plain." },
    .{ .name = "deep", .claude = "opus", .gpt = "sol", .thinking = "high", .description = "Debugging an unclear failure, changes across several modules, concurrency, performance, or a task that leaves the approach open." },
    .{ .name = "ultra", .claude = "fable", .gpt = "astra", .thinking = "xhigh", .description = "The hardest work: architecture and large redesigns, subtle correctness or security problems, research-level algorithms, or a task others have failed at." },
};

/// When the router is unsure or unreachable, the work goes here.
pub const FALLBACK = "deep";

/// `a` is a newer version than `b`: "6.1" > "6" > "5.6".
fn newer(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return false;
        const nx = std.fmt.parseInt(u32, x orelse "0", 10) catch 0;
        const ny = std.fmt.parseInt(u32, y orelse "0", 10) catch 0;
        if (nx != ny) return nx > ny;
    }
}

/// The newest `gpt-<version>-<family>` in `models` (ids, optionally `provider/` first; pi's OpenAI ones preferred).
pub fn newestGpt(models: []const []const u8, family: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_version: []const u8 = "";
    var best_openai = false;
    for (models) |m| {
        const slash = std.mem.lastIndexOfScalar(u8, m, '/');
        const id = if (slash) |i| m[i + 1 ..] else m;
        const openai = slash == null or rt.startsWith(m, "openai/");
        if (!rt.startsWith(id, "gpt-")) continue;
        const rest = id["gpt-".len..];
        const dash = std.mem.indexOfScalar(u8, rest, '-') orelse continue;
        if (!rt.eql(rest[dash + 1 ..], family)) continue;
        const version = rest[0..dash];
        if (best == null or newer(version, best_version) or (rt.eql(version, best_version) and openai and !best_openai)) {
            best = m;
            best_version = version;
            best_openai = openai;
        }
    }
    return best;
}

/// The tiers as routing profiles for `kind`, `{ fallback, profiles }`; `models` is the harness's model list (unused for
/// Claude Code). Tiers with no model on this harness are left out; null when none is left.
pub fn profilesFor(kind: []const u8, models: []const []const u8) ?*json.Obj {
    const profiles = json.newObj();
    for (TIERS) |t| {
        const model = if (rt.eql(kind, "claude")) t.claude else newestGpt(models, t.gpt) orelse continue;
        profiles.put(t.name, json.object(.{ .{ "model", model }, .{ "thinking", t.thinking }, .{ "description", t.description } }).val());
    }
    if (profiles.count() == 0) return null;
    const fallback = if (profiles.has(FALLBACK)) FALLBACK else profiles.keys()[profiles.count() - 1];
    return json.object(.{ .{ "fallback", fallback }, .{ "profiles", profiles } });
}

test "tiers take the newest model of each family" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    const fx = [_][]const u8{ "gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna" };
    try std.testing.expectEqualStrings("gpt-6.1-sol", newestGpt(&fx, "sol").?);
    try std.testing.expectEqualStrings("gpt-6-luna", newestGpt(&fx, "luna").?);
    try std.testing.expectEqualStrings("gpt-6.1-terra", newestGpt(&fx, "terra").?);
    try std.testing.expect(newestGpt(&fx, "nova") == null);
    const pi = [_][]const u8{ "azure/gpt-6.1-sol", "openai/gpt-6.1-sol", "openai/gpt-6-sol" };
    try std.testing.expectEqualStrings("openai/gpt-6.1-sol", newestGpt(&pi, "sol").?);
    const p = profilesFor("fx", &fx).?;
    try std.testing.expectEqualStrings("deep", p.str("fallback").?);
    try std.testing.expectEqualStrings("gpt-6-astra", p.obj("profiles").?.obj("ultra").?.str("model").?);
    try std.testing.expectEqualStrings("xhigh", p.obj("profiles").?.obj("ultra").?.str("thinking").?);
    try std.testing.expectEqualStrings("fable", profilesFor("claude", &.{}).?.obj("profiles").?.obj("ultra").?.str("model").?);
    try std.testing.expect(profilesFor("codex", &.{}) == null);
}
