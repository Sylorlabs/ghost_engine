const std = @import("std");
const intent_grounding = @import("intent_grounding.zig");

pub const Sketch = struct {
    hash: u64,
    feature_count: usize,

    pub fn valid(self: Sketch) bool {
        return self.feature_count != 0;
    }
};

const MAX_RUNES: usize = 128;
const MAX_NORMALIZED_BYTES: usize = 4096;

pub fn simHash64(allocator: std.mem.Allocator, text: []const u8) !Sketch {
    return simHash64Internal(allocator, text, .plain);
}

pub fn simHash64Query(allocator: std.mem.Allocator, text: []const u8) !Sketch {
    var salience = try intent_grounding.analyzeSalience(allocator, text);
    defer salience.deinit(allocator);
    if (salience.semantic_target.len == 0) return simHash64Internal(allocator, text, .plain);
    return simHash64Internal(allocator, salience.semantic_target, .plain);
}

const SketchMode = enum {
    plain,
    query_focus,
};

const Rune = struct {
    text: []u8,
    weight: i32,
};

fn simHash64Internal(allocator: std.mem.Allocator, text: []const u8, mode: SketchMode) !Sketch {
    var runes = std.ArrayList(Rune).init(allocator);
    defer {
        for (runes.items) |rune| allocator.free(rune.text);
        runes.deinit();
    }

    var normalized = std.ArrayList(u8).init(allocator);
    defer normalized.deinit();

    var start: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (isRuneByte(c)) {
            if (start == null) start = i;
        } else if (start) |s| {
            try appendNormalizedRune(allocator, &runes, &normalized, text[s..i]);
            start = null;
        }
        if (runes.items.len >= MAX_RUNES and normalized.items.len >= MAX_NORMALIZED_BYTES) break;
    }
    if (start) |s| {
        if (runes.items.len < MAX_RUNES or normalized.items.len < MAX_NORMALIZED_BYTES) {
            try appendNormalizedRune(allocator, &runes, &normalized, text[s..]);
        }
    }
    var weights = [_]i32{0} ** 64;
    var feature_count: usize = 0;

    for (runes.items) |rune| {
        addFeature(&weights, "rune", rune.text, null, rune.weight);
        feature_count += 1;
    }

    if (runes.items.len >= 2) {
        var idx: usize = 0;
        while (idx + 1 < runes.items.len) : (idx += 1) {
            const weight = @divTrunc(runes.items[idx].weight + runes.items[idx + 1].weight, 2);
            addFeature(&weights, "bi", runes.items[idx].text, runes.items[idx + 1].text, weight);
            feature_count += 1;
        }
    }

    const normalized_text = normalized.items;
    if (mode == .plain and normalized_text.len >= 3) {
        var idx: usize = 0;
        while (idx + 3 <= normalized_text.len) : (idx += 1) {
            const tri = normalized_text[idx .. idx + 3];
            if (tri[0] == ' ' or tri[2] == ' ') continue;
            addFeature(&weights, "tri", tri, null, 5);
            feature_count += 1;
        }
    }

    if (feature_count == 0) return .{ .hash = 0, .feature_count = 0 };

    var hash: u64 = 0;
    for (weights, 0..) |weight, bit| {
        if (weight >= 0) hash |= (@as(u64, 1) << @intCast(bit));
    }
    return .{ .hash = hash, .feature_count = feature_count };
}

pub fn hammingDistance(lhs: u64, rhs: u64) u7 {
    return @intCast(@popCount(lhs ^ rhs));
}

pub fn similarityScore(distance: u7) u16 {
    const remaining: u16 = 64 - @as(u16, distance);
    return @intCast((@as(u32, remaining) * 1000) / 64);
}

fn isRuneByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn simHash64Salience(runes: []const intent_grounding.SalienceRune) Sketch {
    var weights = [_]i32{0} ** 64;
    var feature_count: usize = 0;
    var last_selected: ?usize = null;
    for (runes, 0..) |rune, idx| {
        if (rune.selected_target) last_selected = idx;
    }
    for (runes, 0..) |rune, idx| {
        if (!rune.selected_target) continue;
        var weight: i32 = @intCast(@max(@as(u16, 1), rune.semantic_score / 80));
        if (last_selected != null and idx == last_selected.?) weight += 256;
        addFeature(&weights, "rune", rune.text, null, weight);
        feature_count += 1;
    }
    if (last_selected) |idx| {
        addFeature(&weights, "tail", runes[idx].text, null, 256);
        feature_count += 1;
    }
    if (feature_count == 0) return .{ .hash = 0, .feature_count = 0 };
    var hash: u64 = 0;
    for (weights, 0..) |weight, bit| {
        if (weight >= 0) hash |= (@as(u64, 1) << @intCast(bit));
    }
    return .{ .hash = hash, .feature_count = feature_count };
}

fn appendNormalizedRune(
    allocator: std.mem.Allocator,
    runes: *std.ArrayList(Rune),
    normalized: *std.ArrayList(u8),
    raw: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, raw, "_-");
    if (trimmed.len < 2) return;

    var lower_buf: [128]u8 = undefined;
    var lower_owned: ?[]u8 = null;
    const lower = if (trimmed.len <= lower_buf.len) blk: {
        for (trimmed, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);
        break :blk lower_buf[0..trimmed.len];
    } else blk: {
        const owned = try allocator.alloc(u8, trimmed.len);
        for (trimmed, 0..) |c, idx| owned[idx] = std.ascii.toLower(c);
        lower_owned = owned;
        break :blk owned;
    };
    defer if (lower_owned) |owned| allocator.free(owned);

    if (runes.items.len < MAX_RUNES) {
        try runes.append(.{ .text = try allocator.dupe(u8, lower), .weight = 10 });
    }
    if (normalized.items.len < MAX_NORMALIZED_BYTES) {
        if (normalized.items.len != 0) try normalized.append(' ');
        const remaining = MAX_NORMALIZED_BYTES - normalized.items.len;
        try normalized.appendSlice(lower[0..@min(lower.len, remaining)]);
    }
}

fn addFeature(weights: *[64]i32, prefix: []const u8, first: []const u8, second: ?[]const u8, weight: i32) void {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(prefix);
    hasher.update(":");
    hasher.update(first);
    if (second) |value| {
        hasher.update("|");
        hasher.update(value);
    }
    const hash = hasher.final();
    for (0..64) |bit| {
        const mask = @as(u64, 1) << @intCast(bit);
        if ((hash & mask) != 0) {
            weights[bit] += weight;
        } else {
            weights[bit] -= weight;
        }
    }
}

test "simhash is stable for identical text and near for small local variation" {
    const allocator = std.testing.allocator;
    const base = try simHash64(allocator, "retention policy is enabled for event audit logs");
    const same = try simHash64(allocator, "Retention policy is enabled for event audit logs");
    const near = try simHash64(allocator, "retention policy is enabled for event audit logs today");
    const unrelated = try simHash64(allocator, "shader compilation failed in a vulkan driver path");

    try std.testing.expect(base.valid());
    try std.testing.expectEqual(base.hash, same.hash);
    const near_distance = hammingDistance(base.hash, near.hash);
    const unrelated_distance = hammingDistance(base.hash, unrelated.hash);
    try std.testing.expect(near_distance < unrelated_distance);
}

test "query simhash focuses subject runes over inquiry runes" {
    const allocator = std.testing.allocator;
    const subject = try simHash64Query(allocator, "father");
    const inquiry = try simHash64Query(allocator, "whats a father");
    const unrelated = try simHash64Query(allocator, "whats a circuit");

    try std.testing.expect(subject.valid());
    try std.testing.expect(similarityScore(hammingDistance(subject.hash, inquiry.hash)) >= 900);
    try std.testing.expect(hammingDistance(subject.hash, inquiry.hash) < hammingDistance(subject.hash, unrelated.hash));
}

test "simhash preserves utf8 rune bytes" {
    const allocator = std.testing.allocator;
    const one = try simHash64Query(allocator, "¿qué es padre?");
    const two = try simHash64Query(allocator, "padre");
    try std.testing.expect(one.valid());
    try std.testing.expect(two.valid());
}

test "hammingDistance edge cases" {
    // exact match
    try std.testing.expectEqual(@as(u7, 0), hammingDistance(0x1234567890ABCDEF, 0x1234567890ABCDEF));

    // zero vs zero
    try std.testing.expectEqual(@as(u7, 0), hammingDistance(0, 0));

    // maxInt(u64) vs maxInt(u64)
    try std.testing.expectEqual(@as(u7, 0), hammingDistance(std.math.maxInt(u64), std.math.maxInt(u64)));

    // zero vs maxInt(u64) = 64
    try std.testing.expectEqual(@as(u7, 64), hammingDistance(0, std.math.maxInt(u64)));

    // one-bit difference = 1
    try std.testing.expectEqual(@as(u7, 1), hammingDistance(0b0000, 0b0001));
    try std.testing.expectEqual(@as(u7, 1), hammingDistance(0x8000000000000000, 0));

    // multi-bit difference
    try std.testing.expectEqual(@as(u7, 2), hammingDistance(0b1001, 0b0000));
    try std.testing.expectEqual(@as(u7, 4), hammingDistance(0x0F, 0x00));
}
