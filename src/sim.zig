//! ECS state and systems. Knows nothing about rendering, so it runs under
//! `zig build test` without a window or GPU.
const std = @import("std");
const ecs = @import("zflecs");

// Star colours: the mother is the brightest (warm white), her children green.
const mother_white: u32 = 0xFFF1D6FF;
const child_green: u32 = 0x4FC27AFF;

// Star cluster (world units; masses only matter relative to each other). The
// mother is slightly smaller than her children but heavier, and is held home
// by a weak spring. Every cord is a spring that pulls both ends; every pair of
// stars pushes apart a little. Nothing damps it, so the cluster keeps
// breathing; the anchor lets the barycenter drift a little with it.
const mother_radius = 0.55;
const mother_mass = 1.0;
const child_radius = 0.7;
const child_mass = 0.5;
/// Cord rest length, mother center to child center.
const cord_rest = 2.2;
const cord_k = 1.2;
const home_k = 0.8;
/// Pair push: `repel / (r² + repel_soft)`, soft so close passes stay gentle.
const repel = 0.4;
const repel_soft = 0.25;
/// Children start this far off their rest length (fractions of it), so the
/// wobble starts uneven. They start level with the mother: a tilted cluster
/// would slowly turn the planets' orbits about its own axis.
const child_stretch = [_]f32{ 0.15, -0.1, 0.05 };
/// Most stars the `cluster` system handles (it works on all of them at once).
const max_stars = 16;

// Planets (the IPO's inputs): every star pulls each one with g·mass/r²,
// softened so a close pass stays finite. Each starts at the circular speed
// for that pull, around the barycenter, on a plane tilted a few degrees off xz
// about its own node line. The cluster is lumpy and wobbles, which would make
// the orbits wander chaotically; damping their radial motion (relative to the
// barycenter) settles them back toward circles, so they only drift a little.
const g = 55.0;
const planet_soft = 0.3;
/// Per second: how fast radial motion (relative to the barycenter) is damped.
const planet_settle = 0.1;
const PlanetStart = struct {
    /// Orbit radius around the barycenter.
    r: f32,
    /// Where on the orbit it starts, and the node line it tilts about
    /// (radians around y, from +x toward -z).
    phase: f32,
    node: f32,
    /// Plane tilt, radians.
    tilt: f32,
    radius: f32,
    rgba: u32,
};
// Colours from the tech-trio.svg palette (teal, orange, sand, light gray) and
// two lighter shades of the first two.
const planet_starts = [_]PlanetStart{
    .{ .r = 8.0, .phase = 0.0, .node = 0.0, .tilt = 0.06, .radius = 0.35, .rgba = 0x2E7E7EFF },
    .{ .r = 9.2, .phase = 2.4, .node = 1.1, .tilt = -0.04, .radius = 0.3, .rgba = 0xC87137FF },
    .{ .r = 10.4, .phase = 4.8, .node = 2.2, .tilt = 0.08, .radius = 0.4, .rgba = 0xC8A878FF },
    .{ .r = 11.6, .phase = 0.9, .node = 3.3, .tilt = -0.07, .radius = 0.3, .rgba = 0xD1D1D1FF },
    .{ .r = 12.8, .phase = 3.3, .node = 4.4, .tilt = 0.03, .radius = 0.45, .rgba = 0x5AA6A6FF },
    .{ .r = 14.0, .phase = 5.7, .node = 5.5, .tilt = -0.05, .radius = 0.35, .rgba = 0xE0A070FF },
};
/// How far the planets reach from the barycenter at the start, for framing.
pub const system_radius = blk: {
    var r: f32 = 0;
    for (planet_starts) |start| r = @max(r, start.r + start.radius);
    break :blk r;
};

/// How long `FrameStats` collects (seconds) before it updates its readout.
const stats_window = 0.5;

/// World-space vector: x right, y up, z toward the default camera.
/// A SIMD vector, so arithmetic is element-wise (`a + b`, `a * @as(Vec3, @splat(k))`).
pub const Vec3 = @Vector(3, f32);

fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

pub fn normalize(a: Vec3) Vec3 {
    return a / splat(length(a));
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// Mass-weighted mean of `points` (positions or velocities); null when the
/// masses sum to 0.
fn massCenter(points: []const Vec3, masses: []const f32) ?Vec3 {
    var sum = splat(0);
    var total: f32 = 0;
    for (points, masses) |p, m| {
        sum += p * splat(m);
        total += m;
    }
    return if (total > 0) sum / splat(total) else null;
}

pub fn splat(k: f32) Vec3 {
    return @splat(k);
}

pub const Position = struct { v: Vec3 };
pub const Velocity = struct { v: Vec3 };
/// `Position` at the start of the latest step, so rendering can interpolate
/// between fixed steps. Only moving entities need it.
pub const PrevPosition = struct { v: Vec3 };
/// Something to draw: a sphere. `rgba` is 0xRRGGBBAA so this module stays
/// free of raylib types.
pub const Ball = struct { radius: f32, rgba: u32 };
/// A star: takes part in the cluster forces, weighted by `mass`.
pub const Star = struct { mass: f32 };
/// Relationship `(Cord, mother)`: a spring of `rest` length between this star
/// and `mother` (also a `Star`). It pulls when stretched, pushes when squeezed.
/// At most one per star (safe builds check both rules).
pub const Cord = struct { rest: f32 };
/// A weak spring holds the star near `v` (the mother's anchor).
pub const Home = struct { v: Vec3 };
/// Tag on the entity `ecs.id(Barycenter)` (a singleton): its `Position` is the
/// mass-weighted center of all stars, and its `PrevPosition` (from `snapshot`,
/// like any moving entity) lets rendering interpolate it.
pub const Barycenter = struct {};
/// Singleton on `ecs.id(StarField)`: every star's position and mass after the
/// latest step (from `barycenter`, or `spawnCluster` before the first), so
/// `pull` reads them without a query.
pub const StarField = struct {
    n: usize = 0,
    pos: [max_stars]Vec3 = @splat(splat(0)),
    mass: [max_stars]f32 = @splat(0),
    /// The barycenter, and how fast it moves.
    center: Vec3 = splat(0),
    drift: Vec3 = splat(0),
};
/// Tag: a planet, pulled by every star.
pub const Planet = struct {};
/// Tag: the mother star (the IPO's process). Her children hang on cords;
/// planets are her inputs.
pub const Mother = struct {};
/// Relationship `(InputOf, mother)`: a planet feeds this mother star. It
/// only links them (for drawing and labels); gravity comes from every star.
pub const InputOf = struct {};

// zflecs declares ecs_set_id as returning entity_t, but flecs 4.1 returns void.
// Native ABIs ignore the bogus return value; on wasm, wasm-ld replaces the call
// with a trap. So declare it correctly and avoid ecs.set.
extern fn ecs_set_id(world: *ecs.world_t, entity: ecs.entity_t, component: ecs.id_t, size: usize, ptr: ?*const anyopaque) void;

fn set(world: *ecs.world_t, entity: ecs.entity_t, comptime T: type, val: T) void {
    ecs_set_id(world, entity, ecs.id(T), @sizeOf(T), &val);
}

/// `set` for the pair `(T, target)`, with `T`'s data.
fn setPair(world: *ecs.world_t, entity: ecs.entity_t, comptime T: type, target: ecs.entity_t, val: T) void {
    ecs_set_id(world, entity, ecs.pair(ecs.id(T), target), @sizeOf(T), &val);
}

/// Target of the pair matched by a `(Rel, Wildcard)` term. pair_second keeps
/// only the id's low 32 bits; get_alive restores the generation, or a target
/// on a recycled id would never match its entity.
pub fn pairTarget(it: *ecs.iter_t, index: i8) ecs.entity_t {
    return ecs.get_alive(it.world, ecs.pair_second(ecs.field_id(it, index)));
}

/// Registers components and systems on `world`.
pub fn register(world: *ecs.world_t) void {
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, PrevPosition);
    ecs.COMPONENT(world, Ball);
    ecs.COMPONENT(world, Star);
    ecs.COMPONENT(world, Cord);
    ecs.COMPONENT(world, Home);
    ecs.TAG(world, Barycenter);
    ecs.COMPONENT(world, StarField);
    ecs.TAG(world, Planet);
    ecs.TAG(world, Mother);
    ecs.TAG(world, InputOf);
    // Before any star exists: system terms on singletons need them to match.
    set(world, ecs.id(StarField), StarField, .{});
    set(world, ecs.id(Barycenter), Position, .{ .v = splat(0) });
    set(world, ecs.id(Barycenter), PrevPosition, .{ .v = splat(0) });
    addSystem(world, "snapshot", ecs.OnLoad, snapshot, &.{});
    // cluster and pull (PreUpdate) update velocity before move (OnUpdate)
    // uses it: semi-implicit Euler, which keeps orbits and springs from
    // gaining energy and spiralling out.
    addRunSystem(world, "cluster", ecs.PreUpdate, cluster, &.{
        .{ .id = ecs.id(Position), .inout = .In },
        .{ .id = ecs.id(Velocity), .inout = .InOut },
        .{ .id = ecs.id(Star), .inout = .In },
        .{ .id = ecs.pair(ecs.id(Cord), ecs.Wildcard), .inout = .In, .oper = .Optional },
        .{ .id = ecs.id(Home), .inout = .In, .oper = .Optional },
    });
    addSystem(world, "pull", ecs.PreUpdate, pull, &.{
        .{ .id = ecs.id(Planet), .inout = .InOutNone },
        .{ .id = ecs.id(StarField), .src = .{ .id = ecs.id(StarField) }, .inout = .In },
    });
    addSystem(world, "move", ecs.OnUpdate, move, &.{});
    // After move, so it describes the step just taken (and the next pull).
    addRunSystem(world, "barycenter", ecs.PostUpdate, barycenter, &.{
        .{ .id = ecs.id(Position), .inout = .In },
        .{ .id = ecs.id(Velocity), .inout = .In },
        .{ .id = ecs.id(Star), .inout = .In },
        .{ .id = ecs.id(Position), .src = .{ .id = ecs.id(Barycenter) }, .inout = .Out },
        .{ .id = ecs.id(StarField), .src = .{ .id = ecs.id(StarField) }, .inout = .Out },
    });
}

/// A system whose `run` sees every matching table in one call (it loops
/// `ecs.iter_next` itself), for forces between entities in different tables.
/// It writes other entities' data, so it never splits across workers.
fn addRunSystem(world: *ecs.world_t, name: [*:0]const u8, phase: ecs.entity_t, run: ecs.run_action_t, terms: []const ecs.term_t) void {
    var desc: ecs.system_desc_t = .{ .phase = phase, .run = run };
    @memcpy(desc.query.terms[0..terms.len], terms);
    _ = ecs.SYSTEM(world, name, &desc);
}

/// zflecs' `ADD_SYSTEM_WITH_FILTERS`, plus `multi_threaded` (which it can't
/// set): every system may split across `ecs.set_threads` workers.
fn addSystem(world: *ecs.world_t, name: [*:0]const u8, phase: ecs.entity_t, comptime f: anytype, filters: []const ecs.term_t) void {
    var desc = ecs.SYSTEM_DESC_WITH_FILTERS(f, filters);
    desc.phase = phase;
    desc.multi_threaded = true;
    _ = ecs.SYSTEM(world, name, &desc);
}

fn snapshot(positions: []const Position, prevs: []PrevPosition) void {
    for (positions, prevs) |p, *prev| prev.* = .{ .v = p.v };
}

// Field indices of the `cluster` and `barycenter` terms in `register`.
const cluster_pos = 0;
const cluster_vel = 1;
const cluster_star = 2;
const cluster_cord = 3;
const cluster_home = 4;
// pull's extra terms come after its own two params.
const pull_field = 3;
const bary_pos = 0;
const bary_vel = 1;
const bary_star = 2;
const bary_out = 3;
const bary_field = 4;

/// One star, as `cluster` gathers it.
const Body = struct {
    e: ecs.entity_t,
    pos: Vec3,
    mass: f32,
    /// Into its table, which stays put while the system runs: write through it.
    vel: *Vec3,
    cord: ?struct { mother: ecs.entity_t, rest: f32 },
    home: ?Vec3,
};

/// Cord springs, pair pushes and the home anchor, on every star at once.
fn cluster(it: *ecs.iter_t) callconv(.c) void {
    var bodies: [max_stars]Body = undefined;
    var n: usize = 0;
    while (ecs.iter_next(it)) {
        const cords = ecs.field(it, Cord, cluster_cord);
        const mother = if (cords != null) pairTarget(it, cluster_cord) else 0;
        const homes = ecs.field(it, Home, cluster_home);
        const ps = ecs.field(it, Position, cluster_pos).?;
        const vs = ecs.field(it, Velocity, cluster_vel).?;
        const ss = ecs.field(it, Star, cluster_star).?;
        for (it.entities(), ps, vs, ss, 0..) |e, p, *v, s, i| {
            if (n == max_stars) @panic("more stars than sim.max_stars");
            // A second (Cord, *) pair would match this table again and add the
            // star twice, doubling its forces.
            if (std.debug.runtime_safety) for (bodies[0..n]) |b| if (b.e == e) @panic("a star has more than one Cord");
            bodies[n] = .{
                .e = e,
                .pos = p.v,
                .mass = s.mass,
                .vel = &v.v,
                .cord = if (cords) |c| .{ .mother = mother, .rest = c[i].rest } else null,
                .home = if (homes) |h| h[i].v else null,
            };
            n += 1;
        }
    }
    const bs = bodies[0..n];

    var acc: [max_stars]Vec3 = @splat(splat(0));
    for (bs, 0..) |b, i| {
        if (b.home) |h| acc[i] += (h - b.pos) * splat(home_k / b.mass);
        if (b.cord) |cord| {
            for (bs, 0..) |m, j| {
                if (m.e != cord.mother) continue;
                const d = m.pos - b.pos;
                const r = length(d);
                if (r == 0) break;
                // Positive when stretched: pulls b toward m and m toward b.
                const f = d * splat(cord_k * (r - cord.rest) / r);
                acc[i] += f / splat(b.mass);
                acc[j] -= f / splat(m.mass);
                break;
            } else if (std.debug.runtime_safety) @panic("a Cord's mother is not a Star");
        }
        for (bs[i + 1 ..], i + 1..) |o, j| {
            const d = b.pos - o.pos;
            const r2 = dot(d, d);
            if (r2 == 0) continue;
            const f = d * splat(repel / ((r2 + repel_soft) * @sqrt(r2)));
            acc[i] += f / splat(b.mass);
            acc[j] -= f / splat(o.mass);
        }
    }
    for (bs, acc[0..n]) |b, a| b.vel.* += a * splat(it.delta_time);
}

/// Every star's pull on every planet.
fn pull(it: *ecs.iter_t, positions: []const Position, velocities: []Velocity) void {
    const f = &ecs.field(it, StarField, pull_field).?[0];
    const dt = it.delta_time;
    for (positions, velocities) |p, *v| {
        var a = fieldPull(f, p.v);
        // Damp motion toward or away from the barycenter (relative to its
        // own drift): purely radial, so it keeps angular momentum and
        // settles the orbit toward a circle.
        const out = p.v - f.center;
        const r2 = dot(out, out);
        if (r2 > 0) a -= out * splat(planet_settle * dot(v.v - f.drift, out) / r2);
        v.v += a * splat(dt);
    }
}

/// Acceleration every star in `f` gives a planet at `p`.
fn fieldPull(f: *const StarField, p: Vec3) Vec3 {
    var a = splat(0);
    for (f.pos[0..f.n], f.mass[0..f.n]) |s, m| {
        const d = s - p;
        const r2 = dot(d, d) + planet_soft * planet_soft;
        a += d * splat(g * m / (r2 * @sqrt(r2)));
    }
    return a;
}

/// The `StarField` (every star, the barycenter and its drift) and the
/// barycenter entity's `Position`.
fn barycenter(it: *ecs.iter_t) callconv(.c) void {
    var f: StarField = .{};
    var vels: [max_stars]Vec3 = undefined;
    var field: ?*StarField = null;
    var center: ?*Position = null;
    while (ecs.iter_next(it)) {
        field = &ecs.field(it, StarField, bary_field).?[0];
        center = &ecs.field(it, Position, bary_out).?[0];
        const ps = ecs.field(it, Position, bary_pos).?;
        const vs = ecs.field(it, Velocity, bary_vel).?;
        for (ps, vs, ecs.field(it, Star, bary_star).?) |p, v, s| {
            if (f.n == max_stars) @panic("more stars than sim.max_stars");
            f.pos[f.n] = p.v;
            f.mass[f.n] = s.mass;
            vels[f.n] = v.v;
            f.n += 1;
        }
    }
    if (f.n == 0) return;
    // Massless stars: keep the last center rather than divide by zero.
    f.center = massCenter(f.pos[0..f.n], f.mass[0..f.n]) orelse field.?.center;
    f.drift = massCenter(vels[0..f.n], f.mass[0..f.n]) orelse splat(0);
    field.?.* = f;
    center.?.v = f.center;
}

fn move(it: *ecs.iter_t, positions: []Position, velocities: []const Velocity) void {
    const dt = it.delta_time;
    for (positions, velocities) |*p, v| p.v += v.v * splat(dt);
}

/// Fixed simulation step. The sim always advances in these steps, whatever
/// the frame rate, so it behaves the same everywhere (and matches the tests).
pub const step_dt: f32 = 1.0 / 60.0;
/// Most steps one frame may run. A longer frame (tab hidden, window dragged,
/// debugger pause) drops the backlog instead of applying one huge `dt`, which
/// would fling planets out of orbit and overstretch the cords.
pub const max_steps_per_frame: u32 = 5;

/// Turns variable frame times into a count of fixed `step_dt` steps.
pub const FixedClock = struct {
    acc: f32 = 0,

    /// Adds `frame_dt` seconds; returns how many `step_dt` steps to run now.
    pub fn advance(self: *FixedClock, frame_dt: f32) u32 {
        self.acc += @max(frame_dt, 0);
        var n: u32 = 0;
        while (self.acc >= step_dt and n < max_steps_per_frame) : (n += 1) self.acc -= step_dt;
        if (self.acc >= step_dt) self.acc = 0; // too far behind: drop it
        return n;
    }

    /// How far the frame is past the latest step.
    /// @returns {f32} 0..1, the weight rendering gives the current `Position`
    /// over `PrevPosition`.
    pub fn alpha(self: FixedClock) f32 {
        return self.acc / step_dt;
    }
};

/// Per-frame work time (seconds spent before presenting), summarised as mean
/// and max over each `stats_window`. Per-frame numbers flicker too fast to read.
pub const FrameStats = struct {
    elapsed: f32 = 0,
    sum: f32 = 0,
    peak: f32 = 0,
    n: u32 = 0,
    /// Readout from the last complete window, in milliseconds.
    mean_ms: f32 = 0,
    max_ms: f32 = 0,

    /// Records one frame.
    /// @param {f32} frame_dt - the frame's interval in seconds; drives the window.
    /// @param {f32} work - seconds of work in that frame.
    pub fn add(self: *FrameStats, frame_dt: f32, work: f32) void {
        self.elapsed += frame_dt;
        self.sum += work;
        self.peak = @max(self.peak, work);
        self.n += 1;
        if (self.elapsed < stats_window) return;
        const n: f32 = @floatFromInt(self.n);
        self.* = .{ .mean_ms = 1000 * self.sum / n, .max_ms = 1000 * self.peak };
    }
};

/// Camera that circles a target point: drag turns it, the wheel zooms.
/// Pure math, so it lives here (and is tested) rather than in main.zig.
pub const OrbitCam = struct {
    target: Vec3 = .{ 0, 0, 0 },
    /// Turn around the y axis, radians; 0 looks from +z toward the target.
    yaw: f32 = 0,
    /// Height angle, radians; positive looks down from above.
    pitch: f32 = 0.5,
    distance: f32,
    /// Zoom limits for `distance`.
    min_distance: f32,
    max_distance: f32,

    /// Radians per pixel of mouse drag.
    const drag_speed = 0.005;
    /// Distance scales by `exp(-zoom_speed)` per wheel notch.
    const zoom_speed = 0.1;
    /// Just short of straight up or down, where the view's up vector flips.
    const max_pitch = std.math.pi / 2.0 - 0.05;
    // Distances, as multiples of the radius `framing` is given: at 45° fovy
    // and 16:9, frame_distance just fits the radius across with some margin.
    const frame_distance = 1.9;
    const frame_min = 0.3;
    const frame_max = 5;

    /// A camera on `target` that fits a scene `radius` across in its default
    /// view, and zooms from close to the center to far away.
    pub fn framing(target: Vec3, radius: f32) OrbitCam {
        return .{
            .target = target,
            .distance = radius * frame_distance,
            .min_distance = radius * frame_min,
            .max_distance = radius * frame_max,
        };
    }

    /// Mouse moved by (`dx`, `dy`) pixels with the button held: the scene
    /// follows the mouse sideways, and dragging down looks from higher up.
    pub fn drag(self: *OrbitCam, dx: f32, dy: f32) void {
        self.yaw = @mod(self.yaw - dx * drag_speed, std.math.tau);
        // In f32, @mod of a tiny negative rounds up to tau itself.
        if (self.yaw >= std.math.tau) self.yaw = 0;
        self.pitch = std.math.clamp(self.pitch + dy * drag_speed, -max_pitch, max_pitch);
    }

    /// `notches` of mouse wheel; positive zooms in.
    pub fn zoom(self: *OrbitCam, notches: f32) void {
        self.distance = std.math.clamp(self.distance * @exp(-notches * zoom_speed), self.min_distance, self.max_distance);
    }

    /// Two-finger pinch: the fingers are now `ratio` times as far apart as
    /// before, so the view zooms in by that ratio.
    pub fn pinch(self: *OrbitCam, ratio: f32) void {
        if (!(ratio > 0)) return; // also skips NaN
        self.distance = std.math.clamp(self.distance / ratio, self.min_distance, self.max_distance);
    }

    /// Camera position.
    pub fn eye(self: OrbitCam) Vec3 {
        const flat = @cos(self.pitch);
        return self.target + splat(self.distance) * Vec3{ flat * @sin(self.yaw), @sin(self.pitch), flat * @cos(self.yaw) };
    }
};

/// What one frame of pointer input does to the camera.
pub const Gesture = union(enum) {
    none,
    /// Turn by this many pixels.
    drag: [2]f32,
    /// Zoom by this ratio of finger spans (`OrbitCam.pinch`).
    pinch: f32,
};

/// One finger, as the platform reports it.
pub const Touch = struct { id: i32, x: f32, y: f32 };

/// Turns raw pointer input into gestures: one finger (or, with no finger
/// down, the left mouse button) drags, two fingers pinch. Fingers are followed by id, frame to
/// frame: a finger that just landed, or a pair that just changed (a finger
/// lifted or joined), does nothing until it moves on from there. Positions
/// are never compared across different fingers, so the camera never jumps.
pub const TouchSteer = struct {
    /// Fingers down last frame (the first two).
    before: [2]Touch = undefined,
    n_before: usize = 0,

    /// One frame: `touches` down now (raylib keeps the first ones), the left
    /// button and the mouse's movement.
    pub fn update(self: *TouchSteer, touches: []const Touch, mouse_down: bool, mouse_delta: [2]f32) Gesture {
        const n = @min(touches.len, 2);
        defer {
            @memcpy(self.before[0..n], touches[0..n]);
            self.n_before = n;
        }
        // Fingers first: on web, emscripten's GLFW also reports a touch as a
        // held left button, which would turn a pinch into a zero drag.
        if (n == 0) return if (mouse_down) .{ .drag = mouse_delta } else .none;
        if (n == 1 and self.n_before == 1 and touches[0].id == self.before[0].id)
            return .{ .drag = .{ touches[0].x - self.before[0].x, touches[0].y - self.before[0].y } };
        if (n == 2 and self.n_before == 2 and samePair(touches[0..2], &self.before)) {
            const was = span(self.before[0], self.before[1]);
            if (was > 0) return .{ .pinch = span(touches[0], touches[1]) / was };
        }
        return .none;
    }

    fn samePair(a: []const Touch, b: []const Touch) bool {
        return (a[0].id == b[0].id and a[1].id == b[1].id) or (a[0].id == b[1].id and a[1].id == b[0].id);
    }

    fn span(a: Touch, b: Touch) f32 {
        return std.math.hypot(a.x - b.x, a.y - b.y);
    }
};

pub const Cluster = struct { mother: ecs.entity_t, children: [child_stretch.len]ecs.entity_t };

/// The mother star at `at`, anchored there, and her children spread evenly
/// around her on cords, each started a little off rest so the cluster wobbles.
/// Also sets the `StarField` and `Barycenter` singletons for them, as the
/// `barycenter` system will after each step.
pub fn spawnCluster(world: *ecs.world_t, at: Vec3) Cluster {
    var c: Cluster = undefined;
    var f: StarField = .{ .n = 1 + child_stretch.len };
    c.mother = spawnStar(world, at, mother_mass, mother_radius, mother_white);
    ecs.add(world, c.mother, Mother);
    set(world, c.mother, Home, .{ .v = at });
    f.pos[0] = at;
    f.mass[0] = mother_mass;

    for (&c.children, child_stretch, 1..) |*child, stretch, i| {
        const angle = std.math.tau * @as(f32, @floatFromInt(i - 1)) / child_stretch.len;
        const r = cord_rest * (1 + stretch);
        const p = at + Vec3{ r * @cos(angle), 0, -r * @sin(angle) };
        child.* = spawnStar(world, p, child_mass, child_radius, child_green);
        setPair(world, child.*, Cord, c.mother, .{ .rest = cord_rest });
        f.pos[i] = p;
        f.mass[i] = child_mass;
    }
    f.center = massCenter(f.pos[0..f.n], f.mass[0..f.n]).?;
    set(world, ecs.id(StarField), StarField, f);
    set(world, ecs.id(Barycenter), Position, .{ .v = f.center });
    set(world, ecs.id(Barycenter), PrevPosition, .{ .v = f.center });
    return c;
}

/// The planets of `planet_starts`, around the current barycenter (so spawn
/// the cluster first), each an input of `mother`.
pub fn spawnPlanets(world: *ecs.world_t, mother: ecs.entity_t) [planet_starts.len]ecs.entity_t {
    var out: [planet_starts.len]ecs.entity_t = undefined;
    for (&out, planet_starts) |*e, start| e.* = spawnPlanet(world, mother, start);
    return out;
}

fn spawnPlanet(world: *ecs.world_t, mother: ecs.entity_t, start: PlanetStart) ecs.entity_t {
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    // Flat orbit first: outward and counter-clockwise (seen from above)
    // directions at `phase`. Then tilt both about the node line.
    const out_dir = Vec3{ @cos(start.phase), 0, -@sin(start.phase) };
    const along = Vec3{ -@sin(start.phase), 0, -@cos(start.phase) };
    const node = Vec3{ @cos(start.node), 0, -@sin(start.node) };
    const out = rotate(out_dir, node, start.tilt);
    const p = f.center + out * splat(start.r);
    // Circular speed for the stars' actual pull toward the center here: v²/r
    // = inward pull. (The cluster is not a point: its ring of children pulls
    // harder in its plane than the same mass at the barycenter would.)
    const speed = @sqrt(@max(0, -dot(fieldPull(f, p), out)) * start.r);

    const e = ecs.new_id(world);
    set(world, e, Position, .{ .v = p });
    set(world, e, PrevPosition, .{ .v = p });
    // Plus the barycenter's own drift, so the orbit is circular around it.
    set(world, e, Velocity, .{ .v = f.drift + rotate(along, node, start.tilt) * splat(speed) });
    ecs.add(world, e, Planet);
    ecs.add_pair(world, e, ecs.id(InputOf), mother);
    set(world, e, Ball, .{ .radius = start.radius, .rgba = start.rgba });
    return e;
}

/// `v` turned by `angle` radians about the unit `axis` (Rodrigues' formula).
fn rotate(v: Vec3, axis: Vec3, angle: f32) Vec3 {
    const c = @cos(angle);
    const s = @sin(angle);
    return v * splat(c) + cross(axis, v) * splat(s) + axis * splat(dot(axis, v) * (1 - c));
}

fn spawnStar(world: *ecs.world_t, at: Vec3, mass: f32, radius: f32, rgba: u32) ecs.entity_t {
    const e = ecs.new_id(world);
    set(world, e, Position, .{ .v = at });
    set(world, e, PrevPosition, .{ .v = at });
    set(world, e, Velocity, .{ .v = splat(0) });
    set(world, e, Star, .{ .mass = mass });
    set(world, e, Ball, .{ .radius = radius, .rgba = rgba });
    return e;
}

/// Query over every `(Rel, mother)` link to draw: term 0 = `Position`,
/// term 1 = optional `PrevPosition`, term 2 = the pair (target via
/// `pairTarget(it, 2)`). Rel is `Cord` (child stars) or `InputOf` (planets).
/// Caller owns it (`ecs.query_fini`).
pub fn linkQuery(world: *ecs.world_t, comptime Rel: type) !*ecs.query_t {
    return ecs.query_init(world, &.{
        .terms = [_]ecs.term_t{
            .{ .id = ecs.id(Position) },
            .{ .id = ecs.id(PrevPosition), .oper = .Optional },
            .{ .id = ecs.pair(ecs.id(Rel), ecs.Wildcard) },
        } ++ ecs.array(ecs.term_t, ecs.FLECS_TERM_COUNT_MAX - 3),
    });
}

/// Query over every mother star: term 0 = `Position`, term 1 = optional
/// `PrevPosition`, term 2 = `Ball`. Caller owns it (`ecs.query_fini`).
pub fn motherQuery(world: *ecs.world_t) !*ecs.query_t {
    return ecs.query_init(world, &.{
        .terms = [_]ecs.term_t{
            .{ .id = ecs.id(Position) },
            .{ .id = ecs.id(PrevPosition), .oper = .Optional },
            .{ .id = ecs.id(Ball) },
            .{ .id = ecs.id(Mother) },
        } ++ ecs.array(ecs.term_t, ecs.FLECS_TERM_COUNT_MAX - 4),
    });
}

/// Query over every star (what glows): term 0 = `Position`, term 1 =
/// optional `PrevPosition`, term 2 = `Ball`, as `ballQuery`.
/// Caller owns it (`ecs.query_fini`).
pub fn starQuery(world: *ecs.world_t) !*ecs.query_t {
    return ecs.query_init(world, &.{
        .terms = [_]ecs.term_t{
            .{ .id = ecs.id(Position) },
            .{ .id = ecs.id(PrevPosition), .oper = .Optional },
            .{ .id = ecs.id(Ball) },
            .{ .id = ecs.id(Star) },
        } ++ ecs.array(ecs.term_t, ecs.FLECS_TERM_COUNT_MAX - 4),
    });
}

/// Query over every drawable entity: term 0 = `Position`, term 1 = optional
/// `PrevPosition` (null field for static entities), term 2 = `Ball`.
/// Caller owns it (`ecs.query_fini`).
pub fn ballQuery(world: *ecs.world_t) !*ecs.query_t {
    return ecs.query_init(world, &.{
        .terms = [_]ecs.term_t{
            .{ .id = ecs.id(Position) },
            .{ .id = ecs.id(PrevPosition), .oper = .Optional },
            .{ .id = ecs.id(Ball) },
        } ++ ecs.array(ecs.term_t, ecs.FLECS_TERM_COUNT_MAX - 3),
    });
}

// ---------------------------------------------------------------- tests

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqualSlices = std.testing.expectEqualSlices;

fn step(world: *ecs.world_t, n: usize) void {
    for (0..n) |_| _ = ecs.progress(world, step_dt);
}

fn distance(a: Vec3, b: Vec3) f32 {
    return length(a - b);
}

fn positionOf(world: *ecs.world_t, e: ecs.entity_t) Vec3 {
    return ecs.get(world, e, Position).?.v;
}

test "move system integrates velocity over delta time" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);

    const e = ecs.new_id(world);
    set(world, e, Position, .{ .v = .{ 0, 0, 0 } });
    set(world, e, Velocity, .{ .v = .{ 10, -4, 2 } });

    _ = ecs.progress(world, 0.5);
    _ = ecs.progress(world, 0.5);

    try expect(distance(positionOf(world, e), .{ 10, -4, 2 }) < 1e-5);
}

test "entities without Velocity are not moved" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);

    const e = ecs.new_id(world);
    set(world, e, Position, .{ .v = .{ 3, 7, -1 } });
    _ = ecs.progress(world, 1.0);

    try expectEqual(Vec3{ 3, 7, -1 }, positionOf(world, e));
}

test "FixedClock: fractional frames carry over" {
    var clock: FixedClock = .{};
    try expectEqual(@as(u32, 0), clock.advance(0)); // raylib's first frame
    try expectEqual(@as(u32, 2), clock.advance(step_dt * 2.5));
    try expectEqual(@as(u32, 1), clock.advance(step_dt * 0.6)); // 0.5 + 0.6 carried
}

test "FixedClock: a long stall is capped and its backlog dropped" {
    var clock: FixedClock = .{};
    try expectEqual(max_steps_per_frame, clock.advance(3.0));
    try expectEqual(@as(u32, 0), clock.advance(0));
}

test "FixedClock: alpha is the leftover fraction of a step" {
    var clock: FixedClock = .{};
    _ = clock.advance(step_dt * 1.25);
    try expectApproxEqAbs(@as(f32, 0.25), clock.alpha(), 1e-4);
}

test "FrameStats: publishes mean and max once per window, then restarts" {
    var s: FrameStats = .{};
    s.add(0.2, 0.001);
    s.add(0.2, 0.003);
    try expectEqual(0, s.mean_ms); // window not full yet
    s.add(0.2, 0.002);
    try expectApproxEqAbs(2, s.mean_ms, 1e-4);
    try expectApproxEqAbs(3, s.max_ms, 1e-4);
    s.add(0.5, 0.0005); // a fresh window: the old peak is gone
    try expectApproxEqAbs(0.5, s.max_ms, 1e-4);
}

test "OrbitCam: eye sits `distance` from the target, above it for positive pitch" {
    var cam = OrbitCam.framing(.{ 1, 2, 3 }, 1);
    cam.yaw = 0.7;
    cam.pitch = 0.4;
    cam.distance = 10;
    const e = cam.eye();
    try expectApproxEqAbs(@as(f32, 10), distance(e, cam.target), 1e-4);
    try expectApproxEqAbs(@as(f32, 2 + 10 * @sin(0.4)), e[1], 1e-4);
    // Default yaw and level pitch look from +z.
    var level = OrbitCam.framing(.{ 0, 0, 0 }, 1);
    level.pitch = 0;
    try expect(distance(level.eye(), .{ 0, 0, level.distance }) < 1e-4);
}

test "OrbitCam: drag clamps pitch short of the poles and wraps yaw" {
    var cam = OrbitCam.framing(.{ 0, 0, 0 }, 5);
    cam.drag(0, 1e6);
    try expectEqual(OrbitCam.max_pitch, cam.pitch);
    cam.drag(0, -1e6);
    try expectEqual(-OrbitCam.max_pitch, cam.pitch);
    cam.drag(-std.math.tau / OrbitCam.drag_speed * 3.5, 0);
    try expect(cam.yaw >= 0 and cam.yaw < std.math.tau);
    cam.yaw = 0;
    cam.drag(1e-6, 0); // a sub-pixel step backwards from 0
    try expect(cam.yaw >= 0 and cam.yaw < std.math.tau);
}

test "OrbitCam: zoom moves in and out within its limits" {
    var cam = OrbitCam.framing(.{ 0, 0, 0 }, 5);
    const start = cam.distance;
    cam.zoom(1);
    try expect(cam.distance < start);
    cam.zoom(-2);
    try expect(cam.distance > start);
    cam.zoom(1000);
    try expectEqual(cam.min_distance, cam.distance);
    cam.zoom(-1000);
    try expectEqual(cam.max_distance, cam.distance);
}

test "cluster: stars stay together and the barycenter drifts only a little" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 1, 2, 3 });
    const home: Vec3 = .{ 1, 2, 3 };

    var drift: f32 = 0;
    for (0..2 * 60 * 60) |_| { // two minutes
        const before = positionOf(world, ecs.id(Barycenter));
        step(world, 1);
        const m = positionOf(world, c.mother);
        try expect(distance(m, home) < 0.4);
        var sum = m * splat(mother_mass);
        for (c.children) |child| {
            const p = positionOf(world, child);
            const r = distance(p, m);
            try expect(r > cord_rest - 0.4 and r < cord_rest + 0.6);
            sum += p * splat(child_mass);
        }
        // The singleton is the mass-weighted mean, and remembers the step before.
        const b = positionOf(world, ecs.id(Barycenter));
        try expect(distance(b, sum / splat(mother_mass + child_mass * @as(f32, child_stretch.len))) < 1e-4);
        try expectEqual(before, ecs.get(world, ecs.id(Barycenter), PrevPosition).?.v);
        drift = @max(drift, distance(b, home));
    }
    try expect(drift > 0.05 and drift < 0.3);
}

test "cords hold on recycled entity ids" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    // Freed ids come back with a higher generation in their upper bits.
    for (0..8) |_| ecs.delete(world, ecs.new_id(world));
    const c = spawnCluster(world, .{ 0, 0, 0 });
    try expect(c.mother >> 32 != 0);

    step(world, 10 * 60);
    for (c.children) |child| try expect(distance(positionOf(world, child), positionOf(world, c.mother)) < cord_rest + 0.6);
}

test "cord pulls when stretched and pushes when squeezed, on both ends" {
    for ([_]f32{ 1.5, 0.6 }) |stretch| {
        const world = ecs.init();
        defer _ = ecs.fini(world);
        register(world);
        const mother = spawnStar(world, .{ 0, 0, 0 }, mother_mass, mother_radius, mother_white);
        const child = spawnStar(world, .{ cord_rest * stretch, 0, 0 }, child_mass, child_radius, child_green);
        setPair(world, child, Cord, mother, .{ .rest = cord_rest });

        step(world, 10);
        const m = positionOf(world, mother);
        const r = distance(positionOf(world, child), m);
        if (stretch > 1) {
            try expect(r < cord_rest * stretch);
            try expect(m[0] > 0); // the mother is pulled toward the child
        } else {
            try expect(r > cord_rest * stretch);
            try expect(m[0] < 0); // and pushed away
        }
    }
}

test "planets stay near their orbits and planes for two minutes" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    const ps = spawnPlanets(world, c.mother);

    for (0..2 * 60 * 60) |_| {
        step(world, 1);
        const b = positionOf(world, ecs.id(Barycenter));
        for (ps, planet_starts) |e, start| {
            const d = positionOf(world, e) - b;
            // A 10-minute probe stayed within 0.81-1.26 radii and 0.09 radii
            // off the plane; these bounds leave room for that.
            const r = length(d) / start.r;
            try expect(r > 0.75 and r < 1.35);
            try expect(@abs(d[1]) / start.r < 0.15);
        }
    }
}

test "pull sums every star, weighted by mass" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    _ = spawnStar(world, .{ -5, 0, 0 }, 1, 0.5, 0);
    _ = spawnStar(world, .{ 5, 0, 0 }, 3, 0.5, 0);
    const p = ecs.new_id(world);
    set(world, p, Position, .{ .v = splat(0) });
    set(world, p, Velocity, .{ .v = splat(0) });
    ecs.add(world, p, Planet);

    // The first step publishes the StarField (spawnStar alone doesn't); the
    // second applies its pull.
    _ = ecs.progress(world, step_dt);
    const v0 = ecs.get(world, p, Velocity).?.v;
    _ = ecs.progress(world, step_dt);
    const v = ecs.get(world, p, Velocity).?.v - v0;
    // Net pull toward the heavier star: g·(3 - 1)/5² (softened), along +x.
    const r2 = 25 + planet_soft * planet_soft;
    try expectApproxEqAbs(@as(f32, g * 2 * 5 / (r2 * @sqrt(r2)) * step_dt), v[0], 1e-3);
    try expectEqual(@as(f32, 0), v[1]);
}

test "planets start at the circular speed for the stars' pull" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    const ps = spawnPlanets(world, c.mother);
    const b = positionOf(world, ecs.id(Barycenter));
    for (ps, planet_starts) |e, start| {
        const d = positionOf(world, e) - b;
        const v = ecs.get(world, e, Velocity).?.v;
        try expectApproxEqAbs(start.r, length(d), 1e-3);
        try expectApproxEqAbs(@as(f32, 0), dot(v, d), 1e-2); // tangential
        const inward = -dot(fieldPull(ecs.get(world, ecs.id(StarField), StarField).?, positionOf(world, e)), d) / length(d);
        try expectApproxEqAbs(inward * start.r, dot(v, v), 1e-2);
        // Tilted by start.tilt: the orbit's axis leans that far off +y.
        const axis = cross(d, v);
        try expectApproxEqAbs(@cos(start.tilt), axis[1] / length(axis), 1e-4);
    }
}

test "a planet spawned mid-wobble starts circular around the drifting barycenter" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    step(world, 200); // the barycenter is drifting by now
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    try expect(length(f.drift) > 1e-3);
    const p = spawnPlanets(world, c.mother)[0];
    const d = positionOf(world, p) - f.center;
    // No radial motion relative to the barycenter.
    try expectApproxEqAbs(@as(f32, 0), dot(ecs.get(world, p, Velocity).?.v - f.drift, d), 1e-2);
}

test "massless stars leave the barycenter where it was" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    _ = spawnStar(world, .{ 3, 0, 0 }, 0, 0.5, 0);
    step(world, 2);
    const b = positionOf(world, ecs.id(Barycenter));
    try expect(!std.math.isNan(b[0]));
    try expectEqual(Vec3{ 0, 0, 0 }, b);
}

test "orbits survive a 3 s frame stall" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    const ps = spawnPlanets(world, c.mother);

    var clock: FixedClock = .{};
    step(world, 30);
    for (0..clock.advance(3.0)) |_| _ = ecs.progress(world, step_dt);
    for (0..120) |_| {
        for (0..clock.advance(step_dt)) |_| _ = ecs.progress(world, step_dt);
        const b = positionOf(world, ecs.id(Barycenter));
        for (ps, planet_starts) |e, start| {
            const r = distance(positionOf(world, e), b) / start.r;
            try expect(r > 0.9 and r < 1.1);
        }
    }
}

test "snapshot keeps the position from before the step" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    const p = spawnPlanets(world, c.mother)[0];

    step(world, 10);
    const before = positionOf(world, p);
    step(world, 1);
    try expectEqual(before, ecs.get(world, p, PrevPosition).?.v);
    try expect(distance(before, positionOf(world, p)) > 0);
}

test "ballQuery yields every star and planet, all moving" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    _ = spawnPlanets(world, c.mother);

    const q = try ballQuery(world);
    defer ecs.query_fini(q);
    var n: usize = 0;
    var with_prev: usize = 0;
    var it = ecs.query_iter(world, q);
    while (ecs.query_next(&it)) {
        n += it.count();
        if (ecs.field(&it, PrevPosition, 1) != null) with_prev += it.count();
    }
    const total = 1 + child_stretch.len + planet_starts.len;
    try expectEqual(total, n);
    try expectEqual(total, with_prev);
}

test "worker threads give the same result as one thread" {
    const planets = 200;
    var runs: [2][planets]Vec3 = undefined;
    // zflecs allows one world at a time, so run them one after the other.
    for (&runs, [_]i32{ 0, 4 }) |*out, threads| {
        const world = ecs.init();
        defer _ = ecs.fini(world);
        register(world);
        if (threads > 0) ecs.set_threads(world, threads);
        const c = spawnCluster(world, .{ 0, 0, 0 });
        // Many planets, so pull splits across workers.
        var es: [planets]ecs.entity_t = undefined;
        for (&es, 0..) |*e, i| {
            const k: f32 = @floatFromInt(i);
            e.* = spawnPlanet(world, c.mother, .{ .r = 6 + k * 0.05, .phase = k, .node = k * 0.3, .tilt = 0.05, .radius = 0.1, .rgba = 0 });
        }
        step(world, 600);
        for (out, es) |*p, e| p.* = positionOf(world, e);
    }
    try expectEqualSlices(Vec3, &runs[0], &runs[1]);
}

test "OrbitCam: pinch zooms by the finger-distance ratio, within limits" {
    var cam = OrbitCam.framing(.{ 0, 0, 0 }, 5);
    const start = cam.distance;
    cam.pinch(2); // fingers spread to twice as far apart
    try expectApproxEqAbs(start / 2, cam.distance, 1e-4);
    cam.pinch(0.5);
    try expectApproxEqAbs(start, cam.distance, 1e-4);
    cam.pinch(1e6);
    try expectEqual(cam.min_distance, cam.distance);
    cam.pinch(0); // a degenerate gesture changes nothing
    try expectEqual(cam.min_distance, cam.distance);
}

test "links: children hang on the mother by cords, planets are her inputs" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    const ps = spawnPlanets(world, c.mother);
    const mq = try motherQuery(world);
    defer ecs.query_fini(mq);
    var mothers: usize = 0;
    var mother_ok = true;
    var mit = ecs.query_iter(world, mq);
    while (ecs.query_next(&mit)) {
        for (mit.entities()) |e| mother_ok = mother_ok and e == c.mother;
        mothers += mit.count();
    }
    try expect(mother_ok);
    try expectEqual(@as(usize, 1), mothers);

    // Stars (what glows): the mother and her children, no planets.
    const sq = try starQuery(world);
    defer ecs.query_fini(sq);
    var stars: usize = 0;
    var sit = ecs.query_iter(world, sq);
    while (ecs.query_next(&sit)) stars += sit.count();
    try expectEqual(1 + c.children.len, stars);

    const cords = try linkQuery(world, Cord);
    defer ecs.query_fini(cords);
    const inputs = try linkQuery(world, InputOf);
    defer ecs.query_fini(inputs);
    for ([_]*ecs.query_t{ cords, inputs }, [_]usize{ c.children.len, ps.len }) |q, want| {
        // Collect first, check after: a failed check mid-iteration would
        // leave the iterator unfinished.
        var n: usize = 0;
        var targets_ok = true;
        var it = ecs.query_iter(world, q);
        while (ecs.query_next(&it)) {
            targets_ok = targets_ok and pairTarget(&it, 2) == c.mother and ecs.field(&it, PrevPosition, 1) != null;
            n += it.count();
        }
        try expect(targets_ok);
        try expectEqual(want, n);
    }
}

test "TouchSteer: a finger drags by its own movement, from its second frame" {
    var t: TouchSteer = .{};
    const none: []const Touch = &.{};
    try expectEqual(Gesture.none, t.update(none, false, .{ 5, 5 }));
    try expectEqual(Gesture{ .drag = .{ 5, 5 } }, t.update(none, true, .{ 5, 5 }));
    try expectEqual(Gesture.none, t.update(&.{.{ .id = 7, .x = 100, .y = 100 }}, false, .{ 0, 0 })); // lands
    try expectEqual(Gesture{ .drag = .{ 3, -2 } }, t.update(&.{.{ .id = 7, .x = 103, .y = 98 }}, false, .{ 0, 0 }));
    // A stuck count (the finger gone, its last point still reported) is no drag.
    try expectEqual(Gesture{ .drag = .{ 0, 0 } }, t.update(&.{.{ .id = 7, .x = 103, .y = 98 }}, false, .{ 9, 9 }));
    // A new finger in the slot: its jump from the old one is no drag.
    try expectEqual(Gesture.none, t.update(&.{.{ .id = 8, .x = 400, .y = 10 }}, false, .{ 0, 0 }));
}

test "TouchSteer: pinch only within the same pair of fingers" {
    var t: TouchSteer = .{};
    const a: Touch = .{ .id = 1, .x = 0, .y = 0 };
    try expectEqual(Gesture.none, t.update(&.{ a, .{ .id = 2, .x = 100, .y = 0 } }, true, .{ 0, 0 }));
    // The left button reads as held during a touch on web: fingers win.
    try expectEqual(Gesture{ .pinch = 1.5 }, t.update(&.{ a, .{ .id = 2, .x = 150, .y = 0 } }, true, .{ 0, 0 }));
    // Finger 2 lifts and finger 3 slides into its slot: no 4x zoom jump.
    try expectEqual(Gesture.none, t.update(&.{ a, .{ .id = 3, .x = 600, .y = 0 } }, false, .{ 0, 0 }));
    try expectEqual(Gesture{ .pinch = 0.5 }, t.update(&.{ a, .{ .id = 3, .x = 300, .y = 0 } }, false, .{ 0, 0 }));
    // Down to one finger: it waits a frame before dragging.
    try expectEqual(Gesture.none, t.update(&.{a}, false, .{ 0, 0 }));
    try expectEqual(Gesture{ .drag = .{ 0, 0 } }, t.update(&.{a}, false, .{ 0, 0 }));
}
