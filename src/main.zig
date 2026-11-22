const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const ecs = @import("zflecs");
const sim = @import("sim");
const config = @import("config");

/// Native starting size, landscape; `--portrait` swaps the two. The window is
/// resizable, and on web raylib sizes it to the viewport.
const long_side = 800;
const short_side = 450;
/// The smallest window (both sides; raylib clamps to it, natively and on web).
const min_side = 64;
// Render-only colours (tech-trio palette; ball colours are in sim.zig).
const background = 0x0E1414FF; // near-black teal
const sand = 0xC8A878FF; // readout text
const link_gray = 0x666666FF; // the mother's ring
const cord_glow = 0xB4F7CFFF; // pale phosphor green: the children's cords
/// Theme (phosphor CRT, beside the children's green in sim.zig): the planets'
/// orbit rings, inner amber and outer cyan. A planet's link takes its ring's.
const ring_colors = [2]u32{ 0xFFB000FF, 0x3FC8D0FF };

// Links (world units). Cords are glowing cylinders (thickness: sim.Cord.radius);
// planet links are faded tube dashes from the planet to the mother's ring:
// thinner and a little brighter while the planet is off its ring (not touching),
// and each dash lit by the cluster: brighter the nearer it is to the barycenter.
const cord_sides = 8;
const dash_len = 0.3;
const dash_gap = 0.25;
const tube_sides = 4; // faded rings' and links' tubes: too thin to look square
const link_width = 0.05; // tube radius
const link_alpha = 0.8; // at the barycenter; ~0.4 at the inner ring
const link_off_thin = 0.5; // × link_width
const link_off_alpha = 1.0;
const link_light_floor = 0.3;
const link_light_d0 = 6.0; // world units
const link_off_brighten = 0.2; // rl.colorBrightness
/// The mother's ring: radius as a multiple of hers, leaving room for her glow.
const ring_scale = 2.2;
const ring_segments = 48;
/// The planets' starting rings: faded tube dashes (every other segment).
const start_ring_width = 0.06; // tube radius
const start_ring_alpha = 0.3;
const start_ring_segments = 160;
// Thrusters (sim.Thruster): a nozzle disc set into the planet on the side it
// pushes from, and while firing a tapered, pulsing exhaust beam out of it,
// opposite its thrust (sim.zig `thrust`: it can point away from the slot while
// braking). Both glow while firing.
const nozzle_idle = 0x2A2E2EFF; // dark, like a hole
const flame = 0xFF9A3CFF; // orange
const flame_hot = 0xFFF2C8FF; // near white, at the pulse peak
const nozzle_size = 0.35; // disc radius / planet radius
const beam_length = 2.0; // / planet radius, at mid pulse
const beam_pulse = 0.35; // ± fraction of the length
const beam_pulse_hz = 5.0;
const beam_sides = 10;
/// The flame's colorBrightness in the glow pass: a slightly softer aura.
const flame_glow = -0.25;

// Labels: screen-space text beside each named body, drawn after bloom.
const label_color = 0xE0D8C8FF; // pale sand
const label_font_size = 16; // at the default zoom and further out
/// Outputs (bodies with a `(Cord, mother)` pair): larger, in their star's own green. 20 is 2x
/// raylib's 10 px default font, so it stays crisp.
const output_font_size = 20;
/// Their dark outline (the background colour, part see-through), so they read
/// over the glow: 1 px at `output_font_size`, thicker as they grow.
/// shortcut: most outline pixels sit under 3-5 of the 8 offset copies, so a
/// low alpha per copy stacks to about 60-75% (darker in tight spots); draw it
/// into a render texture once for an even alpha.
const outline_color = (background & 0xFFFFFF00) | 0x40;
const outline_offsets = [_][2]i32{ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
/// Zoomed in k times, labels grow k^this: a bit less than the bodies do.
const label_zoom_follow = 0.8;
const label_gap = 4; // pixels from the sphere's edge

// Bloom: stars, cords and firing thrusters are also drawn into a smaller glow
// texture, which is blurred and added on top of the scene. Planets go into it
// in black (so they hide the glow behind them); gray links and rings stay out.
const glow_downscale = 2; // glow texture size = window size / this
/// Glowing spheres are drawn this much larger than the stars, for a wider aura.
const glow_grow = 1.4;
/// Black occluder spheres in the glow pass, relative to the ball.
const occluder_grow = 1.04;
/// Horizontal + vertical blur rounds; each widens the aura.
const blur_rounds = 2;
/// Glow texels between the blur's taps (wider is softer; above ~2 it bands).
const blur_spread = 1.5;
/// How many times the glow is added: brightness of the aura. Two (approved
/// look) washes the green children toward mint-white in their cores.
const glow_layers = 2;
/// src/shaders/blur.fs with its header: GLSL ES 1.00 for WebGL 1, GLSL 330 on
/// desktop (raylib's default vertex shader supplies fragTexCoord).
const web = builtin.os.tag == .emscripten;
const blur_fs = (if (web)
    "#version 100\nprecision mediump float;\nvarying vec2 fragTexCoord;\n#define TEX texture2D\n#define FRAG gl_FragColor\n"
else
    "#version 330\nin vec2 fragTexCoord;\nout vec4 fragOut;\n#define TEX texture\n#define FRAG fragOut\n") ++ @embedFile("shaders/blur.fs");

// Planet lighting (src/shaders/planet.vs/.fs): a faint ambient plus every
// star's colour, weighted by its share of the stars' mass, where the surface
// faces it. Lit sides come out brighter than the base colour.
const planet_ambient: f32 = 0.3;
const planet_light_gain: f32 = 1.0;
const planet_mesh_detail = 24; // rings and slices of the unit sphere
const planet_vs = (if (web)
    "#version 100\nattribute vec3 vertexPosition;\nattribute vec3 vertexNormal;\nvarying vec3 fragPos;\nvarying vec3 fragNormal;\n"
else
    "#version 330\nin vec3 vertexPosition;\nin vec3 vertexNormal;\nout vec3 fragPos;\nout vec3 fragNormal;\n") ++ @embedFile("shaders/planet.vs");
const planet_fs = (if (web)
    "#version 100\nprecision mediump float;\nvarying vec3 fragPos;\nvarying vec3 fragNormal;\n#define FRAG gl_FragColor\n"
else
    "#version 330\nin vec3 fragPos;\nin vec3 fragNormal;\nout vec4 fragOut;\n#define FRAG fragOut\n") ++
    std.fmt.comptimePrint("#define MAX_STARS {d}\n", .{sim.max_stars}) ++ @embedFile("shaders/planet.fs");
// Starfield (src/shaders/sky.fs): drawn first, added onto the background.
// Its hash needs highp: WebGL without it in fragment shaders gets no stars.
const sky_fs = (if (web)
    "#version 100\n#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#define SKY_OFF\n#endif\n#define FRAG gl_FragColor\n"
else
    "#version 330\nout vec4 fragOut;\n#define FRAG fragOut\n") ++ @embedFile("shaders/sky.fs");
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
pub const os = if (web) struct {
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
var stars: *ecs.query_t = undefined;
var labels: *ecs.query_t = undefined;
var thrusters: *ecs.query_t = undefined;
/// This frame's camera, for the label callback.
var frame_camera: rl.Camera3D = undefined;
/// Glow textures: the stars drawn into [0], then blurred back and forth.
var glow: [2]rl.RenderTexture2D = undefined;
var blur: rl.Shader = undefined;
var blur_tap: i32 = undefined;
var planets: *ecs.query_t = undefined;
/// A unit sphere with normals, scaled per planet, and its lit material.
var planet_mesh: rl.Mesh = undefined;
var planet_material: rl.Material = undefined;
/// planet.fs uniform locations.
var loc_star_count: i32 = undefined;
var loc_star_pos: i32 = undefined;
var loc_star_light: i32 = undefined;
/// This frame's stars, as the planet shader sees them.
var star_n: i32 = 0;
var star_pos: [sim.max_stars][3]f32 = undefined;
var star_light: [sim.max_stars][3]f32 = undefined;
var star_mass_total: f32 = 0;
var sky: rl.Shader = undefined;
/// sky.fs uniform locations, by name.
var sky_loc: struct { resolution: i32, fwd: i32, right: i32, up: i32, time: i32 } = undefined;
var cam: sim.OrbitCam = undefined;
var touch: sim.TouchSteer = .{};
/// This frame's interpolation weight and camera position, for the draw callbacks.
var alpha: f32 = 0;
var eye: sim.Vec3 = undefined;
/// This frame's camera axes, unit: forward, right, up. The pitch clamp keeps
/// forward off vertical.
var view: [3]sim.Vec3 = undefined;
var clock: sim.FixedClock = .{};
/// The window size the camera is framed for (see `resize`).
var view_size: [2]i32 = undefined;
/// Whether `glow` holds textures for `view_size`; without them, no glow.
var glow_ok = false;
var stats: sim.FrameStats = .{};

pub fn main(init: std.process.Init.Minimal) !void {
    const portrait = !web and try hasArg(init.args, "--portrait");
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(if (portrait) short_side else long_side, if (portrait) long_side else short_side, "zig-orbit-mindmap");
    defer rl.closeWindow();
    rl.setWindowMinSize(min_side, min_side);

    world = ecs.init();
    defer _ = ecs.fini(world);
    sim.register(world);
    if (config.threads > 0) ecs.set_threads(world, config.threads); // -Dthreads, native only
    _ = sim.spawnPlanets(world, sim.spawnCluster(world, .{ 0, 0, 0 }).mother, sim.planet_count);
    cam = sim.OrbitCam.framing(.{ 0, 0, 0 }, sim.system_radius, aspect());

    balls = try sim.ballQuery(world, null);
    defer ecs.query_fini(balls);
    cords = try sim.linkQuery(world, sim.Cord, &.{});
    defer ecs.query_fini(cords);
    inputs = try sim.linkQuery(world, sim.InputOf, &.{ sim.Slot, sim.Ball });
    defer ecs.query_fini(inputs);
    mothers = try sim.ballQuery(world, sim.Mother);
    defer ecs.query_fini(mothers);
    stars = try sim.ballQuery(world, sim.Star);
    defer ecs.query_fini(stars);
    labels = try sim.ballQuery(world, sim.Label);
    defer ecs.query_fini(labels);
    thrusters = try sim.ballQuery(world, sim.Thruster);
    defer ecs.query_fini(thrusters);

    view_size = screenSize();
    glow = try loadGlow(view_size);
    glow_ok = true;
    defer if (glow_ok) unloadGlow();
    blur = try rl.loadShaderFromMemory(null, blur_fs); // raylib's default vertex shader
    defer rl.unloadShader(blur);
    blur_tap = rl.getShaderLocation(blur, "tap");

    planets = try sim.ballQuery(world, sim.Planet);
    defer ecs.query_fini(planets);
    planet_mesh = rl.genMeshSphere(1, planet_mesh_detail, planet_mesh_detail);
    defer rl.unloadMesh(planet_mesh);
    planet_material = try rl.loadMaterialDefault();
    defer rl.unloadMaterial(planet_material); // and the planet shader, once set
    planet_material.shader = try rl.loadShaderFromMemory(planet_vs, planet_fs);
    loc_star_count = rl.getShaderLocation(planet_material.shader, "starCount");
    loc_star_pos = rl.getShaderLocation(planet_material.shader, "starPos");
    loc_star_light = rl.getShaderLocation(planet_material.shader, "starLight");
    // raylib falls back to its default shader when ours doesn't compile or link
    // (e.g. only the ES 1.00 variant on web): fail instead of drawing unlit.
    if (planet_material.shader.id == rlGetShaderIdDefault() or loc_star_count < 0 or loc_star_pos < 0 or loc_star_light < 0)
        return error.PlanetShader;
    rl.setShaderValue(planet_material.shader, rl.getShaderLocation(planet_material.shader, "ambient"), &planet_ambient, .float);
    sky = try rl.loadShaderFromMemory(null, sky_fs);
    defer rl.unloadShader(sky);
    // Likewise: raylib's fallback shader would paint the whole screen white.
    if (sky.id == rlGetShaderIdDefault()) return error.SkyShader;
    // Not checked: with SKY_OFF they are compiled out, and -1 sets nothing.
    inline for (@typeInfo(@TypeOf(sky_loc)).@"struct".field_names) |name| @field(sky_loc, name) = rl.getShaderLocation(sky, name);

    if (web) {
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
    if (!std.meta.eql(screenSize(), view_size)) resize();
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
    const fwd = sim.normalize(cam.target - eye);
    const right = sim.normalize(sim.cross(fwd, .{ 0, 1, 0 }));
    view = .{ fwd, right, sim.cross(right, fwd) };

    frame_camera = .{
        .position = vec3(eye),
        .target = vec3(cam.target),
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = sim.OrbitCam.fovyFor(aspect()),
        .projection = .perspective,
    };
    if (glow_ok) glowPass(frame_camera);

    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.getColor(background));
    drawSky();
    rl.beginMode3D(frame_camera);
    forEachDrawn(cords, drawCord);
    forEachDrawn(balls, drawUnlitBall);
    lightPlanets();
    forEachDrawn(planets, drawPlanet);
    forEachDrawn(thrusters, drawThruster);
    // See-through last, so they don't hide what is behind them, and
    // without writing depth, so they don't hide each other either.
    rlDrawRenderBatchActive(); // the depth mask applies when a batch is drawn
    rlDisableDepthMask();
    drawStartRings();
    forEachDrawn(inputs, drawInputLink);
    forEachDrawn(mothers, drawRing);
    rlDrawRenderBatchActive();
    rlEnableDepthMask();
    rl.endMode3D();

    // The blurred glow, added on top.
    rl.beginBlendMode(.additive);
    if (glow_ok) for (0..glow_layers) |_| rl.drawTexturePro(glow[0].texture, flipped(glow[0]), .{ .x = 0, .y = 0, .width = @floatFromInt(screenSize()[0]), .height = @floatFromInt(screenSize()[1]) }, .{ .x = 0, .y = 0 }, 0, .white);
    rl.endBlendMode();
    // Labels last, so the glow doesn't blur them.
    forEachDrawn(labels, drawLabel);

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

fn hasArg(args: std.process.Args, want: []const u8) !bool {
    var it = try args.iterateAllocator(std.heap.page_allocator); // Windows needs one
    defer it.deinit();
    while (it.next()) |arg| if (std.mem.eql(u8, arg, want)) return true;
    return false;
}

fn screenSize() [2]i32 {
    return .{ rl.getScreenWidth(), rl.getScreenHeight() };
}

/// Width / height of `size`.
fn aspectOf(size: [2]i32) f32 {
    return @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(size[1]));
}

/// Width / height of the window.
fn aspect() f32 {
    return aspectOf(screenSize());
}

/// Follow a new window size (resized, rotated or a new viewport on web): the
/// camera's zoom and the glow textures. If those can't be made, the scene
/// goes without glow until the next resize tries again (not every frame:
/// raylib leaks a failed render texture's framebuffer).
fn resize() void {
    const size = screenSize();
    cam.reframe(aspectOf(view_size), aspectOf(size));
    view_size = size;
    // A drag in progress spans two layouts: start it afresh.
    touch = .{};
    if (glow_ok) unloadGlow();
    glow_ok = false;
    glow = loadGlow(size) catch return;
    glow_ok = true;
}

/// Glow textures for a window of `size`; none are left loaded on failure.
fn loadGlow(size: [2]i32) ![2]rl.RenderTexture2D {
    var out: [2]rl.RenderTexture2D = undefined;
    for (&out, 0..) |*g, i| {
        g.* = rl.loadRenderTexture(@divTrunc(size[0], glow_downscale), @divTrunc(size[1], glow_downscale)) catch |err| {
            for (out[0..i]) |done| rl.unloadRenderTexture(done);
            return err;
        };
        rl.setTextureFilter(g.texture, .bilinear); // smooth when scaled up
        // raylib makes render textures repeat; the blur's edge taps would
        // then pick up glow from the opposite edge.
        rl.setTextureWrap(g.texture, .clamp);
    }
    return out;
}

fn unloadGlow() void {
    for (glow) |g| rl.unloadRenderTexture(g);
}

/// Every ball in black, then cords, stars (a bit larger) and firing thrusters
/// into glow[0], then blurred there.
fn glowPass(camera: rl.Camera3D) void {
    rl.beginTextureMode(glow[0]);
    rl.clearBackground(.black);
    rl.beginMode3D(camera);
    // Every ball in black first, so planets in front of a star hide its glow.
    // A touch larger than the planet mesh, whose facets reach further out
    // than drawSphere's: no rim of glow over a planet's edge.
    forEachDrawn(balls, ballDrawer(occluder_grow, .black));
    forEachDrawn(cords, drawCord);
    forEachDrawn(stars, ballDrawer(glow_grow, null));
    forEachDrawn(thrusters, drawFiringThruster);
    rl.endMode3D();
    rl.endTextureMode();

    const tap_x = blur_spread / @as(f32, @floatFromInt(glow[0].texture.width));
    const tap_y = blur_spread / @as(f32, @floatFromInt(glow[0].texture.height));
    for (0..blur_rounds) |_| {
        blurInto(glow[0], glow[1], .{ tap_x, 0 });
        blurInto(glow[1], glow[0], .{ 0, tap_y });
    }
}

/// `src` blurred along `tap` (texture coordinates per tap) into `dst`.
fn blurInto(src: rl.RenderTexture2D, dst: rl.RenderTexture2D, tap: [2]f32) void {
    rl.beginTextureMode(dst);
    rl.beginShaderMode(blur);
    rl.setShaderValue(blur, blur_tap, &tap, .vec2);
    rl.drawTextureRec(src.texture, flipped(src), .{ .x = 0, .y = 0 }, .white);
    rl.endShaderMode();
    rl.endTextureMode();
}

/// A render texture's whole area, upside down: GL stores it bottom-up.
fn flipped(t: rl.RenderTexture2D) rl.Rectangle {
    return .{ .x = 0, .y = 0, .width = @floatFromInt(t.texture.width), .height = -@as(f32, @floatFromInt(t.texture.height)) };
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

/// A draw callback for balls: each at `scale` × its radius, in its own
/// colour or in `color`.
fn ballDrawer(comptime scale: f32, comptime color: ?rl.Color) fn (*ecs.iter_t, usize, sim.Vec3) void {
    return struct {
        fn draw(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
            const b = ecs.field(it, sim.Ball, 2).?[i];
            rl.drawSphere(vec3(at), b.radius * scale, color orelse rl.getColor(b.rgba));
        }
    }.draw;
}

/// Every ball but the planets (lit by `drawPlanet`): stars and anything else.
fn drawUnlitBall(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    if (ecs.has_id(it.world, it.entities()[i], ecs.id(sim.Planet))) return;
    ballDrawer(1, null)(it, i, at);
}

/// A child's glowing cord to her mother.
fn drawCord(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const to = drawnOf(sim.pairTarget(it, 2));
    const r = ecs.field(it, sim.Cord, 2).?[i].radius(sim.length(to - at));
    rl.drawCylinderEx(vec3(at), vec3(to), r, r, cord_sides, rl.getColor(cord_glow));
}

/// Dashes from a planet to its mother's ring (its sphere hides the start), in
/// its orbit ring's colour: thinner and brighter while it is off that ring.
fn drawInputLink(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const mother = sim.pairTarget(it, 2);
    const d = drawnOf(mother) - at;
    const len = sim.length(d) - ringRadius(mother);
    if (len <= 0) return;
    const ring = ecs.field(it, sim.Slot, 3).?[i].ring;
    const off = sim.ringGap(at, cam.target, ring) > ecs.field(it, sim.Ball, 4).?[i].radius;
    const base = rl.getColor(ring_colors[ring]);
    const width: f32, const color, const peak: f32 = if (off)
        .{ link_width * link_off_thin, rl.colorBrightness(base, link_off_brighten), link_off_alpha }
    else
        .{ link_width, base, link_alpha };
    const dir = sim.normalize(d);
    var t: f32 = 0;
    while (t < len) : (t += dash_len + dash_gap) {
        const a = at + dir * sim.splat(t);
        const b = at + dir * sim.splat(@min(t + dash_len, len));
        const k = sim.length((a + b) * sim.splat(0.5) - cam.target) / link_light_d0;
        const light = link_light_floor + (1 - link_light_floor) / (1 + k * k);
        drawSegment(a, b, width, rl.colorAlpha(color, peak * light));
    }
}

/// The rings the planets are laid out on (and drift from): faded dashed
/// ellipses in their theme colours, the current barycenter at a focus.
fn drawStartRings() void {
    for (0..sim.planet_rings) |ring| {
        const o = sim.ring_orbits[ring];
        const color = rl.colorAlpha(rl.getColor(ring_colors[ring]), start_ring_alpha);
        drawCircle(cam.target + o.center(), o.peri * sim.splat(o.a), o.side * sim.splat(o.b()), start_ring_segments, 2, start_ring_width, color);
    }
}

/// The starfield, added onto the cleared background. It turns with the
/// camera: sky.fs gets the camera's axes, scaled to the field of view.
fn drawSky() void {
    const tan_h = @tan(std.math.degreesToRadians(frame_camera.fovy / 2));
    const axes = [3][3]f32{ view[0], view[1] * sim.splat(tan_h * aspect()), view[2] * sim.splat(tan_h) };
    // gl_FragCoord counts framebuffer pixels (more than screen units on HiDPI);
    // the rectangle below is in screen units.
    const res = [2]f32{ @floatFromInt(rl.getRenderWidth()), @floatFromInt(rl.getRenderHeight()) };
    const size = screenSize();
    const time: f32 = @floatCast(rl.getTime());
    rl.setShaderValue(sky, sky_loc.resolution, &res, .vec2);
    rl.setShaderValue(sky, sky_loc.fwd, &axes[0], .vec3);
    rl.setShaderValue(sky, sky_loc.right, &axes[1], .vec3);
    rl.setShaderValue(sky, sky_loc.up, &axes[2], .vec3);
    rl.setShaderValue(sky, sky_loc.time, &time, .float);
    rl.beginShaderMode(sky);
    rl.beginBlendMode(.additive);
    rl.drawRectangle(0, 0, size[0], size[1], .white);
    rl.endBlendMode();
    rl.endShaderMode();
}

/// A body's name on screen beside its sphere; none behind the camera.
fn drawLabel(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    if (sim.dot(at - eye, view[0]) <= 0) return;
    const b = ecs.field(it, sim.Ball, 2).?[i];
    const text = ecs.field(it, sim.Label, 3).?[i].text;
    const center = rl.getWorldToScreen(vec3(at), frame_camera);
    // Just in front of the eye (zoomed in among the planets) a body projects
    // far off screen, beyond what @intFromFloat can hold: no label then.
    const w: f32 = @floatFromInt(screenSize()[0]);
    const h: f32 = @floatFromInt(screenSize()[1]);
    if (!(@abs(center.x) < 4 * w and @abs(center.y) < 4 * h)) return; // also skips NaN
    // The sphere's on-screen radius: project a point on its right edge.
    const edge = rl.getWorldToScreen(vec3(at + view[1] * sim.splat(b.radius)), frame_camera);
    const offset = @abs(edge.x - center.x) + label_gap;
    const output = ecs.has_id(it.world, it.entities()[i], ecs.pair(ecs.id(sim.Cord), ecs.Wildcard));
    const base: f32 = if (output) output_font_size else label_font_size;
    const zoom = @max(1, cam.zoomFactor());
    const size: i32 = @intFromFloat(@round(base * std.math.pow(f32, zoom, label_zoom_follow)));
    const text_w: f32 = @floatFromInt(rl.measureText(text, size));
    // Right of the sphere, or left of it where the right would run off
    // screen; never past the left edge either.
    const x = @max(0, if (center.x + offset + text_w > w) center.x - offset - text_w else center.x + offset);
    const y = center.y - @as(f32, @floatFromInt(size)) / 2;
    const xi: i32 = @intFromFloat(x);
    const yi: i32 = @intFromFloat(y);
    if (output) {
        const t = @max(1, @divTrunc(size, output_font_size));
        for (outline_offsets) |d| rl.drawText(text, xi + d[0] * t, yi + d[1] * t, size, rl.getColor(outline_color));
    }
    rl.drawText(text, xi, yi, size, rl.getColor(if (output) b.rgba else label_color));
}

/// Hands this frame's stars (drawn positions, colour × share of the mass) to
/// the planet shader.
fn lightPlanets() void {
    star_n = 0;
    star_mass_total = 0;
    forEachDrawn(stars, gatherStar);
    for (star_light[0..@intCast(star_n)]) |*l| {
        for (l) |*c| c.* *= planet_light_gain / star_mass_total;
    }
    const shader = planet_material.shader;
    rl.setShaderValue(shader, loc_star_count, &star_n, .int);
    rl.setShaderValueV(shader, loc_star_pos, &star_pos, .vec3, star_n);
    rl.setShaderValueV(shader, loc_star_light, &star_light, .vec3, star_n);
}

fn gatherStar(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    if (star_n == sim.max_stars) return;
    const mass = ecs.field(it, sim.Star, 3).?[i].mass;
    const c = rl.getColor(ecs.field(it, sim.Ball, 2).?[i].rgba);
    const k: usize = @intCast(star_n);
    star_pos[k] = .{ at[0], at[1], at[2] };
    star_light[k] = .{ @as(f32, @floatFromInt(c.r)) / 255 * mass, @as(f32, @floatFromInt(c.g)) / 255 * mass, @as(f32, @floatFromInt(c.b)) / 255 * mass };
    star_mass_total += mass;
    star_n += 1;
}

/// A planet's nozzle (and its beam while firing).
fn drawThruster(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const t = ecs.field(it, sim.Thruster, 3).?[i];
    const r = ecs.field(it, sim.Ball, 2).?[i].radius;
    if (t.on) drawFlame(at, -t.dir, r, t.time, 0) else drawNozzle(at, -t.dir, r, rl.getColor(nozzle_idle));
}

/// The glow pass's share: only a firing thruster glows.
fn drawFiringThruster(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const t = ecs.field(it, sim.Thruster, 3).?[i];
    if (t.on) drawFlame(at, -t.dir, ecs.field(it, sim.Ball, 2).?[i].radius, t.time, flame_glow);
}

/// A firing thruster: the nozzle and its beam, in the flame colour at
/// `brightness` (rl.colorBrightness: 0 as is, below 0 darker).
fn drawFlame(at: sim.Vec3, back: sim.Vec3, r: f32, time: f32, brightness: f32) void {
    const color = rl.colorBrightness(flameColor(time), brightness);
    drawNozzle(at, back, r, color);
    drawBeam(at, back, r, color, time);
}

/// A thin disc just proud of the surface, on the side `back` points to.
fn drawNozzle(at: sim.Vec3, back: sim.Vec3, r: f32, color: rl.Color) void {
    const disc_in = at + back * sim.splat(r * 0.96);
    const disc_out = at + back * sim.splat(r * 1.02);
    rl.drawCylinderEx(vec3(disc_in), vec3(disc_out), r * nozzle_size, r * nozzle_size, beam_sides, color);
}

/// The exhaust: a cone out of the nozzle along `back`, its length pulsing
/// with the firing `time`.
fn drawBeam(at: sim.Vec3, back: sim.Vec3, r: f32, color: rl.Color, time: f32) void {
    const pulse = @sin(time * beam_pulse_hz * std.math.tau);
    const start = at + back * sim.splat(r);
    const end = start + back * sim.splat(r * beam_length * (1 + beam_pulse * pulse));
    rl.drawCylinderEx(vec3(start), vec3(end), r * nozzle_size, r * 0.05, beam_sides, color);
}

/// Orange to near white and back, with the beam's pulse.
fn flameColor(time: f32) rl.Color {
    const k = 0.5 + 0.5 * @sin(time * beam_pulse_hz * std.math.tau);
    return rl.colorLerp(rl.getColor(flame), rl.getColor(flame_hot), k);
}

/// A planet: the lit unit sphere, scaled to its radius, in its colour.
fn drawPlanet(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const b = ecs.field(it, sim.Ball, 2).?[i];
    planet_material.maps[@backingInt(rl.MaterialMapIndex.albedo)].color = rl.getColor(b.rgba);
    const transform = rl.math.matrixMultiply(rl.math.matrixScale(b.radius, b.radius, b.radius), rl.math.matrixTranslate(at[0], at[1], at[2]));
    rl.drawMesh(planet_mesh, planet_material, transform);
}

/// A gray circle around a mother that always faces the camera.
fn drawRing(it: *ecs.iter_t, i: usize, at: sim.Vec3) void {
    const r = ecs.field(it, sim.Ball, 2).?[i].radius * ring_scale;
    // The camera's own axes (the direction to the mother itself may be vertical).
    drawCircle(at, view[1] * sim.splat(r), view[2] * sim.splat(r), ring_segments, 1, 0, rl.getColor(link_gray));
}

/// A circle (or an ellipse) around `center` spanned by the radius vectors `u` and `v`, in
/// `segments` straight pieces (`drawSegment`s of `width`): every one (`step`
/// 1) or every other (2, dashed).
fn drawCircle(center: sim.Vec3, u: sim.Vec3, v: sim.Vec3, segments: usize, step: usize, width: f32, color: rl.Color) void {
    var k: usize = 0;
    while (k < segments) : (k += step) {
        const a0 = std.math.tau * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(segments));
        const a1 = std.math.tau * @as(f32, @floatFromInt(k + 1)) / @as(f32, @floatFromInt(segments));
        const p0 = center + u * sim.splat(@cos(a0)) + v * sim.splat(@sin(a0));
        const p1 = center + u * sim.splat(@cos(a1)) + v * sim.splat(@sin(a1));
        drawSegment(p0, p1, width, color);
    }
}

/// A straight piece from `a` to `b`: a line, or a tube of radius `width` if
/// that is above 0.
fn drawSegment(a: sim.Vec3, b: sim.Vec3, width: f32, color: rl.Color) void {
    if (width > 0) rl.drawCylinderEx(vec3(a), vec3(b), width, width, tube_sides, color) else rl.drawLine3D(vec3(a), vec3(b), color);
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
extern fn rlGetShaderIdDefault() c_uint;
extern fn rlDisableDepthMask() void;
extern fn rlEnableDepthMask() void;

/// One right-aligned readout line; `line` 0 is the top.
fn drawStat(text: [:0]const u8, line: i32) void {
    const x = screenSize()[0] - stats_margin - rl.measureText(text, stats_font_size);
    rl.drawText(text, x, stats_margin + line * (stats_font_size + stats_line_gap), stats_font_size, rl.getColor(sand));
}
