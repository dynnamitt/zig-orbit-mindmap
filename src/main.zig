const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const ecs = @import("zflecs");
const sim = @import("sim");
const config = @import("config");

const width = 800;
const height = 450;
// Render-only colours (tech-trio.svg palette; ball colours are in sim.zig).
const background = 0x0E1414FF; // near-black teal
const sand = 0xC8A878FF; // readout text
const link_gray = 0x666666FF; // planet-to-mother dots and the mother's ring
const cord_glow = 0xB8F5C8FF; // pale green: the children's cords

// Links (world units). Cords are thin cylinders, ready to glow once bloom
// lands; planet links are dashes from the planet to the mother's ring.
const cord_radius = 0.05;
const cord_sides = 6;
const dash_len = 0.3;
const dash_gap = 0.25;
/// The mother's ring: radius as a multiple of hers, leaving room for her glow.
const ring_scale = 2.2;
const ring_segments = 48;

const fovy = 45; // degrees, vertical
// Perf readout: top-right, right-aligned, raylib's default font size.
// The buffer fits any i32 FPS and any sane ms pair.
const stats_margin = 16;
const stats_font_size = 20;
const stats_line_gap = 4;
const stats_buf_len = 64;
// emscripten_set_main_loop args: fps 0 = requestAnimationFrame; nonzero
// simulate_infinite_loop = never return from main.
const web_loop_fps = 0;
const web_simulate_infinite_loop = 1;

// zflecs allocates through std.heap.page_allocator, which on wasm calls
// memory.grow behind emscripten's back. That fails on emscripten's fixed-size
// heap (panic: OOM in ecs.init), so take pages from emscripten's malloc.
pub const os = if (builtin.os.tag == .emscripten) struct {
    pub const heap = struct {
        pub const page_allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &EmscriptenPages.vtable };
    };
} else struct {};

/// Aligned (no over-allocation) and zero-filled: zflecs' DebugAllocator
/// assumes its backing allocator returns zeroed memory, as real pages are.
const EmscriptenPages = struct {
    // std.c only exposes posix_memalign on some OSes; emscripten's libc has it.
    extern "c" fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) c_int;

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    };

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        var p: ?*anyopaque = null;
        if (posix_memalign(&p, @max(alignment.toByteUnits(), @sizeOf(usize)), len) != 0) return null;
        const bytes: [*]u8 = @ptrCast(p orelse return null);
        @memset(bytes[0..len], 0);
        return bytes;
    }

    fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        std.c.free(memory.ptr);
    }
};

/// Globals, not locals in main: on web, emscripten_set_main_loop unwinds
/// main's stack and calls frame() later.
var world: *ecs.world_t = undefined;
var balls: *ecs.query_t = undefined;
var cords: *ecs.query_t = undefined;
var inputs: *ecs.query_t = undefined;
var mothers: *ecs.query_t = undefined;
var cam: sim.OrbitCam = undefined;
var touch: sim.TouchSteer = .{};
/// This frame's interpolation weight and camera position, for the draw callbacks.
var alpha: f32 = 0;
var eye: sim.Vec3 = undefined;
var clock: sim.FixedClock = .{};
var stats: sim.FrameStats = .{};

pub fn main() !void {
    rl.initWindow(width, height, "zig-orbit-mindmap");
    defer rl.closeWindow();

    world = ecs.init();
    defer _ = ecs.fini(world);
    sim.register(world);
    if (config.threads > 0) ecs.set_threads(world, config.threads); // -Dthreads, native only
    _ = sim.spawnPlanets(world, sim.spawnCluster(world, .{ 0, 0, 0 }).mother);
    cam = sim.OrbitCam.framing(.{ 0, 0, 0 }, sim.system_radius);

    balls = try sim.ballQuery(world);
    defer ecs.query_fini(balls);
    cords = try sim.linkQuery(world, sim.Cord);
    defer ecs.query_fini(cords);
    inputs = try sim.linkQuery(world, sim.InputOf);
    defer ecs.query_fini(inputs);
    mothers = try sim.motherQuery(world);
    defer ecs.query_fini(mothers);

    if (builtin.os.tag == .emscripten) {
        // raylib's web pacing (WindowShouldClose's emscripten_sleep, SetTargetFPS's
        // WaitTime) isn't vsync-aligned and needs Asyncify. Never returns, so
        // the defers above don't run.
        std.os.emscripten.emscripten_set_main_loop(frame, web_loop_fps, web_simulate_infinite_loop);
    } else {
        rl.setTargetFPS(60);
        while (!rl.windowShouldClose()) frame();
    }
}

fn frame() callconv(.c) void {
    const work_start = rl.getTime();
    // Fixed steps, never raylib's raw dt: a long frame would otherwise
    // fling planets out of orbit, and dt=0 (first frame) would make
    // flecs measure its own clock.
    for (0..clock.advance(rl.getFrameTime())) |_| _ = ecs.progress(world, sim.step_dt);
    alpha = clock.alpha();

    steer();
    // The barycenter, interpolated like the stars, so the camera never
    // jitters against them.
    cam.target = drawnOf(ecs.id(sim.Barycenter));
    eye = cam.eye();

    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.getColor(background));

    rl.beginMode3D(.{
        .position = vec3(eye),
        .target = vec3(cam.target),
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = fovy,
        .projection = .perspective,
    });
    // Glowing geometry (cords, then stars and planets), then the gray links
    // and rings, which #6's bloom pass will leave out.
    forEachDrawn(cords, drawCord);
    forEachDrawn(balls, drawBall);
    forEachDrawn(inputs, drawInputLink);
    forEachDrawn(mothers, drawRing);
    rl.endMode3D();

    // CPU work = sim steps + issuing draw calls, up to here. Flush raylib's
    // last draw batch first so it counts. GPU time isn't measured (GL runs
    // asynchronously, so it shows up at present); the present (buffer swap, vsync and
    // setTargetFPS waits) is idle time and stays out. On web performance.now()
    // is coarsened (~0.1 ms), so read the mean, not one frame.
    rlDrawRenderBatchActive();
    stats.add(rl.getFrameTime(), @floatCast(rl.getTime() - work_start));
    // Not rl.drawFPS: its lime/orange/red colours ignore the theme.
    var buf: [stats_buf_len]u8 = undefined;
    drawStat(std.fmt.bufPrintSentinel(&buf, "{d} FPS", .{rl.getFPS()}, 0) catch unreachable, 0);
    drawStat(std.fmt.bufPrintSentinel(&buf, "cpu {d:.2}/{d:.2} ms", .{ stats.mean_ms, stats.max_ms }, 0) catch "cpu ?", 1);
}

/// Mouse or one finger turns the camera, the wheel or two fingers zoom.
fn steer() void {
    var touches: [2]sim.Touch = undefined;
    const n: usize = @intCast(std.math.clamp(rl.getTouchPointCount(), 0, touches.len));
    for (touches[0..n], 0..) |*t, i| {
        const p = rl.getTouchPosition(@intCast(i));
        t.* = .{ .id = rl.getTouchPointId(@intCast(i)), .x = p.x, .y = p.y };
    }
    const d = rl.getMouseDelta();
    switch (touch.update(touches[0..n], rl.isMouseButtonDown(.left), .{ d.x, d.y })) {
        .none => {},
        .drag => |by| cam.drag(by[0], by[1]),
        .pinch => |ratio| cam.pinch(ratio),
    }
    cam.zoom(rl.getMouseWheelMove());
}

/// Calls `draw` for every entity of `q` (term 0 `Position`, term 1 optional
/// `PrevPosition`, as every sim query lays them out) at its drawn position.
fn forEachDrawn(q: *ecs.query_t, comptime draw: fn (it: *ecs.iter_t, i: usize, at: sim.Vec3) void) void {
    var it = ecs.query_iter(world, q);
    while (ecs.query_next(&it)) {
        const prevs = ecs.field(&it, sim.PrevPosition, 1);
        for (ecs.field(&it, sim.Position, 0).?, 0..) |p, i| draw(&it, i, drawnAt(p, if (prevs) |pp| &pp[i] else null));
    }
}

fn drawBall(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const b = ecs.field(it, sim.Ball, 2).?[i];
    rl.drawSphere(vec3(at), b.radius, rl.getColor(b.rgba));
}

/// A child's glowing cord to her mother.
fn drawCord(it: *ecs.iter_t, _: usize, at: sim.Vec3) void {
    const to = drawnOf(sim.pairTarget(it, 2));
    rl.drawCylinderEx(vec3(at), vec3(to), cord_radius, cord_radius, cord_sides, rl.getColor(cord_glow));
}

/// Dashes from a planet to its mother's ring (its sphere hides the start).
fn drawInputLink(it: *ecs.iter_t, _: usize, at: sim.Vec3) void {
    const mother = sim.pairTarget(it, 2);
    const d = drawnOf(mother) - at;
    const len = sim.length(d) - ringRadius(mother);
    if (len <= 0) return;
    const dir = sim.normalize(d);
    const color = rl.getColor(link_gray);
    var t: f32 = 0;
    while (t < len) : (t += dash_len + dash_gap) {
        rl.drawLine3D(vec3(at + dir * sim.splat(t)), vec3(at + dir * sim.splat(@min(t + dash_len, len))), color);
    }
}

/// A gray circle around a mother that always faces the camera.
fn drawRing(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const r = ecs.field(it, sim.Ball, 2).?[i].radius * ring_scale;
    // Axes from the camera's own view direction, which the pitch clamp keeps
    // off vertical (the direction to the mother itself may not be).
    const view = cam.target - eye;
    const right = sim.cross(view, .{ 0, 1, 0 });
    const u = sim.normalize(right) * sim.splat(r);
    const v = sim.normalize(sim.cross(right, view)) * sim.splat(r);
    const color = rl.getColor(link_gray);
    var prev = at + u;
    for (1..ring_segments + 1) |k| {
        const t = std.math.tau * @as(f32, @floatFromInt(k)) / ring_segments;
        const next = at + u * sim.splat(@cos(t)) + v * sim.splat(@sin(t));
        rl.drawLine3D(vec3(prev), vec3(next), color);
        prev = next;
    }
}

fn ringRadius(mother: ecs.entity_t) f32 {
    return ecs.get(world, mother, sim.Ball).?.radius * ring_scale;
}

/// `drawnAt` for an entity looked up by id.
fn drawnOf(e: ecs.entity_t) sim.Vec3 {
    return drawnAt(ecs.get(world, e, sim.Position).?.*, ecs.get(world, e, sim.PrevPosition));
}

/// Where to draw an entity: between its last two steps when it moves, so
/// motion stays smooth when frames don't line up with steps (rAF jitter,
/// 120/144 Hz screens).
fn drawnAt(p: sim.Position, prev: ?*const sim.PrevPosition) sim.Vec3 {
    const pp = prev orelse return p.v;
    return std.math.lerp(pp.v, p.v, sim.splat(alpha));
}

fn vec3(v: sim.Vec3) rl.Vector3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

// rlgl, part of the raylib library; raylib-zig doesn't export it as a module.
extern fn rlDrawRenderBatchActive() void;

/// One right-aligned readout line; `line` 0 is the top.
fn drawStat(text: [:0]const u8, line: i32) void {
    const x = width - stats_margin - rl.measureText(text, stats_font_size);
    rl.drawText(text, x, stats_margin + line * (stats_font_size + stats_line_gap), stats_font_size, rl.getColor(sand));
}
