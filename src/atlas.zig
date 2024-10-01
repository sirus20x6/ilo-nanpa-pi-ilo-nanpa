const std = @import("std");

atlas: struct {
    type: []const u8,
    distanceRange: usize,
    distanceRangeMiddle: usize,
    size: f32,
    width: usize,
    height: usize,
    yOrigin: []const u8,
    },
    metrics: struct {
        emSize: f32,
        lineHeight: f32,
        ascender: f32,
        descender: f32,
        underlineY: f32,
        underlineThickness: f32,
    },

    glyphs: [] const struct {
        unicode: u32,
        advance: f32,
        planeBounds: ?Bounds = null,
        atlasBounds: ?Bounds = null,
    },
    kerning: []const struct {},

pub const Bounds = struct {
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
};

const Self = @This();

pub fn readAtlas(allocator: std.mem.Allocator) !std.json.Parsed(Self) {
    return try std.json.parseFromSlice(Self, allocator, @embedFile("atlas.json"), .{});
}
