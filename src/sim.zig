//! ECS state and systems. Knows nothing about rendering, so it runs under
//! `zig build test` without a window or GPU.
const std = @import("std");
const ecs = @import("zflecs");

// Ball colours from the tech-trio.svg palette (0xRRGGBBAA); render-only
// colours live in main.zig and web/shell.html.
const orange: u32 = 0xC87137FF;
const teal: u32 = 0x2E7E7EFF;
// Star colours: the mother is the brightest (warm white), her children green.
const mother_white: u32 = 0xFFF1D6FF;
const child_green: u32 = 0x4FC27AFF;

// Demo ball sizes, as fractions of the orbit radius.
const attractor_size = 0.16;
const orbiter_size = 0.066;

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
/// Children start this far off their rest length (fractions of it) and this
/// high above the mother's plane, so the wobble starts uneven.
const child_starts = [_]struct { stretch: f32, lift: f32 }{
    .{ .stretch = 0.15, .lift = 0.3 },
    .{ .stretch = -0.1, .lift = -0.25 },
    .{ .stretch = 0.05, .lift = 0.1 },
};
const cluster_mass = mother_mass + child_mass * @as(f32, child_starts.len);
/// Roughly how far the cluster reaches from its barycenter, for framing it.
pub const cluster_radius = cord_rest + child_radius;
/// Most stars the `cluster` system handles (it works on all of them at once).
const max_stars = 16;

/// How long `FrameStats` collects (seconds) before it updates its readout.
const stats_window = 0.5;

/// World-space vector: x right, y up, z toward the default camera.
/// A SIMD vector, so arithmetic is element-wise (`a + b`, `a * @as(Vec3, @splat(k))`).
pub const Vec3 = @Vector(3, f32);

fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
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
/// Pulls `Orbits` entities toward it with acceleration `mu / r²`.
pub const Attractor = struct { mu: f32 };
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
/// Relationship `(Orbits, center)`: accelerates toward `center`, which must
/// have `Position` + `Attractor`. As a pair, every orbiter of one center
/// shares a table, so systems read the center once per table, not per entity.
pub const Orbits = struct {};

// Fields of the extra terms `register` appends after each system's own params.
const gravity_center_pos = 3;
const gravity_center_attractor = 4;

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

// `$center` binds the target of `(rel, $center)`; terms on it read that exact
// entity. (An `up` traversal would be cached, but it climbs past a center that
// lacks the component, e.g. to a moon's sun.)
const center_var = "$center";

/// Term matching the pair `(rel, $center)`.
fn toCenter(comptime rel: type) ecs.term_t {
    return .{ .first = .{ .id = ecs.id(rel) }, .second = .{ .name = center_var }, .inout = .In };
}

/// Term for `$center`'s `T`.
fn onCenter(comptime T: type) ecs.term_t {
    return .{ .id = ecs.id(T), .src = .{ .name = center_var }, .inout = .In };
}

/// A field the whole table shares (the center's): one value, not a slice.
fn sharedField(it: *ecs.iter_t, comptime T: type, index: i8) T {
    return ecs.field(it, T, index).?[0];
}

/// Registers components and systems on `world`.
pub fn register(world: *ecs.world_t) void {
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, PrevPosition);
    ecs.COMPONENT(world, Ball);
    ecs.COMPONENT(world, Attractor);
    ecs.TAG(world, Orbits);
    ecs.COMPONENT(world, Star);
    ecs.COMPONENT(world, Cord);
    ecs.COMPONENT(world, Home);
    ecs.TAG(world, Barycenter);
    addSystem(world, "snapshot", ecs.OnLoad, snapshot, &.{});
    // gravity and cluster (PreUpdate) update velocity before move (OnUpdate)
    // uses it: semi-implicit Euler, which keeps orbits and springs from
    // gaining energy and spiralling out.
    addSystem(world, "gravity", ecs.PreUpdate, gravity, &.{ toCenter(Orbits), onCenter(Position), onCenter(Attractor) });
    addRunSystem(world, "cluster", ecs.PreUpdate, cluster, &.{
        .{ .id = ecs.id(Position), .inout = .In },
        .{ .id = ecs.id(Velocity), .inout = .InOut },
        .{ .id = ecs.id(Star), .inout = .In },
        .{ .id = ecs.pair(ecs.id(Cord), ecs.Wildcard), .inout = .In, .oper = .Optional },
        .{ .id = ecs.id(Home), .inout = .In, .oper = .Optional },
    });
    addSystem(world, "move", ecs.OnUpdate, move, &.{});
    // After move, so it describes the step just taken.
    addRunSystem(world, "barycenter", ecs.PostUpdate, barycenter, &.{
        .{ .id = ecs.id(Position), .inout = .In },
        .{ .id = ecs.id(Star), .inout = .In },
        .{ .id = ecs.id(Position), .src = .{ .id = ecs.id(Barycenter) }, .inout = .InOut },
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

fn gravity(it: *ecs.iter_t, positions: []const Position, velocities: []Velocity) void {
    const dt = it.delta_time;
    const c = sharedField(it, Position, gravity_center_pos);
    const a = sharedField(it, Attractor, gravity_center_attractor);
    for (positions, velocities) |p, *v| {
        const d = c.v - p.v;
        const r2 = dot(d, d);
        if (r2 == 0) continue;
        // a = mu / r² along d / r.
        v.v += d * splat(a.mu / (r2 * @sqrt(r2)) * dt);
    }
}

// Field indices of the `cluster` and `barycenter` terms in `register`.
const cluster_pos = 0;
const cluster_vel = 1;
const cluster_star = 2;
const cluster_cord = 3;
const cluster_home = 4;
const bary_pos = 0;
const bary_star = 1;
const bary_out = 2;

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
        // pair_second keeps only the id's low 32 bits; get_alive restores the
        // generation, or a mother on a recycled id would never match.
        const mother = if (cords != null) ecs.get_alive(it.world, ecs.pair_second(ecs.field_id(it, cluster_cord))) else 0;
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

/// Mass-weighted center of the stars into the `Barycenter` singleton.
fn barycenter(it: *ecs.iter_t) callconv(.c) void {
    var sum = splat(0);
    var total: f32 = 0;
    var out: ?*Position = null;
    while (ecs.iter_next(it)) {
        out = &ecs.field(it, Position, bary_out).?[0];
        for (ecs.field(it, Position, bary_pos).?, ecs.field(it, Star, bary_star).?) |p, s| {
            sum += p.v * splat(s.mass);
            total += s.mass;
        }
    }
    const b = out orelse return;
    if (total > 0) b.v = sum / splat(total);
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
/// would fling the orbiter out of orbit for good.
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
    // Distances, as multiples of the radius `framing` is given.
    const frame_distance = 3.2;
    const frame_min = 1.3;
    const frame_max = 12;

    /// A camera on `target` that fits a scene `radius` across in its default
    /// view, and zooms from just outside it to far away.
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

    /// Camera position.
    pub fn eye(self: OrbitCam) Vec3 {
        const flat = @cos(self.pitch);
        return self.target + splat(self.distance) * Vec3{ flat * @sin(self.yaw), @sin(self.pitch), flat * @cos(self.yaw) };
    }
};

pub const Demo = struct { center: ecs.entity_t, orbiter: ecs.entity_t };

/// A static ball at `at` and a second ball circling it in the horizontal (xz)
/// plane at `radius`, once every `period` seconds. Speed and pull are chosen
/// so the orbit is an exact circle: v = 2πr/T, mu = v²·r.
pub fn spawnDemo(world: *ecs.world_t, at: Vec3, radius: f32, period: f32) Demo {
    const speed = 2 * std.math.pi * radius / period;

    const center = ecs.new_id(world);
    set(world, center, Position, .{ .v = at });
    set(world, center, Attractor, .{ .mu = speed * speed * radius });
    set(world, center, Ball, .{ .radius = radius * attractor_size, .rgba = orange });

    const orbiter = ecs.new_id(world);
    const start = at + Vec3{ radius, 0, 0 };
    set(world, orbiter, Position, .{ .v = start });
    set(world, orbiter, PrevPosition, .{ .v = start });
    // Counter-clockwise seen from above (+y).
    set(world, orbiter, Velocity, .{ .v = .{ 0, 0, -speed } });
    ecs.add_pair(world, orbiter, ecs.id(Orbits), center);
    set(world, orbiter, Ball, .{ .radius = radius * orbiter_size, .rgba = teal });

    return .{ .center = center, .orbiter = orbiter };
}

pub const Cluster = struct { mother: ecs.entity_t, children: [child_starts.len]ecs.entity_t };

/// The mother star at `at`, anchored there, and her children spread evenly
/// around her on cords, each started a little off rest so the cluster wobbles.
/// Also sets the `Barycenter` singleton.
pub fn spawnCluster(world: *ecs.world_t, at: Vec3) Cluster {
    var c: Cluster = undefined;
    c.mother = spawnStar(world, at, mother_mass, mother_radius, mother_white);
    set(world, c.mother, Home, .{ .v = at });

    var sum = at * splat(mother_mass);
    for (&c.children, child_starts, 0..) |*child, start, i| {
        const angle = std.math.tau * @as(f32, @floatFromInt(i)) / child_starts.len;
        const r = cord_rest * (1 + start.stretch);
        const p = at + Vec3{ r * @cos(angle), start.lift, -r * @sin(angle) };
        child.* = spawnStar(world, p, child_mass, child_radius, child_green);
        setPair(world, child.*, Cord, c.mother, .{ .rest = cord_rest });
        sum += p * splat(child_mass);
    }
    const center = sum / splat(cluster_mass);
    set(world, ecs.id(Barycenter), Position, .{ .v = center });
    set(world, ecs.id(Barycenter), PrevPosition, .{ .v = center });
    return c;
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

/// Query over every drawable entity: term 0 = `Position`, term 1 = `Ball`,
/// term 2 = optional `PrevPosition` (null field for static entities).
/// Caller owns it (`ecs.query_fini`).
pub fn ballQuery(world: *ecs.world_t) !*ecs.query_t {
    return ecs.query_init(world, &.{
        .terms = [_]ecs.term_t{
            .{ .id = ecs.id(Position) },
            .{ .id = ecs.id(Ball) },
            .{ .id = ecs.id(PrevPosition), .oper = .Optional },
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

// Semi-implicit Euler keeps the orbit bounded but slightly elliptical: at
// 120 steps per orbit the radius wobbles about ±3% and never drifts, and each
// full period returns close to the start. The tests check exactly that.

test "orbit radius stays bounded over many orbits, in its plane" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const d = spawnDemo(world, .{ 0, 0, 0 }, 5, 2);

    for (0..10 * 120) |_| { // 10 orbits at 60 steps/s
        step(world, 1);
        const o = positionOf(world, d.orbiter);
        try expectApproxEqAbs(@as(f32, 5), length(o), 5 * 0.03);
        try expectEqual(@as(f32, 0), o[1]);
    }
}

test "attractor stays put" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const d = spawnDemo(world, .{ 4, 2, -3 }, 5, 4);

    step(world, 240);
    try expectEqual(Vec3{ 4, 2, -3 }, positionOf(world, d.center));
}

test "each period brings the orbiter back to its start" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const d = spawnDemo(world, .{ 0, 0, 0 }, 5, 2);

    for (0..3) |_| {
        step(world, 120);
        try expect(distance(positionOf(world, d.orbiter), .{ 5, 0, 0 }) < 5 * 0.05);
    }
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

test "orbit survives a 3 s frame stall" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const d = spawnDemo(world, .{ 0, 0, 0 }, 5, 2);

    var clock: FixedClock = .{};
    step(world, 30);
    for (0..clock.advance(3.0)) |_| _ = ecs.progress(world, step_dt);
    for (0..120) |_| {
        for (0..clock.advance(step_dt)) |_| _ = ecs.progress(world, step_dt);
        try expectApproxEqAbs(@as(f32, 5), length(positionOf(world, d.orbiter)), 5 * 0.03);
    }
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

test "snapshot keeps the position from before the step" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const d = spawnDemo(world, .{ 0, 0, 0 }, 5, 2);

    step(world, 10);
    const before = positionOf(world, d.orbiter);
    step(world, 1);
    try expectEqual(before, ecs.get(world, d.orbiter, PrevPosition).?.v);
    try expect(distance(before, positionOf(world, d.orbiter)) > 0);
}

test "ballQuery yields both demo balls" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    _ = spawnDemo(world, .{ 0, 0, 0 }, 5, 2);

    const q = try ballQuery(world);
    defer ecs.query_fini(q);
    var n: usize = 0;
    var with_prev: usize = 0; // only the orbiter has PrevPosition
    var it = ecs.query_iter(world, q);
    while (ecs.query_next(&it)) {
        n += it.count();
        if (ecs.field(&it, PrevPosition, 2) != null) with_prev += it.count();
    }
    try expectEqual(@as(usize, 2), n);
    try expectEqual(@as(usize, 1), with_prev);
}

test "worker threads give the same result as one thread" {
    const orbiters = 200;
    var runs: [2][orbiters]Vec3 = undefined;
    // zflecs allows one world at a time, so run them one after the other.
    for (&runs, [_]i32{ 0, 4 }) |*out, threads| {
        const world = ecs.init();
        defer _ = ecs.fini(world);
        register(world);
        if (threads > 0) ecs.set_threads(world, threads);
        const d = spawnDemo(world, .{ 0, 0, 0 }, 5, 4);
        const speed = 2 * std.math.pi * 5.0 / 4.0;
        // Extra orbiters on tilted, widening paths, so work splits across workers.
        var es: [orbiters]ecs.entity_t = undefined;
        for (&es, 0..) |*e, i| {
            const k: f32 = @floatFromInt(i);
            e.* = ecs.new_id(world);
            set(world, e.*, Position, .{ .v = .{ 3 + k * 0.02, 0, 0 } });
            set(world, e.*, Velocity, .{ .v = .{ 0, k * 0.01, -speed } });
            ecs.add_pair(world, e.*, ecs.id(Orbits), d.center);
        }
        step(world, 600);
        for (out, es) |*p, e| p.* = positionOf(world, e);
    }
    try expectEqualSlices(Vec3, &runs[0], &runs[1]);
}

test "a center without Attractor pulls nothing, even if its own center has one" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const d = spawnDemo(world, .{ 0, 0, 0 }, 5, 2);

    // A moon of the orbiter, which has Position but no Attractor.
    const moon = ecs.new_id(world);
    set(world, moon, Position, .{ .v = .{ 5, 1, 0 } });
    set(world, moon, Velocity, .{ .v = .{ 0, 0, 0 } });
    ecs.add_pair(world, moon, ecs.id(Orbits), d.orbiter);

    step(world, 10);
    try expectEqual(Vec3{ 0, 0, 0 }, ecs.get(world, moon, Velocity).?.v);
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
        try expect(distance(b, sum / splat(cluster_mass)) < 1e-4);
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
