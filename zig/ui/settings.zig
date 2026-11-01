const std = @import("std");
const rt = @import("../rt.zig");
const json = @import("../core/json.zig");
const fs = @import("../core/fs.zig");
const paths = @import("../core/paths.zig");
const proc = @import("../core/proc.zig");
const config = @import("../core/config.zig");
const crewmates = @import("../agents/crewmates.zig");
const mux = @import("../mux/index.zig");
const ansi = @import("ansi.zig");
const term = @import("term.zig");
const picker = @import("picker.zig");
const theme = @import("theme.zig");
const routing = @import("../core/routing.zig");
const api_keys = @import("../core/keys.zig");

const Obj = json.Obj;
const Config = *Obj;
const PickItem = picker.PickItem;
const PickOptions = picker.PickOptions;

pub const KINDS = [_]PickItem{
    .{ .value = "claude", .description = "Claude Code" },
    .{ .value = "codex", .description = "OpenAI Codex" },
    .{ .value = "pi", .description = "pi coding agent" },
    .{ .value = "fx", .description = "Vercel fx" },
};

pub fn thinkingFor(kind: []const u8) ?[]const []const u8 {
    if (rt.eql(kind, "claude")) return &.{ "low", "medium", "high", "xhigh", "max" };
    if (rt.eql(kind, "codex")) return &.{ "minimal", "low", "medium", "high", "xhigh" };
    if (rt.eql(kind, "pi")) return &.{ "off", "minimal", "low", "medium", "high", "xhigh", "max" };
    if (rt.eql(kind, "fx")) return &.{ "auto", "minimal", "low", "medium", "high", "xhigh" };
    return null;
}

pub const Model = struct { provider: []const u8, id: []const u8 };

pub fn piModels() []const Model {
    const res = proc.run(&.{ "pi", "--list-models" }, .{});
    if (!res.ok()) return &.{};
    var out: std.ArrayListUnmanaged(Model) = .empty;
    const lines = ansi.splitLines(res.stdout);
    for (lines[@min(1, lines.len)..]) |l| {
        var cols: std.ArrayListUnmanaged([]const u8) = .empty;
        const t = rt.trim(l);
        var it = std.mem.tokenizeAny(u8, t, " \t\r\x0b\x0c");
        while (it.next()) |c| cols.append(rt.a, c) catch {};
        if (cols.items.len == 0 and t.len == 0) cols.append(rt.a, "") catch {};
        if (cols.items.len >= 2 and !rt.eql(cols.items[0], "provider")) out.append(rt.a, .{ .provider = cols.items[0], .id = cols.items[1] }) catch {};
    }
    return out.items;
}

/// `fx models` lists ` - <id> · <provider>` under a `[models]` header.
pub fn fxModels() []const PickItem {
    const res = proc.run(&.{ "fx", "models" }, .{});
    if (!res.ok()) return &.{};
    var out: std.ArrayListUnmanaged(PickItem) = .empty;
    for (ansi.splitLines(res.stdout)) |l| {
        const t = rt.trim(l);
        if (!rt.startsWith(t, "- ")) continue;
        const rest = t[2..];
        const sep = std.mem.indexOf(u8, rest, " · ");
        const id = rt.trim(if (sep) |i| rest[0..i] else rest);
        if (id.len > 0) out.append(rt.a, .{ .value = id, .description = if (sep) |i| rt.trim(rest[i + " · ".len ..]) else null }) catch {};
    }
    return out.items;
}

const MODELS_KEPT_MS: i64 = 24 * 3_600_000;
/// Set while the page lists a row's choices beside it: a list nobody has kept yet is left out rather than awaited.
var kept_models_only = false;

fn modelsFile(kind: []const u8) []const u8 {
    return fs.join(&.{ paths.state_dir, "models", rt.concat(&.{ kind, ".json" }) });
}

/// `pi --list-models` takes about two seconds and `fx models` half of one, so a harness's list is kept for a day.
pub fn modelsFor(kind: []const u8) []const PickItem {
    if (rt.eql(kind, "claude")) return listModels(kind);
    const file = modelsFile(kind);
    if (keptModels(file)) |kept| return kept;
    if (kept_models_only) return &.{};
    const fresh = listModels(kind);
    if (fresh.len == 0) return fresh;
    const arr = json.newArr();
    for (fresh) |m| arr.push(json.object(.{ .{ "value", m.value }, .{ "description", m.description } }).val());
    _ = paths.ensureDir(fs.join(&.{ paths.state_dir, "models" }));
    fs.writeAtomic(file, json.stringify(arr.val(), false), 0o600) catch {};
    return fresh;
}

fn keptModels(file: []const u8) ?[]const PickItem {
    const st = fs.stat(file) catch return null;
    if (rt.nowMs() - st.mtime_ms >= MODELS_KEPT_MS) return null;
    const v = json.parse(fs.readFileOpt(file) orelse return null) catch return null;
    var out: std.ArrayListUnmanaged(PickItem) = .empty;
    for ((v.asArr() orelse return null).objs()) |o| out.append(rt.a, .{ .value = o.str("value") orelse continue, .description = o.str("description") }) catch {};
    return if (out.items.len > 0) out.items else null;
}

fn listModels(kind: []const u8) []const PickItem {
    if (rt.eql(kind, "claude")) return &.{ .{ .value = "fable" }, .{ .value = "opus" }, .{ .value = "sonnet" }, .{ .value = "haiku" } };
    if (rt.eql(kind, "fx")) return fxModels();
    const models = piModels();
    var out: std.ArrayListUnmanaged(PickItem) = .empty;
    for (models) |m| {
        if (rt.eql(kind, "codex")) {
            if (rt.eql(m.provider, "openai")) out.append(rt.a, .{ .value = m.id }) catch {};
        } else out.append(rt.a, .{ .value = rt.concat(&.{ m.provider, "/", m.id }), .description = m.provider }) catch {};
    }
    return out.items;
}

pub fn placementLabel(p: []const u8) []const u8 {
    if (rt.eql(p, "tab")) return "hidden tabs";
    if (rt.eql(p, "split")) return "beside the leader";
    if (rt.eql(p, "background")) return if (mux.caps().background) "no tabs" else "no tabs (hidden tabs here)";
    return "undefined";
}

fn placementPhrase(p: []const u8) []const u8 {
    if (rt.eql(p, "tab")) return "each in a hidden tab of its own";
    if (rt.eql(p, "split")) return "in the right half of your tab, each new one splitting the biggest crewmate the other way";
    if (rt.eql(p, "background")) return if (mux.caps().background) "in no tab at all; the user opens one from the crew pane as a popup" else "each in a hidden tab of its own (no tabs is set, but this multiplexer needs a tab)";
    return "undefined";
}

pub fn worktreeLabel(m: []const u8) []const u8 {
    if (rt.eql(m, "on")) return "on";
    if (rt.eql(m, "off")) return "off";
    if (rt.eql(m, "leader")) return "leader decides";
    if (rt.eql(m, "shared")) return "one shared worktree";
    return "undefined";
}

pub const Ask = *const fn (o: PickOptions) anyerror!?[]const u8;

pub const SettingsRow = struct {
    section: []const u8,
    label: []const u8,
    value: *const fn (c: Config) []const u8,
    change: *const fn (c: Config, ask: Ask) anyerror!void,
    /// Whether the row applies under the multiplexer Lodestar runs in; rows without one always do.
    shown: ?*const fn () bool = null,
    /// The `lodestar config set` flag that sets the row, and the one that clears it back to the harness default.
    flag: []const u8,
    clear: ?[]const u8 = null,
    /// Whether something else decides the row for now (routing picks the model and effort): greyed, and not changed.
    decided: ?*const fn (c: Config) bool = null,
};

const HARNESS_DEFAULT: PickItem = .{ .value = "", .label = "harness default", .description = "pass nothing; the harness picks" };

fn kindOf(c: Config) []const u8 {
    return c.str("kind") orelse crewmates.DEFAULT_KIND;
}

fn kindDefaults(c: Config) *Obj {
    const kinds = c.obj("kinds") orelse return json.newObj();
    return kinds.obj(kindOf(c)) orelse json.newObj();
}

fn onOff(b: bool) []const u8 {
    return if (b) "on" else "off";
}

fn minutes(n: i64) []const u8 {
    if (n == 0) return "off";
    if (@mod(n, 60) == 0) return rt.fmt("{d} h", .{@divTrunc(n, 60)});
    return rt.fmt("{d} min", .{n});
}

fn setKindDefault(c: Config, field: []const u8, value: ?[]const u8) void {
    const next = kindDefaults(c).clone();
    next.putStr(field, value);
    c.ensureObj("kinds").put(kindOf(c), next.val());
}

fn parseMinutes(text: []const u8) !i64 {
    const n = @import("../cli/args.zig").jsNumber(text);
    if (n == null or @floor(n.?) != n.? or n.? < 0 or !std.math.isFinite(n.?)) return rt.fail(null, "\"{s}\" is not a whole number of minutes; 0 turns the alert off", .{text});
    return @intFromFloat(n.?);
}

fn settings(c: Config) *Obj {
    return config.settingsObj(config.settingsOf(c));
}

fn sPlacement(c: Config) []const u8 {
    return settings(c).str("placement") orelse "tab";
}
fn sWorktree(c: Config) []const u8 {
    return settings(c).str("worktree") orelse "leader";
}
fn sNavigator(c: Config) bool {
    return settings(c).boolean("navigator") orelse true;
}
fn sPopup(c: Config) bool {
    return settings(c).boolean("popup") orelse true;
}
fn sReview(c: Config) bool {
    return settings(c).boolean("review") orelse true;
}
fn sStall(c: Config) i64 {
    return settings(c).int("stall_minutes") orelse 20;
}
fn sHandoff(c: Config) *Obj {
    return settings(c).obj("handoff") orelse json.object(.{ .{ "enabled", false }, .{ "at_tokens", 200_000 } });
}

fn modelOrDefault(c: Config) []const u8 {
    return kindDefaults(c).str("model") orelse "harness default";
}
fn thinkingOrDefault(c: Config) []const u8 {
    return kindDefaults(c).str("thinking") orelse "harness default";
}

fn vHarness(c: Config) []const u8 {
    return kindOf(c);
}
fn cHarness(c: Config, ask: Ask) anyerror!void {
    const v = try ask(.{ .title = "Crewmates run in", .items = &KINDS, .current = kindOf(c) });
    if (v) |x| if (x.len > 0) c.putStr("kind", x);
}

fn cModel(c: Config, ask: Ask) anyerror!void {
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    try items.append(rt.a, HARNESS_DEFAULT);
    try items.appendSlice(rt.a, modelsFor(kindOf(c)));
    const v = try ask(.{ .title = rt.concat(&.{ "Model for ", kindOf(c) }), .items = items.items, .current = kindDefaults(c).str("model") orelse "", .allowCustom = true, .hint = "type to search · ^j/^k move · enter picks, or takes what you typed · ^h or esc cancels" });
    if (v) |x| setKindDefault(c, "model", if (x.len > 0) x else null);
}

fn cEffort(c: Config, ask: Ask) anyerror!void {
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    try items.append(rt.a, HARNESS_DEFAULT);
    for (thinkingFor(kindOf(c)) orelse thinkingFor("pi").?) |l| try items.append(rt.a, .{ .value = l });
    const v = try ask(.{ .title = rt.concat(&.{ "Effort for ", kindOf(c) }), .items = items.items, .current = kindDefaults(c).str("thinking") orelse "" });
    if (v) |x| setKindDefault(c, "thinking", if (x.len > 0) x else null);
}

fn vPlacement(c: Config) []const u8 {
    return placementLabel(sPlacement(c));
}
fn cPlacement(c: Config, ask: Ask) anyerror!void {
    const all = [_]PickItem{ .{ .value = "tab", .label = "hidden tabs" }, .{ .value = "split", .label = "beside the leader" }, .{ .value = "background", .label = "no tabs" } };
    const items = if (mux.caps().background) all[0..] else all[0..2];
    const v = try ask(.{ .title = "New crewmates open in", .items = items, .current = sPlacement(c) });
    if (v) |x| if (x.len > 0) c.putStr("placement", x);
}

fn vWorktree(c: Config) []const u8 {
    return worktreeLabel(sWorktree(c));
}
fn cWorktree(c: Config, ask: Ask) anyerror!void {
    const items = [_]PickItem{ .{ .value = "on", .label = "on" }, .{ .value = "off", .label = "off" }, .{ .value = "leader", .label = "leader decides" }, .{ .value = "shared", .label = "one shared worktree" } };
    const v = try ask(.{ .title = "Git worktrees for crewmates", .items = &items, .current = sWorktree(c) });
    if (v) |x| if (x.len > 0) c.putStr("worktree", x);
}

fn vNavigator(c: Config) []const u8 {
    return onOff(sNavigator(c));
}
fn cNavigator(c: Config, ask: Ask) anyerror!void {
    _ = ask;
    c.putBool("navigator", !sNavigator(c));
}

fn vPopup(c: Config) []const u8 {
    return onOff(sPopup(c));
}
fn cPopup(c: Config, ask: Ask) anyerror!void {
    _ = ask;
    c.putBool("popup", !sPopup(c));
}
fn canFloat() bool {
    return mux.caps().float;
}

fn vReview(c: Config) []const u8 {
    return onOff(sReview(c));
}
fn cReview(c: Config, ask: Ask) anyerror!void {
    _ = ask;
    c.putBool("review", !sReview(c));
}

fn vStall(c: Config) []const u8 {
    return minutes(sStall(c));
}
fn cStall(c: Config, ask: Ask) anyerror!void {
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    for ([_]i64{ 10, 20, 30, 60, 0 }) |n| try items.append(rt.a, .{ .value = rt.fmt("{d}", .{n}), .label = minutes(n) });
    const v = try ask(.{ .title = "Stall alert after", .items = items.items, .current = rt.fmt("{d}", .{sStall(c)}), .allowCustom = true, .hint = "^j/^k move · or type minutes and press enter · ^h or esc cancels" });
    if (v) |x| c.putInt("stall_minutes", try parseMinutes(x));
}

fn handoffWith(c: Config, key: []const u8, v: json.Value) void {
    const next = if (c.obj("handoff")) |h| h.clone() else json.newObj();
    next.put(key, v);
    c.put("handoff", next.val());
}

fn vHandoff(c: Config) []const u8 {
    return onOff(sHandoff(c).boolean("enabled") orelse false);
}
fn cHandoff(c: Config, ask: Ask) anyerror!void {
    _ = ask;
    handoffWith(c, "enabled", json.b(!(sHandoff(c).boolean("enabled") orelse false)));
}

fn atTokens(c: Config) i64 {
    return sHandoff(c).int("at_tokens") orelse 200_000;
}
fn vHandoffAt(c: Config) []const u8 {
    return rt.concat(&.{ config.formatTokens(atTokens(c)), " tokens" });
}
fn cHandoffAt(c: Config, ask: Ask) anyerror!void {
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    for ([_]i64{ 100, 150, 200, 300, 400, 600 }) |k| try items.append(rt.a, .{ .value = rt.fmt("{d}k", .{k}), .label = rt.fmt("{d}k tokens", .{k}) });
    const v = try ask(.{ .title = "Hand off once the leader's context passes", .items = items.items, .current = config.formatTokens(atTokens(c)), .allowCustom = true, .hint = "^j/^k move · or type a size like 250k and press enter · ^h or esc cancels" });
    if (v) |x| handoffWith(c, "at_tokens", json.i(try config.parseTokens(x)));
}

fn sRouter(c: Config) []const u8 {
    return (c.obj("routing") orelse return "off").str("provider") orelse "off";
}
fn vRouting(c: Config) []const u8 {
    const p = sRouter(c);
    if (rt.eql(p, "off")) return "off";
    if (routedProfiles(c) == null) return rt.concat(&.{ p, " (no models listed for ", kindOf(c), ")" });
    return p;
}
/// The routing profiles for the current harness when routing is on: the model and effort come from one of them.
/// Yours from the routing configuration, else Lodestar's tiers on the harness's newest models.
fn routedProfiles(c: Config) ?*Obj {
    if (rt.eql(sRouter(c), "off")) return null;
    const configured = if (c.obj("routing")) |r| if (r.obj("kinds")) |k| k.obj(kindOf(c)) else null else null;
    const kind = configured orelse builtinTiers(kindOf(c)) orelse return null;
    const profiles = kind.obj("profiles") orelse return null;
    return if (profiles.count() > 0) profiles else null;
}

fn builtinTiers(kind: []const u8) ?*Obj {
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    if (!rt.eql(kind, "claude")) {
        kept_models_only = true;
        defer kept_models_only = false;
        for (modelsFor(kind)) |m| ids.append(rt.a, m.value) catch {};
    }
    return @import("../core/tiers.zig").profilesFor(kind, ids.items);
}
fn routed(c: Config) bool {
    return routedProfiles(c) != null;
}
fn vModelRouted(c: Config) []const u8 {
    return if (routed(c)) rt.concat(&.{ sRouter(c), " picks" }) else modelOrDefault(c);
}
fn vEffortRouted(c: Config) []const u8 {
    return if (routed(c)) rt.concat(&.{ sRouter(c), " picks" }) else thinkingOrDefault(c);
}

/// The profiles the router picks from, as `name  model · effort`.
fn profileItems(profiles: *Obj) []const PickItem {
    var out: std.ArrayListUnmanaged(PickItem) = .empty;
    var width: usize = 0;
    for (profiles.keys()) |name| width = @max(width, ansi.width(name));
    for (profiles.keys()) |name| {
        const p = profiles.obj(name) orelse continue;
        const model = p.str("model") orelse "?";
        const label = rt.concat(&.{ ansi.pad(name, width + 2), ansi.dim(if (p.str("thinking")) |t| rt.concat(&.{ model, " · ", t }) else model) });
        out.append(rt.a, .{ .value = name, .label = label }) catch {};
    }
    return out.items;
}

fn cRouting(c: Config, ask: Ask) anyerror!void {
    const items = [_]PickItem{
        .{ .value = "off", .label = "off" },
        .{ .value = "openai", .label = "openai", .description = "OpenAI Decisions; needs OPENAI_API_KEY" },
        .{ .value = "jev", .label = "jev", .description = "TypeSafe Jev; needs TYPESAFE_API_KEY" },
    };
    const v = try ask(.{ .title = "Model routing", .items = &items, .current = sRouter(c) });
    const x = v orelse return;
    if (x.len == 0) return;
    const base = if (c.obj("routing")) |r| r.clone() else json.object(.{.{ "kinds", json.newObj() }});
    base.putStr("provider", x);
    c.put("routing", (try routing.validateRouting(base.val())).val());
}

/// The active router's key: from its environment variable, saved here, or missing.
fn vKey(c: Config) []const u8 {
    const p = sRouter(c);
    if (rt.eql(p, "off")) return "routing off";
    if (rt.getenvNonEmpty(api_keys.envName(p)) != null) return rt.concat(&.{ "from $", api_keys.envName(p) });
    if (api_keys.stored(p)) |k| return rt.concat(&.{ "saved ", api_keys.hint(k) });
    return "not set";
}
fn cKey(c: Config, ask: Ask) anyerror!void {
    const p = sRouter(c);
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    if (rt.eql(p, "off")) {
        try items.append(rt.a, .{ .value = "", .label = "pick a router first" });
    } else {
        try items.append(rt.a, .{ .value = "enter", .label = "type or paste a key" });
        if (api_keys.stored(p) != null) try items.append(rt.a, .{ .value = "remove", .label = "remove the saved key" });
    }
    const v = try ask(.{ .title = rt.concat(&.{ "Key for ", p }), .items = items.items });
    const x = v orelse return;
    if (rt.eql(p, "off")) return rt.fail(null, "Pick a router first; the key is for the router", .{});
    if (rt.eql(x, "remove")) return api_keys.save(p, null);
    if (!rt.eql(x, "enter")) return;
    const typed = try readSecret(rt.concat(&.{ "Key for ", p, " (", api_keys.envName(p), ")" })) orelse return;
    if (rt.trim(typed).len > 0) try api_keys.save(p, typed);
}

/// A line typed or pasted without showing it: a dot per character. Null when cancelled.
fn readSecret(title: []const u8) !?[]const u8 {
    var raw: term.Raw = .{};
    raw.enable();
    defer {
        raw.disable();
        rt.writeStdout(ansi.screen.clear);
    }
    var typed: std.ArrayListUnmanaged(u8) = .empty;
    var reader: term.KeyReader = .{};
    while (true) {
        const sz = term.size(80, 24);
        const dots = ansi.repeat("•", @min(typed.items.len, sz.cols -| 10));
        rt.writeStdout(rt.concat(&.{ ansi.screen.clear, ansi.screen.at(2, 3), ansi.bold(title), ansi.screen.at(4, 3), ansi.fg.cyan("›"), " ", dots, ansi.inverse(" "), ansi.screen.at(sz.rows -| 1, 3), ansi.dim("type or paste · enter saves · esc cancels"), ansi.screen.at(6, 3), ansi.dim(rt.concat(&.{ "saved to ", api_keys.file(), ", readable only by you" })) }));
        const data = term.readStdin(reader.timeoutMs() orelse -1) orelse return null;
        for (if (data.len == 0) reader.expire() else reader.feed(data)) |key| {
            const name = key.name orelse "";
            if ((key.ctrl and rt.eql(name, "c")) or rt.eql(name, "escape")) return null;
            if (rt.eql(name, "return") or rt.eql(name, "enter")) return typed.items;
            if (rt.eql(name, "backspace")) {
                if (typed.items.len > 0) typed.items.len -= 1;
            } else if (key.ctrl and rt.eql(name, "u")) {
                typed.items.len = 0;
            } else if (key.ch) |ch| if (!key.ctrl and !key.meta and ch.len > 0 and ch[0] > ' ') try typed.appendSlice(rt.a, ch);
        }
    }
}

fn sUsagePane(c: Config) bool {
    return settings(c).boolean("usage_pane") orelse true;
}
fn vUsagePane(c: Config) []const u8 {
    return onOff(sUsagePane(c));
}
fn cUsagePane(c: Config, ask: Ask) anyerror!void {
    _ = ask;
    c.putBool("usage_pane", !sUsagePane(c));
}

fn sSide(c: Config) []const u8 {
    return settings(c).str("sidebar_side") orelse "right";
}
fn vSide(c: Config) []const u8 {
    return sSide(c);
}
fn cSide(c: Config, ask: Ask) anyerror!void {
    const items = [_]PickItem{ .{ .value = "right" }, .{ .value = "left" } };
    const v = try ask(.{ .title = "Sidebar opens on the", .items = &items, .current = sSide(c) });
    if (v) |x| if (x.len > 0) c.putStr("sidebar_side", x);
}

fn sCrewBar(c: Config) bool {
    return settings(c).boolean("crew_bar") orelse true;
}
fn vCrewBar(c: Config) []const u8 {
    return onOff(sCrewBar(c));
}
fn cCrewBar(c: Config, ask: Ask) anyerror!void {
    _ = ask;
    c.putBool("crew_bar", !sCrewBar(c));
}

fn sAccent(c: Config) []const u8 {
    return settings(c).str("accent") orelse "theme";
}
/// The value in its own colour, so the row shows what it picks.
fn vAccent(c: Config) []const u8 {
    const a = sAccent(c);
    const look = if (rt.eql(a, "theme")) theme.loadTheme() else theme.Theme{ .accent = a };
    return rt.concat(&.{ theme.paint(look).apply("●"), " ", a });
}
fn cAccent(c: Config, ask: Ask) anyerror!void {
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    for (config.ACCENTS) |a| try items.append(rt.a, .{ .value = a, .description = if (rt.eql(a, "theme")) "herdr's accent under herdr, else the terminal's cyan" else "from the terminal's palette" });
    const v = try ask(.{ .title = "Accent colour", .items = items.items, .current = sAccent(c), .allowCustom = true, .hint = "^j/^k move · enter picks, or type a colour like #89b482 · ^h or esc cancels" });
    const x = v orelse return;
    if (x.len == 0) return;
    if (!config.validAccent(x)) return rt.fail(null, "\"{s}\" is not an accent: pick one, or type a colour like #89b482", .{x});
    c.putStr("accent", x);
}

fn sRetries(c: Config) i64 {
    return settings(c).int("max_failed_attempts") orelse 3;
}
fn retries(n: i64) []const u8 {
    if (n == 0) return "no limit";
    return if (n == 1) "1 attempt" else rt.fmt("{d} attempts", .{n});
}
fn vRetries(c: Config) []const u8 {
    return retries(sRetries(c));
}
fn cRetries(c: Config, ask: Ask) anyerror!void {
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    for ([_]i64{ 1, 2, 3, 5, 0 }) |n| try items.append(rt.a, .{ .value = rt.fmt("{d}", .{n}), .label = retries(n) });
    const v = try ask(.{ .title = "Failed attempts before a task stops", .items = items.items, .current = rt.fmt("{d}", .{sRetries(c)}), .allowCustom = true, .hint = "^j/^k move · or type a number and press enter · ^h or esc cancels" });
    if (v) |x| c.putInt("max_failed_attempts", try parseMinutes(x));
}

pub const SETTINGS_ROWS = [_]SettingsRow{
    .{ .section = "Crew", .label = "Harness", .value = vHarness, .change = cHarness, .flag = "--kind" },
    .{ .section = "Crew", .label = "Model", .value = vModelRouted, .change = cModel, .flag = "--model", .clear = "--clear-model", .decided = routed },
    .{ .section = "Crew", .label = "Effort", .value = vEffortRouted, .change = cEffort, .flag = "--thinking", .clear = "--clear-thinking", .decided = routed },
    .{ .section = "Crew", .label = "Routing", .value = vRouting, .change = cRouting, .flag = "--router" },
    .{ .section = "Crew", .label = "Router key", .value = vKey, .change = cKey, .flag = "" },
    .{ .section = "Crew", .label = "Placement", .value = vPlacement, .change = cPlacement, .flag = "--placement" },
    .{ .section = "Crew", .label = "Popup", .value = vPopup, .change = cPopup, .shown = canFloat, .flag = "--popup" },
    .{ .section = "Crew", .label = "Worktrees", .value = vWorktree, .change = cWorktree, .flag = "--worktree-mode" },
    .{ .section = "Orchestrator", .label = "Navigator", .value = vNavigator, .change = cNavigator, .flag = "--navigator" },
    .{ .section = "Orchestrator", .label = "Review", .value = vReview, .change = cReview, .flag = "--review" },
    .{ .section = "Orchestrator", .label = "Retry limit", .value = vRetries, .change = cRetries, .flag = "--retry-limit" },
    .{ .section = "Orchestrator", .label = "Stall alert", .value = vStall, .change = cStall, .flag = "--stall-minutes" },
    .{ .section = "Orchestrator", .label = "Handoff", .value = vHandoff, .change = cHandoff, .flag = "--handoff" },
    .{ .section = "Orchestrator", .label = "Handoff at", .value = vHandoffAt, .change = cHandoffAt, .flag = "--handoff-at" },
    .{ .section = "Display", .label = "Sidebar side", .value = vSide, .change = cSide, .flag = "--sidebar-side" },
    .{ .section = "Display", .label = "Usage pane", .value = vUsagePane, .change = cUsagePane, .flag = "--usage-pane" },
    .{ .section = "Display", .label = "Crewmate bar", .value = vCrewBar, .change = cCrewBar, .flag = "--crew-bar" },
    .{ .section = "Display", .label = "Accent", .value = vAccent, .change = cAccent, .flag = "--accent" },
};

fn joinNonEmpty(parts: []const ?[]const u8, sep: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    for (parts) |p| {
        const x = p orelse continue;
        if (x.len == 0) continue;
        if (!first) out.appendSlice(rt.a, sep) catch {};
        out.appendSlice(rt.a, x) catch {};
        first = false;
    }
    return out.items;
}

pub fn describeSettings(c: Config) []const u8 {
    const d = kindDefaults(c);
    const handoff = sHandoff(c);
    const wk = joinNonEmpty(&.{ kindOf(c), d.str("model"), d.str("thinking"), placementLabel(sPlacement(c)), if (canFloat()) rt.concat(&.{ "popup ", onOff(sPopup(c)) }) else null, rt.concat(&.{ "worktrees ", worktreeLabel(sWorktree(c)) }) }, " · ");
    const handoff_text = if (handoff.boolean("enabled") orelse false) rt.concat(&.{ "handoff at ", config.formatTokens(atTokens(c)) }) else "handoff off";
    const leader = joinNonEmpty(&.{ rt.concat(&.{ "navigator ", onOff(sNavigator(c)) }), rt.concat(&.{ "review ", onOff(sReview(c)) }), rt.concat(&.{ "stall ", minutes(sStall(c)) }), handoff_text }, " · ");
    return rt.concat(&.{ "crewmates: ", wk, " | leader: ", leader });
}

fn worktreeRule(m: []const u8) []const u8 {
    if (rt.eql(m, "on")) return "on: every crewmate started in a git repository gets its own worktree without `--worktree`; pass `--worktree PATH` only to reuse a checkout.";
    if (rt.eql(m, "off")) return "off: `--worktree` is refused; keep crewmates on separate files instead.";
    if (rt.eql(m, "leader")) return "leader decides: pass `--worktree new` when two crewmates' edits could collide.";
    if (rt.eql(m, "shared")) return "shared: every crewmate of the run starts in one shared worktree (see \"Run modes\"); `--worktree` or `--cwd` opts a crewmate out.";
    return "undefined";
}

pub fn settingsInForce(c: Config) []const u8 {
    const d = kindDefaults(c);
    const stall = sStall(c);
    const handoff_on = sHandoff(c).boolean("enabled") orelse false;
    const lines = [_][]const u8{
        "",
        "## Settings in force",
        "",
        "The user sets these on the Lodestar settings page (`lodestar settings`). Flags you pass still win, except that worktrees set to off refuse `--worktree`.",
        "",
        rt.fmt("- New crewmates: {s}, model {s}, effort {s}, {s}.", .{ kindOf(c), d.str("model") orelse "harness default", d.str("thinking") orelse "harness default", placementPhrase(sPlacement(c)) }),
        rt.concat(&.{ "- Worktrees ", worktreeRule(sWorktree(c)) }),
        rt.concat(&.{ "- Navigator: ", if (sNavigator(c)) "`run create` opens one under you." else "off; `run create` opens none." }),
        rt.concat(&.{ "- Review: ", if (sReview(c)) "on: verify a crewmate's work before you accept its report." else "off (see \"Run modes\"): accept reports without reviewing the code; `run create --no-review` sets this per run too." }),
        rt.concat(&.{ "- Stall alert: ", if (stall != 0) rt.fmt("after {s} of silence.", .{minutes(stall)}) else "off." }),
        rt.concat(&.{ "- Handoff: ", if (handoff_on) rt.fmt("on, past {s} tokens of your context (see Handoff).", .{config.formatTokens(atTokens(c))}) else "off." }),
        "",
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (lines, 0..) |l, i| {
        if (i > 0) out.append(rt.a, '\n') catch {};
        out.appendSlice(rt.a, l) catch {};
    }
    return out.items;
}

/// The rows that apply under the current multiplexer.
pub fn visibleRows() []const SettingsRow {
    var out: std.ArrayListUnmanaged(SettingsRow) = .empty;
    for (SETTINGS_ROWS) |r| if (r.shown == null or r.shown.?()) out.append(rt.a, r) catch {};
    return out.items;
}

/// On and off as a filled or hollow dot; other values as they are.
fn shownValue(v: []const u8, accent: ansi.Paint) []const u8 {
    if (rt.eql(v, "on")) return accent.apply("● on");
    if (rt.eql(v, "off")) return ansi.dim("○ off");
    return v;
}

var captured: ?PickOptions = null;

fn askCapture(o: PickOptions) anyerror!?[]const u8 {
    captured = o;
    return null;
}

const Choices = struct { items: []const PickItem, current: []const u8, toggle: bool = false, decided: bool = false };

/// What a row can be set to and which it is now: the list `enter` would open, or on and off for a toggle. The row's
/// own change function asks for the list, on a copy of the configuration so a toggle flips nothing.
fn choicesOf(row: SettingsRow, c: Config) Choices {
    if (row.decided) |d| if (d(c)) return .{ .items = profileItems(routedProfiles(c).?), .current = "", .decided = true };
    captured = null;
    kept_models_only = true;
    row.change(c.deepClone(), askCapture) catch {};
    kept_models_only = false;
    const o = captured orelse return .{ .items = &.{ .{ .value = "on" }, .{ .value = "off" } }, .current = row.value(c), .toggle = true };
    const cur = o.current orelse "";
    for (o.items) |it| if (rt.eql(it.value, cur)) return .{ .items = o.items, .current = cur };
    if (o.current == null) return .{ .items = o.items, .current = cur };
    // A value typed in rather than picked from the list: shown after it, as the row shows it.
    const now = ansi.stripSgr(row.value(c));
    var items: std.ArrayListUnmanaged(PickItem) = .empty;
    items.appendSlice(rt.a, o.items) catch {};
    items.append(rt.a, .{ .value = cur, .label = if (rt.startsWith(now, "● ")) now["● ".len..] else now }) catch {};
    return .{ .items = items.items, .current = cur };
}

/// The command that sets the row to `current`, quoted where a shell would split or drop it.
fn commandFor(row: SettingsRow, current: []const u8) []const u8 {
    if (current.len == 0) return rt.concat(&.{ "lodestar config set ", row.clear orelse return "" });
    const arg = if (std.mem.indexOfAny(u8, current, " #'\"$") != null) rt.concat(&.{ "'", current, "'" }) else current;
    return rt.concat(&.{ "lodestar config set ", row.flag, " ", arg });
}

fn accentSwatch(value: []const u8) []const u8 {
    const look = if (rt.eql(value, "theme")) theme.themeAccent() else theme.Theme{ .accent = value };
    return theme.paint(look).apply("■");
}

/// Beside the rows: the selected row's choices with the current one marked, and the command that sets it. With
/// `cursor`, the list has the keys and that item is the one under them. A long list shows the part around the cursor,
/// or else the current value.
fn choicesPanel(row: SettingsRow, c: Config, height: usize, accent: ansi.Paint, cursor: ?usize) []const []const u8 {
    const ch = choicesOf(row, c);
    const cmd = if (ch.decided) "" else commandFor(row, ch.current);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    out.appendSlice(rt.a, &.{ if (ch.decided) rt.concat(&.{ ansi.bold(row.label), ansi.dim(rt.concat(&.{ "  ", sRouter(c), " picks a profile per task" })) }) else ansi.bold(row.label), "" }) catch {};
    const room = height -| (out.items.len + @as(usize, if (cmd.len > 0) 2 else 0));
    const n = ch.items.len;
    // An action list (the router key) has no current item.
    var at: ?usize = null;
    for (ch.items, 0..) |it, i| if (rt.eql(it.value, ch.current)) {
        at = i;
        break;
    };
    const count = if (n <= room) n else room -| 1;
    const start = if (count == 0) 0 else @min((cursor orelse at orelse 0) -| count / 2, n - count);
    const swatch = rt.eql(row.flag, "--accent");
    for (ch.items[start .. start + count], start..) |it, i| {
        const label = if (swatch) rt.concat(&.{ accentSwatch(it.value), " ", it.label orelse it.value }) else it.label orelse it.value;
        const under = cursor != null and cursor.? == i;
        const dot = if (i == at) accent.apply("● ") else ansi.dim("○ ");
        const text = if (under) accent.apply(ansi.bold(label)) else if (at == i) accent.apply(label) else label;
        out.append(rt.a, rt.concat(&.{ if (under) accent.apply("❯ ") else "  ", dot, text })) catch {};
    }
    if (count < n and room > 0) out.append(rt.a, ansi.dim(rt.fmt("    {d} more", .{n - count}))) catch {};
    if (cmd.len > 0 and height >= out.items.len + 2) out.appendSlice(rt.a, &.{ "", ansi.dim(cmd) }) catch {};
    return out.items;
}

/// The panel needs this many columns to be worth drawing.
const PANEL_MIN: usize = 18;
/// Between columns of rows, on a pane too short for one.
const COLUMN_GAP: usize = 4;

const KEYS = [_][2][]const u8{ .{ "j/k", "move" }, .{ "enter", "change" }, .{ "q", "close" } };
/// The keys while the choices beside the rows have them.
const LIST_KEYS = [_][2][]const u8{ .{ "j/k", "move" }, .{ "enter", "pick" }, .{ "/", "search" }, .{ "h", "back" } };

/// The rows' lines split into columns of at most `room`, as `[start, end)`. A column ends before a section's name
/// in its lower half, or else not on a section's name.
fn flowColumns(is_section: []const bool, room: usize) []const [2]usize {
    var out: std.ArrayListUnmanaged([2]usize) = .empty;
    if (is_section.len <= room or room == 0) {
        out.append(rt.a, .{ 0, is_section.len }) catch {};
        return out.items;
    }
    var i: usize = 0;
    while (i < is_section.len) {
        var e = @min(is_section.len, i + room);
        if (e < is_section.len) {
            var k = e;
            while (k > i + room / 2 and !is_section[k]) k -= 1;
            if (is_section[k] and k > i) e = k else if (is_section[e - 1] and e - 1 > i) e -= 1;
        }
        out.append(rt.a, .{ i, e }) catch {};
        i = e;
    }
    return out.items;
}

/// Whether the last page drawn had the choices beside the rows; without them, `enter` opens the full list.
var panel_drawn = false;

/// The page: a margin, rows by section with values in one column, and the keys at the bottom, fitted to the pane's height.
/// With `list`, the choices beside the rows have the keys, the cursor on item `list`, and the selected row is greyed.
pub fn renderSettings(c: Config, sel: usize, list: ?usize, cols: usize, rows: usize, notice: []const u8, accent: ansi.Paint) []const []const u8 {
    const shown = visibleRows();
    const margin = if (cols >= 40) "  " else " ";
    const w: usize = @max(10, cols -| 2 * margin.len);
    var label_width: usize = 0;
    for (shown) |r| label_width = @max(label_width, r.label.len);
    label_width += 4;

    // The page fits the pane instead of scrolling. As the pane gets shorter it drops space: first the gaps between
    // sections and around the keys, then the gap under the title, then the margin above it. Shorter still, the rows
    // flow into columns side by side; only a pane too narrow for those scrolls, keeping the selected row in view.
    var sections: usize = 0;
    var last: []const u8 = "";
    for (shown) |r| if (!rt.eql(r.section, last)) {
        last = r.section;
        sections += 1;
    };
    const extra: usize = if (notice.len > 0) 2 else 0;
    // The rows, their section names, the notice and the keys, with no space between them.
    const lines = shown.len + sections + extra + 1;
    const roomy = rows >= lines + sections + 4;
    var head_len: usize = if (rows >= lines + 3) 3 else if (rows >= lines + 2) 2 else if (rows >= lines + 1) 1 else 3;

    var body: std.ArrayListUnmanaged([]const u8) = .empty;
    var is_section: std.ArrayListUnmanaged(bool) = .empty;
    var sel_line: usize = 0;
    var section: []const u8 = "";
    var value_width: usize = 0;
    for (shown, 0..) |row, i| {
        if (!rt.eql(row.section, section)) {
            section = row.section;
            if (body.items.len > 0 and roomy) {
                body.append(rt.a, "") catch {};
                is_section.append(rt.a, false) catch {};
            }
            body.append(rt.a, ansi.dim(std.ascii.allocUpperString(rt.a, section) catch section)) catch {};
            is_section.append(rt.a, true) catch {};
        }
        if (i == sel) sel_line = body.items.len;
        const value = row.value(c);
        value_width = @max(value_width, ansi.width(shownValue(value, accent)));
        const greyed = if (row.decided) |d| d(c) else false;
        body.append(rt.a, if (greyed)
            rt.concat(&.{ if (i == sel) accent.apply("❯ ") else "  ", ansi.dim(rt.concat(&.{ ansi.pad(row.label, label_width), value })) })
        else if (i == sel and list != null)
            ansi.dim(rt.concat(&.{ "❯ ", ansi.pad(row.label, label_width), ansi.stripSgr(shownValue(value, accent)) }))
        else if (i == sel)
            rt.concat(&.{ accent.apply("❯ "), accent.apply(ansi.bold(ansi.pad(row.label, label_width))), if (rt.eql(value, "on") or rt.eql(value, "off")) shownValue(value, accent) else accent.apply(value) })
        else
            rt.concat(&.{ "  ", ansi.pad(row.label, label_width), shownValue(value, accent) })) catch {};
        is_section.append(rt.a, false) catch {};
    }

    var foot: std.ArrayListUnmanaged([]const u8) = .empty;
    if (notice.len > 0) foot.appendSlice(rt.a, &.{ "", ansi.fg.yellow(notice) }) catch {};
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    for (if (list != null) LIST_KEYS[0..] else KEYS[0..]) |k| keys.append(rt.a, rt.concat(&.{ k[0], " ", ansi.dim(k[1]) })) catch {};
    const hint = std.mem.join(rt.a, ansi.dim("   "), keys.items) catch "";

    // The title; then the rows, in as many columns as they need; then the footer and the keys on the last line.
    // Columns that don't fit across under the title with its margins may fit with the title alone.
    const col_w = 2 + label_width + value_width;
    var columns: []const [2]usize = &.{};
    var room: usize = 0;
    for ([_]usize{ head_len, 1 }) |h| {
        head_len = h;
        room = rows -| (h + foot.items.len + @as(usize, if (roomy) 3 else 1));
        columns = flowColumns(is_section.items, room);
        if (columns.len * (col_w + COLUMN_GAP) - COLUMN_GAP <= w) break;
    } else {
        const start = @min(sel_line -| room / 2, body.items.len - room);
        columns = rt.a.dupe([2]usize, &.{.{ start, start + room }}) catch &.{};
    }
    const title = [_][]const u8{ "", ansi.bold("Lodestar settings"), "" };
    const head = title[if (head_len == 1) 1 else 0..][0..head_len];
    var body_h: usize = 0;
    for (columns) |r| body_h = @max(body_h, r[1] - r[0]);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (head) |l| out.append(rt.a, l) catch {};
    for (0..body_h) |r| {
        var line: []const u8 = "";
        for (columns, 0..) |col, k| {
            const l = if (col[0] + r < col[1]) body.items[col[0] + r] else "";
            line = if (k == 0) l else rt.concat(&.{ ansi.pad(line, k * (col_w + COLUMN_GAP)), l });
        }
        out.append(rt.a, line) catch {};
    }
    for (foot.items) |l| out.append(rt.a, l) catch {};
    while (out.items.len + @as(usize, if (roomy) 2 else 1) < rows) out.append(rt.a, "") catch {};
    out.append(rt.a, hint) catch {};
    if (roomy) out.append(rt.a, "") catch {};

    // The selected row's choices to the right of the rows, past a rule, from the first section down to the keys.
    const left_w = columns.len * (col_w + COLUMN_GAP) - COLUMN_GAP;
    const hint_at = out.items.len - @as(usize, if (roomy) 2 else 1);
    const region_end = @min(hint_at -| @as(usize, if (roomy) 1 else 0), rows);
    panel_drawn = sel < shown.len and w >= left_w + 6 + PANEL_MIN and region_end > head.len;
    if (panel_drawn) {
        const panel = choicesPanel(shown[sel], c, region_end - head.len, accent, list);
        const foot_at = head.len + body_h;
        for (head.len..region_end) |r| {
            if (r >= foot_at and r < foot_at + foot.items.len) continue;
            const p = r - head.len;
            out.items[r] = rt.concat(&.{ ansi.pad(out.items[r], left_w), "   ", ansi.dim("│"), "  ", if (p < panel.len) panel[p] else "" });
        }
    }
    for (out.items) |*l| l.* = if (l.len == 0) "" else rt.concat(&.{ margin, ansi.truncate(l.*, @intCast(w)) });
    return out.items[0..@min(out.items.len, rows)];
}

fn askNested(o: PickOptions) anyerror!?[]const u8 {
    var nested = o;
    nested.nested = true;
    const v = picker.pick(nested);
    rt.writeStdout(ansi.screen.clear);
    return v;
}

/// The value picked from the choices beside the rows, handed to the row's change function as its answer.
var chosen: []const u8 = "";

fn askChosen(o: PickOptions) anyerror!?[]const u8 {
    _ = o;
    return chosen;
}

fn drawSettings(c: Config, sel: usize, list: ?usize, notice: []const u8, accent: ansi.Paint) void {
    const sz = term.size(80, 24);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(rt.a, ansi.screen.home) catch {};
    const lines = renderSettings(c, sel, list, sz.cols, sz.rows, notice, accent);
    for (0..sz.rows) |r| {
        buf.appendSlice(rt.a, ansi.screen.at(r + 1, 1)) catch {};
        buf.appendSlice(rt.a, ansi.screen.clearLine) catch {};
        if (r < lines.len) buf.appendSlice(rt.a, lines[r]) catch {};
    }
    rt.writeStdout(buf.items);
}

const RESIZE_CHECK_MS: i64 = 200;

fn isKey(key: term.Key, ch: []const u8) bool {
    return !key.ctrl and !key.meta and key.ch != null and rt.eql(key.ch.?, ch);
}

/// The interactive settings page; returns the (saved) configuration when closed. Vim keys: j/k move, g/G jump to the
/// first or last row; enter (or space) is the only way to change a value: it flips a toggle or moves into the row's
/// choices beside it (the full list when the pane is too narrow for them). There j/k move, enter picks, / opens the
/// full list to search or type a value, and h or esc goes back to the rows.
pub fn runSettings() !Config {
    if (!term.isTty(0) or !term.isTty(1)) return rt.fail(null, "lodestar settings needs a terminal", .{});
    const c = try config.loadConfig();
    const accent = theme.paint(theme.loadTheme());
    var sel: usize = 0;
    // The cursor in the choices beside the rows while they have the keys, and those choices.
    var list: ?usize = null;
    var list_items: []const PickItem = &.{};
    var notice: []const u8 = "";
    var raw: term.Raw = .{};
    raw.enable();
    rt.writeStdout(ansi.screen.alt ++ ansi.screen.hideCursor ++ ansi.screen.clear);
    defer {
        raw.disable();
        rt.writeStdout(ansi.screen.showCursor ++ ansi.screen.main);
    }
    const shown = visibleRows();
    const n = shown.len;
    // A popup is often sized after the page has drawn once; redraw when it is.
    term.installWinch();
    drawSettings(c, sel, list, notice, accent);
    var reader: term.KeyReader = .{};
    while (true) {
        const data = term.readStdin(reader.timeoutMs() orelse RESIZE_CHECK_MS) orelse return c;
        if (term.got_winch.swap(false, .seq_cst)) drawSettings(c, sel, list, notice, accent);
        const keys = if (data.len == 0) reader.expire() else reader.feed(data);
        for (keys) |key| {
            const name = key.name orelse "";
            if (key.ctrl and rt.eql(name, "c")) return c;
            var ask: ?Ask = null;
            const chord = term.ctrlOf(key);
            const enter = rt.eql(name, "return") or rt.eql(name, "enter") or rt.eql(name, "space");
            if (list) |at| {
                const m = list_items.len;
                if (rt.eql(name, "escape") or isKey(key, "q") or isKey(key, "h") or rt.eql(name, "left") or chord == 'h') {
                    list = null;
                } else if (rt.eql(name, "up") or isKey(key, "k") or chord == 'k' or chord == 'p') {
                    list = (at + m - 1) % m;
                } else if (rt.eql(name, "down") or isKey(key, "j") or chord == 'j' or chord == 'n') {
                    list = (at + 1) % m;
                } else if (isKey(key, "g") or rt.eql(name, "home")) {
                    list = 0;
                } else if (isKey(key, "G") or rt.eql(name, "end")) {
                    list = m - 1;
                } else if (enter) {
                    chosen = list_items[at].value;
                    ask = askChosen;
                    list = null;
                } else if (isKey(key, "/")) {
                    ask = askNested;
                    list = null;
                } else continue;
            } else if (rt.eql(name, "escape") or isKey(key, "q")) {
                return c;
            } else if (chord == 'k') {
                sel = (sel + n - 1) % n;
            } else if (chord == 'j') {
                sel = (sel + 1) % n;
            } else if (rt.eql(name, "up") or isKey(key, "k") or (key.ctrl and rt.eql(name, "p"))) {
                sel = (sel + n - 1) % n;
            } else if (rt.eql(name, "down") or isKey(key, "j") or (key.ctrl and rt.eql(name, "n"))) {
                sel = (sel + 1) % n;
            } else if (isKey(key, "g") or rt.eql(name, "home")) {
                sel = 0;
            } else if (isKey(key, "G") or rt.eql(name, "end")) {
                sel = n - 1;
            } else if (enter and if (shown[sel].decided) |d| d(c) else false) {
                notice = rt.concat(&.{ sRouter(c), " picks the model and effort from the profiles; turn Routing off to set them" });
                drawSettings(c, sel, list, notice, accent);
                continue;
            } else if (enter) {
                const ch = if (panel_drawn) choicesOf(shown[sel], c) else null;
                if (ch == null or ch.?.toggle or ch.?.items.len == 0) {
                    ask = askNested;
                } else {
                    list_items = ch.?.items;
                    list = 0;
                    for (list_items, 0..) |it, i| if (rt.eql(it.value, ch.?.current)) {
                        list = i;
                        break;
                    };
                }
            } else continue;
            notice = "";
            if (ask) |f| {
                if (shown[sel].change(c, f)) |_| {
                    if (config.saveConfig(c)) |_| {} else |err| notice = rt.dupe(rt.errMessage(err));
                } else |err| notice = rt.dupe(rt.errMessage(err));
                raw.enable();
            }
            drawSettings(c, sel, list, notice, accent);
        }
    }
}

test "the settings page shows the popup row and no-tabs placement only where the multiplexer can" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    defer mux.useMux(null);
    const c = json.newObj();
    mux.useMux(&@import("../mux/herdr.zig").backend);
    for (visibleRows()) |r| try std.testing.expect(!rt.eql(r.label, "Popup"));
    try std.testing.expectEqualStrings("no tabs (hidden tabs here)", placementLabel("background"));
    mux.useMux(&@import("../mux/rex.zig").backend);
    var popup = false;
    for (visibleRows()) |r| popup = popup or rt.eql(r.label, "Popup");
    try std.testing.expect(popup);
    try std.testing.expectEqualStrings("on", vPopup(c));
}

test "picking sets a row's value, and a short page scrolls to the selected row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    defer mux.useMux(null);
    mux.useMux(&@import("../mux/rex.zig").backend);
    const c = json.newObj();
    chosen = "background";
    try cPlacement(c, askChosen);
    try std.testing.expectEqualStrings("background", sPlacement(c));
    chosen = "jev";
    try cRouting(c, askChosen);
    try std.testing.expectEqualStrings("jev", sRouter(c));
    try cUsagePane(c, askChosen);
    try std.testing.expectEqualStrings("off", vUsagePane(c));
    const last = visibleRows().len - 1;
    const page = renderSettings(c, last, null, 50, 16, "", .{});
    try std.testing.expectEqual(@as(usize, 16), page.len);
    var found = false;
    for (page) |l| found = found or std.mem.indexOf(u8, ansi.stripSgr(l), "❯ Accent") != null;
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("  j/k move   enter change   q close", ansi.stripSgr(page[15]));
}

test "a short pane drops the spacing, then flows the rows into columns, so every row shows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    defer mux.useMux(null);
    mux.useMux(&@import("../mux/rex.zig").backend);
    const c = json.newObj();
    for ([_][2]usize{ .{ 120, 24 }, .{ 120, 14 }, .{ 90, 14 } }) |sz| {
        const page = renderSettings(c, 0, null, sz[0], sz[1], "", .{});
        try std.testing.expectEqual(sz[1], page.len);
        var text: std.ArrayListUnmanaged(u8) = .empty;
        for (page) |l| try text.appendSlice(rt.a, rt.concat(&.{ ansi.stripSgr(l), "\n" }));
        for (visibleRows()) |r| try std.testing.expect(std.mem.indexOf(u8, text.items, r.label) != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, "Lodestar settings") != null);
    }
}

test "a wide page lists the selected row's choices beside it, with the command that sets the current one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    defer mux.useMux(null);
    mux.useMux(&@import("../mux/rex.zig").backend);
    const c = json.newObj();
    c.putStr("kind", "claude");
    const page = renderSettings(c, 0, null, 120, 34, "", .{});
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (page) |l| try text.appendSlice(rt.a, rt.concat(&.{ ansi.stripSgr(l), "\n" }));
    try std.testing.expect(std.mem.indexOf(u8, text.items, "│    ● claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "│    ○ codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "lodestar config set --kind claude") != null);
    // A toggle shows on and off; a stall time typed in is listed after the presets.
    c.putInt("stall_minutes", 45);
    var found = false;
    for (choicesPanel(SETTINGS_ROWS[11], c, 20, .{}, null)) |l| found = found or rt.eql(ansi.stripSgr(l), "  ● 45 min");
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 2), choicesOf(SETTINGS_ROWS[8], c).items.len);
    try std.testing.expectEqualStrings("lodestar config set --accent '#89b482'", commandFor(SETTINGS_ROWS[17], "#89b482"));
    try std.testing.expectEqualStrings("lodestar config set --clear-model", commandFor(SETTINGS_ROWS[1], ""));
    // A list longer than the room shows the part around the current value and how many it left out.
    const short = choicesPanel(SETTINGS_ROWS[17], c, 6, .{}, null);
    try std.testing.expectEqualStrings("    6 more", ansi.stripSgr(short[3]));
    // Too narrow for it: no panel.
    for (renderSettings(c, 0, null, 60, 34, "", .{})) |l| try std.testing.expect(std.mem.indexOf(u8, l, "│") == null);
}

test "with the choices holding the keys, the row is greyed and the cursor shows in the list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    defer mux.useMux(null);
    mux.useMux(&@import("../mux/rex.zig").backend);
    const c = json.newObj();
    c.putStr("kind", "claude");
    const page = renderSettings(c, 0, 1, 120, 34, "", .{});
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (page) |l| try text.appendSlice(rt.a, rt.concat(&.{ ansi.stripSgr(l), "\n" }));
    try std.testing.expect(std.mem.indexOf(u8, text.items, "│  ❯ ○ codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "│    ● claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "/ search") != null);
    try std.testing.expect(std.mem.indexOf(u8, page[4], "\x1b[2m❯ Harness") != null);
    // Picking hands the row's change function the value.
    chosen = "codex";
    try cHarness(c, askChosen);
    try std.testing.expectEqualStrings("codex", kindOf(c));
}

test "with routing on and profiles for the harness, model and effort are the router's and list the profiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    rt.initForTest(arena.allocator(), &map);
    const c = (try json.parse(
        \\{"kind":"fx","routing":{"provider":"jev","kinds":{"fx":{"fallback":"b","profiles":{"a":{"model":"m1","thinking":"low","description":"x"},"b":{"model":"m2","description":"y"}}}}}}
    )).asObj().?;
    try std.testing.expectEqualStrings("jev picks", vModelRouted(c));
    try std.testing.expectEqualStrings("jev picks", vEffortRouted(c));
    const ch = choicesOf(SETTINGS_ROWS[1], c);
    try std.testing.expect(ch.decided);
    try std.testing.expectEqual(@as(usize, 2), ch.items.len);
    try std.testing.expectEqualStrings("a  m1 · low", ansi.stripSgr(ch.items[0].label.?));
    // A harness without profiles of its own gets Lodestar's tiers; Claude Code's need no model list.
    c.putStr("kind", "claude");
    const tiers = choicesOf(SETTINGS_ROWS[1], c);
    try std.testing.expectEqual(@as(usize, 4), tiers.items.len);
    try std.testing.expectEqualStrings("ultra     fable · xhigh", ansi.stripSgr(tiers.items[3].label.?));
    // With routing off, the model and effort are the harness's own again.
    c.obj("routing").?.putStr("provider", "off");
    try std.testing.expect(!routed(c));
    try std.testing.expectEqualStrings("harness default", vModelRouted(c));
}
