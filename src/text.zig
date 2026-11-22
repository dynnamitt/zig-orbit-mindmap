//! Screen text: two embedded faces (src/fonts) and the type scale. Render
//! side only (imports raylib), like main.zig.
//!
//! Each face is rasterized at the exact framebuffer pixel size it is drawn
//! at, so glyphs map 1:1 to pixels and stay sharp: no atlas scaled up or
//! down. Sizes are loaded on first use and cached (labels grow with zoom, so
//! a zoom gesture walks through a few dozen sizes; each atlas is small).
const std = @import("std");
const rl = @import("raylib");

pub const Face = enum {
    /// Inter SemiBold: outputs, buttons.
    sans,
    /// JetBrains Mono Regular: inputs (file names), the readout.
    mono,
};

/// The type scale, in screen units (logical pixels, before the HiDPI ratio).
pub const caption: f32 = 12; // readout, small UI
pub const label: f32 = 14; // inputs (mono runs small beside Inter)
pub const heading: f32 = 15; // outputs, counts
pub const icon: f32 = 20; // the − and + glyphs

const files = std.enums.EnumArray(Face, []const u8).init(.{
    .sans = @embedFile("fonts/Inter-SemiBold.ttf"),
    .mono = @embedFile("fonts/JetBrainsMono-Regular.ttf"),
});

/// Basic Latin and the extras the subset keeps (src/fonts/README.md).
const extras = [_]i32{ 0xB7, 0x2013, 0x2014, 0x2026, 0x2192, 0x2212 };
const codepoints = blk: {
    var cps: [0x7F - 0x20 + extras.len]i32 = undefined;
    for (0x20..0x7F, 0..) |c, i| cps[i] = c;
    for (extras, 0x7F - 0x20..) |c, i| cps[i] = c;
    break :blk cps;
};

/// Raster sizes kept per face, in framebuffer pixels; larger ones are drawn
/// scaled from the largest.
const max_px = 96;
const min_px = 6;

/// Loaded atlases by face and pixel size; `failed` marks sizes that didn't
/// load, so they aren't retried every frame (raylib's default font stands in).
var cache: std.enums.EnumArray(Face, [max_px + 1]?rl.Font) = .initFill(@splat(null));
var failed: std.enums.EnumArray(Face, [max_px + 1]bool) = .initFill(@splat(false));

/// Framebuffer pixels per screen unit: above 1 on HiDPI.
fn pixelRatio() f32 {
    const sw = rl.getScreenWidth();
    if (sw <= 0) return 1;
    return @max(1, @as(f32, @floatFromInt(rl.getRenderWidth())) / @as(f32, @floatFromInt(sw)));
}

/// The atlas for `face` at `px`, loading it on first use.
fn font(face: Face, px: usize) ?rl.Font {
    if (cache.get(face)[px]) |f| return f;
    if (failed.get(face)[px]) return null;
    const f = rl.loadFontFromMemory(".ttf", files.get(face), @intCast(px), &codepoints) catch {
        failed.getPtr(face)[px] = true;
        return null;
    };
    // Drawn at whole framebuffer pixels this changes nothing; between them
    // (or scaled past max_px) it keeps the edges smooth.
    rl.setTextureFilter(f.texture, .bilinear);
    cache.getPtr(face)[px] = f;
    return f;
}

/// What a draw at `size` screen units uses: the atlas, and the size to hand
/// raylib (in screen units, so the atlas lands 1:1 on framebuffer pixels).
const Pick = struct { font: ?rl.Font, size: f32 };

fn pick(face: Face, size: f32) Pick {
    const ratio = pixelRatio();
    const want = @round(size * ratio);
    const px: usize = @intFromFloat(std.math.clamp(want, min_px, max_px));
    const exact = want <= max_px and want >= min_px;
    return .{ .font = font(face, px), .size = if (exact) @as(f32, @floatFromInt(px)) / ratio else size };
}

/// The size `text` takes at `size` screen units.
pub fn measure(face: Face, text: [:0]const u8, size: f32) rl.Vector2 {
    const p = pick(face, size);
    if (p.font) |f| return rl.measureTextEx(f, text, p.size, 0);
    const s: i32 = @intFromFloat(@round(size));
    return .{ .x = @floatFromInt(rl.measureText(text, s)), .y = size };
}

/// `text` with its top left at `at` (screen units), snapped to whole
/// framebuffer pixels so glyphs stay sharp.
pub fn draw(face: Face, text: [:0]const u8, at: rl.Vector2, size: f32, color: rl.Color) void {
    const p = pick(face, size);
    const ratio = pixelRatio();
    const snapped: rl.Vector2 = .{ .x = @round(at.x * ratio) / ratio, .y = @round(at.y * ratio) / ratio };
    if (p.font) |f| return rl.drawTextEx(f, text, snapped, p.size, 0, color);
    rl.drawText(text, @intFromFloat(snapped.x), @intFromFloat(snapped.y), @intFromFloat(@round(size)), color);
}

/// Frees every loaded atlas (needs the window still open).
pub fn deinit() void {
    for (std.enums.values(Face)) |face| {
        for (cache.getPtr(face)) |*slot| if (slot.*) |f| {
            rl.unloadFont(f);
            slot.* = null;
        };
    }
}
