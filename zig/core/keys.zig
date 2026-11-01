//! API keys for model routing, typed into the settings page: `<config_dir>/keys.json`, readable only by you,
//! `{ "jev": "...", "openai": "..." }`. Kept apart from config.json so showing or sharing the settings never shows a
//! key. The provider's environment variable still wins.

const std = @import("std");
const rt = @import("../rt.zig");
const json = @import("json.zig");
const fs = @import("fs.zig");
const paths = @import("paths.zig");

pub fn file() []const u8 {
    return fs.join(&.{ paths.config_dir, "keys.json" });
}

/// The environment variable a router's key comes from.
pub fn envName(provider: []const u8) []const u8 {
    return if (rt.eql(provider, "openai")) "OPENAI_API_KEY" else "TYPESAFE_API_KEY";
}

fn load() *json.Obj {
    const text = fs.readFileOpt(file()) orelse return json.newObj();
    return ((json.parse(text) catch return json.newObj()).asObj()) orelse json.newObj();
}

/// The key saved for `provider`, if any.
pub fn stored(provider: []const u8) ?[]const u8 {
    return load().strNonEmpty(provider);
}

/// Saves `key` for `provider`, or forgets it when null.
pub fn save(provider: []const u8, key: ?[]const u8) !void {
    const o = load();
    if (key) |k| o.putStr(provider, rt.trim(k)) else _ = o.map.orderedRemove(provider);
    _ = paths.ensureDir(paths.config_dir);
    fs.writeAtomic(file(), json.stringifyObj(o, true), 0o600) catch return rt.fail(null, "Cannot save the key to {s}", .{file()});
}

/// The end of a key, enough to tell which one it is.
pub fn hint(key: []const u8) []const u8 {
    return if (key.len > 8) rt.concat(&.{ "····", key[key.len - 4 ..] }) else "····";
}
