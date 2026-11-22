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
/// Cord thickness at rest length, and how fast it changes with stretch:
/// radius ∝ (rest / len)^cord_bulge, within [min, max] × the rest radius.
const cord_radius = 0.125;
const cord_bulge = 3.0;
const cord_bulge_min = 0.4;
const cord_bulge_max = 3.0;
const home_k = 0.8;
/// Pair push: `repel / (r² + repel_soft)`, soft so close passes stay gentle.
const repel = 0.4;
const repel_soft = 0.25;
/// Children start this far off their rest length (fractions of it), so the
/// wobble starts uneven. They start level with the mother: a tilted cluster
/// would slowly turn the planets' orbits about its own axis.
const ChildData = struct { name: [:0]const u8, stretch: f32 };
const children = [_]ChildData{
    .{ .name = "native binary", .stretch = 0.15 },
    .{ .name = "index.wasm", .stretch = -0.1 },
    .{ .name = "Pages site", .stretch = 0.05 },
};
/// Most stars the `cluster` system handles (it works on all of them at once).
const max_stars = 16;

// Planets (the IPO's inputs): every star pulls each one with g·mass/r²,
// softened so a close pass stays finite. The cluster is lumpy and wobbles,
// which would make the orbits wander chaotically; damping their radial motion
// (relative to the barycenter) settles them back toward circles, so they only
// drift a little.
const g = 55.0;
const planet_soft = 0.3;
/// Per second: how fast radial motion (relative to the barycenter) is damped.
const planet_settle = 0.1;
// Layout (`planetSlot`): every planet the same size, on one ring, the same
// angle apart (360°/n) and at the same speed, on one plane tilted
// `planet_tilt` off xz. Only the colour differs. Past `planet_ring_max`
// planets the odd ones (0-based) move out to a ring `planet_ring_bump`
// further out; the even ones stay, and the angles stay even overall, so the
// two rings interleave (fully only for an even count: with an odd one the
// last and first planets are both inner, side by side).
const planet_ring_r = 9.0;
const planet_ring_bump = 2.5;
const planet_ring_max = 8;
const planet_radius = 0.35;
const planet_tilt = 0.06;
/// Every planet orbit tilts `planet_tilt` about this axis.
const planet_tilt_axis: Vec3 = .{ 1, 0, 0 };
// The sample IPO: this project's own build. The mother is `zig build` (the
// process, unlabelled); the planets are its inputs and her children its
// outputs. Planet colours: the tech-trio.svg palette (teal, orange, sand,
// light gray) with lighter, darker and nearby shades. Cycled past the table
// (tests spawn more).
const PlanetData = struct { name: [:0]const u8, rgba: u32 };
const planets = [_]PlanetData{
    .{ .name = "main.zig", .rgba = 0x2E7E7EFF },
    .{ .name = "sim.zig", .rgba = 0xC87137FF },
    .{ .name = "build.zig", .rgba = 0xC8A878FF },
    .{ .name = "build.zig.zon", .rgba = 0xD1D1D1FF },
    .{ .name = "raylib", .rgba = 0x5AA6A6FF },
    .{ .name = "flecs", .rgba = 0xE0A070FF },
    .{ .name = "emsdk", .rgba = 0x8FD0D0FF },
    .{ .name = "shell.html", .rgba = 0x9C5A1EFF },
    .{ .name = "blur.fs", .rgba = 0xE8D5B0FF },
    .{ .name = "stamp.sh", .rgba = 0x8A8A8AFF },
    .{ .name = "ci.yml", .rgba = 0xD9531EFF },
    .{ .name = "zig 0.17", .rgba = 0x5F8FB0FF },
};
/// Planets in the scene.
pub const planet_count = planets.len;
/// Rings the scene's planets start on: the default one, plus the bumped one
/// past `planet_ring_max`.
pub const planet_rings: u2 = if (planet_count > planet_ring_max) 2 else 1;
/// How far the planets reach from the barycenter, for framing.
pub const system_radius = planet_ring_r + (if (planet_count > planet_ring_max) planet_ring_bump else 0) + planet_radius;

/// How long `FrameStats` collects (seconds) before it updates its readout.
const stats_window = 0.5;

/// World-space vector: x right, y up, z toward the default camera.
/// A SIMD vector, so arithmetic is element-wise (`a + b`, `a * @as(Vec3, @splat(k))`).
pub const Vec3 = @Vector(3, f32);

pub fn dot(a: Vec3, b: Vec3) f32 {
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
pub const Cord = struct {
    rest: f32,

    /// Radius to draw the cord at its current `len`: like an elastic band it
    /// thickens fast when squeezed and thins when stretched, as
    /// (rest / len)^cord_bulge, clamped.
    pub fn radius(self: Cord, len: f32) f32 {
        if (!(len > 0)) return cord_radius * cord_bulge_max;
        const k = std.math.pow(f32, self.rest / len, cord_bulge);
        return cord_radius * std.math.clamp(k, cord_bulge_min, cord_bulge_max);
    }
};
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
/// A name to show next to a body (planets and child stars).
pub const Label = struct { text: [:0]const u8 };
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
    ecs.COMPONENT(world, Label);
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
    // Distances, as multiples of the radius `framing` is given. In landscape
    // frame_distance fits the tilted scene top to bottom with some margin;
    // `fitDistance` backs off further where the width is the tighter fit.
    const frame_distance = 2.2;
    const frame_min = 0.3;
    const frame_max = 5;

    /// The scene radius across the screen's horizontal view gets at least
    /// this much margin (in portrait, the full ring spans the narrow side).
    const frame_fit = 1.1;

    /// A camera on `target` that fits a scene `radius` in its default view of
    /// a screen `aspect` (width / height) wide, and zooms from close to the
    /// center to far away.
    pub fn framing(target: Vec3, radius: f32, aspect: f32) OrbitCam {
        return .{
            .target = target,
            .distance = fitDistance(radius, aspect),
            .min_distance = radius * frame_min,
            .max_distance = radius * frame_max,
        };
    }

    /// Default distance for a scene `radius` on a screen `aspect` wide: far
    /// enough that it fits across the horizontal view too.
    fn fitDistance(radius: f32, aspect: f32) f32 {
        const half_fovx = scaleHalfAngle(std.math.degreesToRadians(fovyFor(aspect) / 2), aspect);
        return radius * @max(frame_distance, frame_fit / @tan(half_fovx));
    }

    /// The screen's aspect went from `from` to `to`: keep the zoom relative
    /// to the default framing, so a flip to portrait backs off just enough.
    pub fn reframe(self: *OrbitCam, from: f32, to: f32) void {
        const k = fitDistance(1, to) / fitDistance(1, from);
        // The limits scale too, so flipping back restores the same zoom.
        self.distance *= k;
        self.min_distance *= k;
        self.max_distance *= k;
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

    /// View angle across the narrower side of the screen, degrees.
    pub const narrow_fov = 45.0;

    /// Vertical field of view (what raylib's Camera3D takes) for a screen
    /// `aspect` (width / height) wide, so the narrower side always spans
    /// `narrow_fov`: framing then fits the scene the same way in landscape
    /// and portrait.
    pub fn fovyFor(aspect: f32) f32 {
        if (aspect >= 1) return narrow_fov;
        return std.math.radiansToDegrees(2 * scaleHalfAngle(std.math.degreesToRadians(narrow_fov / 2.0), 1 / aspect));
    }

    /// The half view angle across a side `k` times as long as the one that
    /// `half` spans (same distance from the eye).
    fn scaleHalfAngle(half: f32, k: f32) f32 {
        return std.math.atan(@tan(half) * k);
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

pub const Cluster = struct { mother: ecs.entity_t, children: [children.len]ecs.entity_t };

/// The mother star at `at`, anchored there, and her children spread evenly
/// around her on cords, each started a little off rest so the cluster wobbles.
/// Also sets the `StarField` and `Barycenter` singletons for them, as the
/// `barycenter` system will after each step.
pub fn spawnCluster(world: *ecs.world_t, at: Vec3) Cluster {
    var c: Cluster = undefined;
    var f: StarField = .{ .n = 1 + children.len };
    c.mother = spawnStar(world, at, mother_mass, mother_radius, mother_white);
    ecs.add(world, c.mother, Mother);
    set(world, c.mother, Home, .{ .v = at });
    f.pos[0] = at;
    f.mass[0] = mother_mass;

    for (&c.children, children, 1..) |*child, data, i| {
        const angle = std.math.tau * @as(f32, @floatFromInt(i - 1)) / children.len;
        const r = cord_rest * (1 + data.stretch);
        const p = at + Vec3{ r * @cos(angle), 0, -r * @sin(angle) };
        child.* = spawnStar(world, p, child_mass, child_radius, child_green);
        setPair(world, child.*, Cord, c.mother, .{ .rest = cord_rest });
        set(world, child.*, Label, .{ .text = data.name });
        f.pos[i] = p;
        f.mass[i] = child_mass;
    }
    f.center = massCenter(f.pos[0..f.n], f.mass[0..f.n]).?;
    set(world, ecs.id(StarField), StarField, f);
    set(world, ecs.id(Barycenter), Position, .{ .v = f.center });
    set(world, ecs.id(Barycenter), PrevPosition, .{ .v = f.center });
    return c;
}

/// Where planet `i` of `n` orbits.
const PlanetSlot = struct {
    /// 0: the default ring, 1: the bumped one.
    ring: u1,
    r: f32,
    /// Unit vectors from the barycenter: outward to the planet, and its
    /// direction of travel (counter-clockwise seen from above), both on the
    /// tilted orbit plane.
    dir: Vec3,
    along: Vec3,
};

fn planetSlot(i: usize, n: usize) PlanetSlot {
    const ring: u1 = @intFromBool(n > planet_ring_max and i % 2 == 1);
    const phase = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
    return .{
        .ring = ring,
        .r = ringRadius(ring),
        .dir = ringDir(phase),
        .along = ringDir(phase + std.math.pi / 2.0),
    };
}

/// Radius of planet ring 0 (default) or 1 (bumped).
pub fn ringRadius(ring: u1) f32 {
    return planet_ring_r + @as(f32, @floatFromInt(ring)) * planet_ring_bump;
}

/// Unit vector at `angle` on the (tilted) planet plane: 0 along +x, then
/// counter-clockwise seen from above.
pub fn ringDir(angle: f32) Vec3 {
    return rotate(.{ @cos(angle), 0, -@sin(angle) }, planet_tilt_axis, planet_tilt);
}

/// `n` planets laid out by `planetSlot` around the current barycenter (so
/// spawn the cluster first), each an input of `mother`. Each ring's planets
/// share one speed: the circular speed for the stars' mean inward pull on
/// that ring (the cluster is lumpy, so the pull varies a little around it).
pub fn spawnPlanets(world: *ecs.world_t, mother: ecs.entity_t, comptime n: usize) [n]ecs.entity_t {
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    var inward = [2]f32{ 0, 0 }; // summed inward pull, per ring
    var on_ring = [2]f32{ 0, 0 };
    for (0..n) |i| {
        const slot = planetSlot(i, n);
        inward[slot.ring] += -dot(fieldPull(f, f.center + slot.dir * splat(slot.r)), slot.dir);
        on_ring[slot.ring] += 1;
    }
    var out: [n]ecs.entity_t = undefined;
    for (&out, 0..) |*e, i| {
        const slot = planetSlot(i, n);
        // v²/r = inward pull; plus the barycenter's own drift, so the orbit is
        // circular around it.
        const speed = @sqrt(@max(0, inward[slot.ring] / on_ring[slot.ring]) * slot.r);
        e.* = spawnPlanet(world, mother, f.center + slot.dir * splat(slot.r), f.drift + slot.along * splat(speed), planets[i % planets.len]);
    }
    return out;
}

fn spawnPlanet(world: *ecs.world_t, mother: ecs.entity_t, p: Vec3, v: Vec3, data: PlanetData) ecs.entity_t {
    const e = ecs.new_id(world);
    set(world, e, Position, .{ .v = p });
    set(world, e, PrevPosition, .{ .v = p });
    set(world, e, Velocity, .{ .v = v });
    ecs.add(world, e, Planet);
    ecs.add_pair(world, e, ecs.id(InputOf), mother);
    set(world, e, Ball, .{ .radius = planet_radius, .rgba = data.rgba });
    set(world, e, Label, .{ .text = data.name });
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

/// Query over every drawable entity, or only those with `Tag` (`Star`,
/// `Mother`): term 0 = `Position`, term 1 = optional `PrevPosition` (null
/// field for static entities), term 2 = `Ball`. Caller owns it
/// (`ecs.query_fini`).
pub fn ballQuery(world: *ecs.world_t, comptime Tag: ?type) !*ecs.query_t {
    var desc: ecs.query_desc_t = .{};
    desc.terms[0] = .{ .id = ecs.id(Position) };
    desc.terms[1] = .{ .id = ecs.id(PrevPosition), .oper = .Optional };
    desc.terms[2] = .{ .id = ecs.id(Ball) };
    if (Tag) |T| desc.terms[3] = .{ .id = ecs.id(T) };
    return ecs.query_init(world, &desc);
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

/// The cluster and `n` planets: the scene, for tests.
fn spawnScene(world: *ecs.world_t, comptime n: usize) struct { c: Cluster, ps: [n]ecs.entity_t } {
    const c = spawnCluster(world, .{ 0, 0, 0 });
    return .{ .c = c, .ps = spawnPlanets(world, c.mother, n) };
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
    var cam = OrbitCam.framing(.{ 1, 2, 3 }, 1, 800.0 / 450.0);
    cam.yaw = 0.7;
    cam.pitch = 0.4;
    cam.distance = 10;
    const e = cam.eye();
    try expectApproxEqAbs(@as(f32, 10), distance(e, cam.target), 1e-4);
    try expectApproxEqAbs(@as(f32, 2 + 10 * @sin(0.4)), e[1], 1e-4);
    // Default yaw and level pitch look from +z.
    var level = OrbitCam.framing(.{ 0, 0, 0 }, 1, 800.0 / 450.0);
    level.pitch = 0;
    try expect(distance(level.eye(), .{ 0, 0, level.distance }) < 1e-4);
}

test "OrbitCam: drag clamps pitch short of the poles and wraps yaw" {
    var cam = OrbitCam.framing(.{ 0, 0, 0 }, 5, 800.0 / 450.0);
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
    var cam = OrbitCam.framing(.{ 0, 0, 0 }, 5, 800.0 / 450.0);
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
        try expect(distance(b, sum / splat(mother_mass + child_mass * @as(f32, children.len))) < 1e-4);
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
    const sc = spawnScene(world, planet_count);

    for (0..2 * 60 * 60) |_| {
        step(world, 1);
        const b = positionOf(world, ecs.id(Barycenter));
        for (sc.ps, 0..) |e, i| {
            const d = positionOf(world, e) - b;
            // The stars' pull (and the radial damping) move them, so they drift
            // (a 2-minute probe: 0.89-1.14
            // radii, 0.10 radii off the plane; 10 minutes: up to 1.34 and 0.15).
            const slot_r = planetSlot(i, planet_count).r;
            const r = length(d) / slot_r;
            try expect(r > 0.85 and r < 1.2);
            try expect(@abs(rotate(d, planet_tilt_axis, -planet_tilt)[1]) / slot_r < 0.13);
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

test "planets: one even ring (or a bumped one for odd planets past the max), same size and speed per ring, one plane, colours differ" {
    inline for (.{ planet_count, planet_ring_max + 2 }) |n| {
        const world = ecs.init();
        defer _ = ecs.fini(world);
        register(world);
        const sc = spawnScene(world, n);
        const f = ecs.get(world, ecs.id(StarField), StarField).?;
        const normal = rotate(.{ 0, 1, 0 }, planet_tilt_axis, planet_tilt);
        var speed = [2]?f32{ null, null };
        var inward = [2]f32{ 0, 0 };
        var on_ring = [2]f32{ 0, 0 };
        for (sc.ps, 0..) |e, i| {
            const slot = planetSlot(i, n);
            try expectEqual(@as(u1, @intFromBool(n > planet_ring_max and i % 2 == 1)), slot.ring);
            const d = positionOf(world, e) - f.center;
            const v = ecs.get(world, e, Velocity).?.v - f.drift;
            try expectApproxEqAbs(planet_ring_r + @as(f32, @floatFromInt(slot.ring)) * planet_ring_bump, length(d), 1e-3);
            // The same angle apart, on one tilted plane.
            const phase = std.math.tau * @as(f32, @floatFromInt(i)) / n;
            try expect(distance(normalize(d), rotate(.{ @cos(phase), 0, -@sin(phase) }, planet_tilt_axis, planet_tilt)) < 1e-4);
            try expectApproxEqAbs(@as(f32, 0), dot(v, d), 1e-2); // tangential
            try expect(distance(normalize(cross(d, v)), normal) < 1e-4); // on the plane
            // One speed per ring.
            if (speed[slot.ring]) |s0| try expectApproxEqAbs(s0, length(v), 1e-4) else speed[slot.ring] = length(v);
            inward[slot.ring] += -dot(fieldPull(f, positionOf(world, e)), normalize(d));
            on_ring[slot.ring] += 1;
            const b = ecs.get(world, e, Ball).?;
            try expectEqual(@as(f32, planet_radius), b.radius);
            try expectEqual(planets[i % planets.len].rgba, b.rgba);
            try std.testing.expectEqualStrings(planets[i % planets.len].name, ecs.get(world, e, Label).?.text);
        }
        // That speed is circular for the ring's mean inward pull: v² = pull · r.
        for (0..2) |ring| if (speed[ring]) |v| {
            const r = planet_ring_r + @as(f32, @floatFromInt(ring)) * planet_ring_bump;
            try expectApproxEqAbs(inward[ring] / on_ring[ring] * r, v * v, 1e-2);
        };
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
    const p = spawnPlanets(world, c.mother, 1)[0];
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
    const sc = spawnScene(world, planet_count);

    var clock: FixedClock = .{};
    step(world, 30);
    for (0..clock.advance(3.0)) |_| _ = ecs.progress(world, step_dt);
    for (0..120) |_| {
        for (0..clock.advance(step_dt)) |_| _ = ecs.progress(world, step_dt);
        const b = positionOf(world, ecs.id(Barycenter));
        for (sc.ps, 0..) |e, i| {
            const r = distance(positionOf(world, e), b) / planetSlot(i, planet_count).r;
            try expect(r > 0.9 and r < 1.1);
        }
    }
}

test "snapshot keeps the position from before the step" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const p = spawnScene(world, 1).ps[0];

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
    _ = spawnScene(world, planet_count);

    const q = try ballQuery(world, null);
    defer ecs.query_fini(q);
    var n: usize = 0;
    var with_prev: usize = 0;
    var it = ecs.query_iter(world, q);
    while (ecs.query_next(&it)) {
        n += it.count();
        if (ecs.field(&it, PrevPosition, 1) != null) with_prev += it.count();
    }
    const total = 1 + children.len + planet_count;
    try expectEqual(total, n);
    try expectEqual(total, with_prev);
}

test "worker threads give the same result as one thread" {
    const many = 200;
    var runs: [2][many]Vec3 = undefined;
    // zflecs allows one world at a time, so run them one after the other.
    for (&runs, [_]i32{ 0, 4 }) |*out, threads| {
        const world = ecs.init();
        defer _ = ecs.fini(world);
        register(world);
        if (threads > 0) ecs.set_threads(world, threads);
        // Many planets (two rings), so pull splits across workers.
        const sc = spawnScene(world, many);
        step(world, 600);
        for (out, sc.ps) |*p, e| p.* = positionOf(world, e);
    }
    try expectEqualSlices(Vec3, &runs[0], &runs[1]);
}

test "OrbitCam: pinch zooms by the finger-distance ratio, within limits" {
    var cam = OrbitCam.framing(.{ 0, 0, 0 }, 5, 800.0 / 450.0);
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
    const sc = spawnScene(world, planet_count);
    const mq = try ballQuery(world, Mother);
    defer ecs.query_fini(mq);
    var mothers: usize = 0;
    var mother_ok = true;
    var mit = ecs.query_iter(world, mq);
    while (ecs.query_next(&mit)) {
        for (mit.entities()) |e| mother_ok = mother_ok and e == sc.c.mother;
        mothers += mit.count();
    }
    try expect(mother_ok);
    try expectEqual(@as(usize, 1), mothers);

    // Stars (what glows): the mother and her children, no planets.
    const sq = try ballQuery(world, Star);
    defer ecs.query_fini(sq);
    var stars: usize = 0;
    var sit = ecs.query_iter(world, sq);
    while (ecs.query_next(&sit)) stars += sit.count();
    try expectEqual(1 + sc.c.children.len, stars);

    const cords = try linkQuery(world, Cord);
    defer ecs.query_fini(cords);
    const inputs = try linkQuery(world, InputOf);
    defer ecs.query_fini(inputs);
    for ([_]*ecs.query_t{ cords, inputs }, [_]usize{ sc.c.children.len, sc.ps.len }) |q, want| {
        // Collect first, check after: a failed check mid-iteration would
        // leave the iterator unfinished.
        var n: usize = 0;
        var targets_ok = true;
        var it = ecs.query_iter(world, q);
        while (ecs.query_next(&it)) {
            targets_ok = targets_ok and pairTarget(&it, 2) == sc.c.mother and ecs.field(&it, PrevPosition, 1) != null;
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

test "Cord.radius: thicker when squeezed, thinner when stretched, clamped" {
    const c: Cord = .{ .rest = 2 };
    try expectApproxEqAbs(@as(f32, cord_radius), c.radius(2), 1e-6);
    try expectEqual(@as(f32, cord_radius * cord_bulge_max), c.radius(1)); // (2/1)^3 = 8, clamped
    try expectApproxEqAbs(@as(f32, cord_radius / 1.728), c.radius(2.4), 1e-5); // (2/2.4)^3
    try expectEqual(@as(f32, cord_radius * cord_bulge_min), c.radius(100));
    try expectEqual(@as(f32, cord_radius * cord_bulge_max), c.radius(0));
}

test "OrbitCam.fovyFor: 45 degrees across the narrower side" {
    try expectEqual(@as(f32, OrbitCam.narrow_fov), OrbitCam.fovyFor(800.0 / 450.0));
    try expectEqual(@as(f32, OrbitCam.narrow_fov), OrbitCam.fovyFor(1));
    // Portrait: the horizontal angle is the narrow one and stays 45 degrees.
    const fovy = OrbitCam.fovyFor(450.0 / 800.0);
    const half_x = std.math.atan(@tan(std.math.degreesToRadians(fovy / 2)) * 450 / 800);
    try expectApproxEqAbs(@as(f32, 22.5), std.math.radiansToDegrees(half_x), 1e-3);
    try expect(fovy > 70 and fovy < 75);
}

test "OrbitCam: portrait framing backs off so the scene fits across" {
    const land = OrbitCam.framing(.{ 0, 0, 0 }, 10, 800.0 / 450.0);
    const port = OrbitCam.framing(.{ 0, 0, 0 }, 10, 450.0 / 800.0);
    try expectApproxEqAbs(@as(f32, 10 * OrbitCam.frame_distance), land.distance, 1e-4);
    // Portrait: 45 degrees across; the radius plus margin fits half of it.
    try expectApproxEqAbs(@as(f32, 10 * OrbitCam.frame_fit / @tan(std.math.degreesToRadians(22.5))), port.distance, 1e-3);
    // Flipping keeps a user's zoom relative to the default.
    var cam = land;
    cam.zoom(2);
    const zoomed = cam.distance / land.distance;
    cam.reframe(800.0 / 450.0, 450.0 / 800.0);
    try expectApproxEqAbs(zoomed, cam.distance / port.distance, 1e-4);
    // Zoomed all the way out, flipping there and back keeps the zoom.
    cam.zoom(-1000);
    const far = cam.distance;
    cam.reframe(450.0 / 800.0, 800.0 / 450.0);
    cam.reframe(800.0 / 450.0, 450.0 / 800.0);
    try expectApproxEqAbs(far, cam.distance, 1e-3);
}

test "labels: every planet and child star, never the mother" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    try expect(!ecs.has_id(world, sc.c.mother, ecs.id(Label)));
    for (sc.c.children, children) |e, data| try std.testing.expectEqualStrings(data.name, ecs.get(world, e, Label).?.text);

    // ballQuery with Label finds exactly those, with Ball at term 2 and
    // Label at term 3 for the renderer.
    const q = try ballQuery(world, Label);
    defer ecs.query_fini(q);
    var n: usize = 0;
    var it = ecs.query_iter(world, q);
    while (ecs.query_next(&it)) n += it.count();
    try expectEqual(planet_count + children.len, n);
}

test "ringDir/ringRadius trace the rings planets start on" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    for (sc.ps, 0..) |e, i| {
        const slot = planetSlot(i, planet_count);
        const phase = std.math.tau * @as(f32, @floatFromInt(i)) / planet_count;
        try expect(distance(positionOf(world, e), f.center + ringDir(phase) * splat(ringRadius(slot.ring))) < 1e-3);
    }
    try expectEqual(@as(u2, 2), planet_rings); // 12 planets: two rings
}
