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
var cam: sim.OrbitCam = undefined;
var clock: sim.FixedClock = .{};
var stats: sim.FrameStats = .{};

pub fn main() !void {
    rl.initWindow(width, height, "zig-orbit-mindmap");
    defer rl.closeWindow();

    world = ecs.init();
    defer _ = ecs.fini(world);
    sim.register(world);
    if (config.threads > 0) ecs.set_threads(world, config.threads); // -Dthreads, native only
    _ = sim.spawnCluster(world, .{ 0, 0, 0 });
    _ = sim.spawnPlanets(world);
    cam = sim.OrbitCam.framing(.{ 0, 0, 0 }, sim.system_radius);

    balls = try sim.ballQuery(world);
    defer ecs.query_fini(balls);

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
    // throw the orbit off for good, and dt=0 (first frame) would make
    // flecs measure its own clock.
    for (0..clock.advance(rl.getFrameTime())) |_| _ = ecs.progress(world, sim.step_dt);
    const alpha = clock.alpha();

    // Drag with the left button to turn the camera, wheel to zoom.
    if (rl.isMouseButtonDown(.left)) {
        const d = rl.getMouseDelta();
        cam.drag(d.x, d.y);
    }
    cam.zoom(rl.getMouseWheelMove());
    // The barycenter, interpolated like the stars, so the camera never
    // jitters against them.
    const bary = ecs.id(sim.Barycenter);
    cam.target = drawnAt(ecs.get(world, bary, sim.Position).?.*, ecs.get(world, bary, sim.PrevPosition), alpha);

    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.getColor(background));

    rl.beginMode3D(.{
        .position = vec3(cam.eye()),
        .target = vec3(cam.target),
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = fovy,
        .projection = .perspective,
    });
    // Every Position + Ball entity.
    var it = ecs.query_iter(world, balls);
    while (ecs.query_next(&it)) {
        const ps = ecs.field(&it, sim.Position, 0).?;
        const bs = ecs.field(&it, sim.Ball, 1).?;
        const prevs = ecs.field(&it, sim.PrevPosition, 2);
        for (ps, bs, 0..) |p, b, i| {
            const at = drawnAt(p, if (prevs) |pp| &pp[i] else null, alpha);
            rl.drawSphere(vec3(at), b.radius, rl.getColor(b.rgba));
        }
    }
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

/// Where to draw an entity: between its last two steps when it moves, so
/// motion stays smooth when frames don't line up with steps (rAF jitter,
/// 120/144 Hz screens).
fn drawnAt(p: sim.Position, prev: ?*const sim.PrevPosition, alpha: f32) sim.Vec3 {
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
