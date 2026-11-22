//! ECS state and systems. Knows nothing about rendering, so it runs under
//! `zig build test` without a window or GPU.
const std = @import("std");
const ecs = @import("zflecs");

// Star colours: the mother is the brightest (warm white), her children green.
const mother_white: u32 = 0xFFF1D6FF;
const child_green: u32 = 0x52D97FFF; // phosphor green, with enough red that the glow washes its core white

// Star cluster (world units; masses only matter relative to each other). The
// mother is slightly smaller than her children but heavier, and is held home
// by a weak spring. Every cord is a spring that pulls both ends; every pair of
// stars pushes apart a little. Nothing damps it, so the cluster keeps
// breathing; the anchor lets the barycenter drift a little with it.
const mother_radius = 0.4;
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
pub const max_stars = 16;

// The waiting dance (#23): with 1 or 2 outputs left, the stars leave their
// springs for exact paths; removed outputs are parked inside the mother (same
// place, mass kept, scale 0), so the planets' gravity doesn't change. Each
// switch eases over `switch_time` from where the stars were and how they
// moved (that motion carries on, fading over `switch_coast`), and back at
// all outputs the springs take over from the spawn layout, so the cluster
// breathes as it did at the start. 2 outputs: mother and children on a level
// triangle's corners, each running corner → centre → far edge and back, a
// third of a cycle apart. 1 output: mother and child take turns through the
// centre on crossed lines. The paths are shifted so the barycenter stays on
// the mother's `Home`; moving stars shrink toward the centre.
const dance_period = 2.4; // seconds per cycle
const dance_shrink = 0.55; // scale at the centre
const switch_time = 1.2;
const switch_coast = 0.3;
/// Triangle corners' distance from its centre: corner to corner is a cord's rest length.
const triangle_r = cord_rest / @sqrt(3.0);
/// Along its corner's line a star swings `triangle_mid` ± `triangle_swing`
/// (× `triangle_r`): from its corner (1) through the centre to the far edge (-0.5).
const triangle_mid = 0.25;
const triangle_swing = 0.75;
/// How far mother and child swing out on their crossed lines.
const cross_reach = 0.85 * cord_rest;
// Springs at all 3 outputs, a dance at 1 and 2: the table must hold exactly 3.
comptime {
    std.debug.assert(children.len == 3);
}
/// Most outputs the scene shows (the children table).
pub const output_max: u8 = children.len;
/// Stars in the dance: the mother (slot 0), then each output by index.
const dancers = 1 + children.len;

// Planets (the IPO's inputs): every star pulls each one with g·mass/r²,
// softened so a close pass stays finite. g sets the pace: the inner ring
// takes ~29 s a lap; the cluster's springs don't use it. The cluster is lumpy
// and wobbles, which would make the orbits wander; the thrusters (below) hold
// them.
const g = 13.75;
const planet_soft = 0.3;
// Layout (`planetSlot`): every planet the same size, on Kepler ellipses
// around the barycenter (one focus), on one plane tilted `planet_tilt` off
// xz. Only the colour differs. Planets on one ring share its period and are
// the same mean anomaly apart (360°/n), so they bunch toward its far end, as
// real ones do. Past `planet_ring_max` planets the odd ones (0-based) move
// out to a ring `planet_ring_bump` larger, its long axis turned
// `planet_ring_turn`; the two never cross (closest ~1.2 apart, over two
// planet radii).
const planet_ring_r = 9.0; // semi-major axis of ring 0
const planet_ring_bump = 3.5;
const planet_ecc = 0.15;
const planet_ring_turn = std.math.pi / 2.0;
/// Newton rounds for Kepler's equation: f32 precision for e up to ~0.5.
const kepler_rounds = 4;
const planet_ring_max = 8;
const planet_radius = 0.48;
const planet_tilt = 0.06;
/// Every planet orbit tilts `planet_tilt` about this axis.
const planet_tilt_axis: Vec3 = .{ 1, 0, 0 };
// The sample IPO: this project's own build. The mother is `zig build` (the
// process, unlabelled); the planets are its inputs and her children its
// outputs. Planet colours: the tech-trio palette (teal, orange, sand,
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
// Thrusters (#21): a planet further than `thrust_on` × its ring's semi-major
// axis from its slot fires until it is back within `thrust_off` (hysteresis,
// so it doesn't flicker). The slot runs round the ring's ellipse on Kepler's
// schedule, so thrusters also restore the spacing. Thrust is a damped spring
// toward the slot's position and velocity, capped at `thrust_max`; gravity
// keeps acting throughout. Between firings `settle` damps the planet's
// radial speed toward its slot's (a quiet stand-in for the thrusters that
// keeps the cluster's wobble from building up). A 10-minute probe with 12
// planets: within 0.10 semi-major axes of their slots, thrusting ~30% of the
// time.
const thrust_on = 0.08;
const thrust_off = 0.02;
const thrust_k = 0.5; // per s², toward the slot's position
const thrust_damp = 1.4; // per s, toward the slot's velocity (~critical for k)
const thrust_max = 0.4;
/// Per second: how fast a planet's radial speed settles to its slot's.
const settle = 0.05;
/// Per second: how fast an idle nozzle swivels toward the push it would give;
/// below `thrust_aim_min` that push is too small to have a steady direction.
const thrust_aim = 4.0;
const thrust_aim_min = 0.05;

/// How far the planets reach from the barycenter (the outer ring's far end), for framing.
pub const system_radius = ring_orbits[planet_rings - 1].a * (1 + planet_ecc) + planet_radius;

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
/// free of raylib types. `scale` shrinks it while it dances (0: parked).
pub const Ball = struct {
    radius: f32,
    rgba: u32,
    scale: f32 = 1,

    /// The radius to draw at.
    /// @param b Ball the ball
    /// @returns f32 `radius` × `scale`
    pub fn size(b: Ball) f32 {
        return b.radius * b.scale;
    }
};
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
/// Where a planet belongs: on ring `ring`'s ellipse (`ring_orbits`) at mean
/// anomaly `phase`, which turns at the ring's mean motion `omega` (rad/s), so
/// the slots keep their spacing in time.
pub const Slot = struct { ring: u1, phase: f32, omega: f32 };
/// A planet's thruster: `on` while it steers back to its slot, pushing along
/// `dir` (unit; while idle, it swivels toward the push it would give);
/// `time` counts how long it has been firing.
pub const Thruster = struct { on: bool = false, dir: Vec3 = .{ 0, 1, 0 }, time: f32 = 0 };
/// A name to show next to a body (planets and child stars).
pub const Label = struct { text: [:0]const u8 };
/// Tag: the mother star (the IPO's process). Her children hang on cords;
/// planets are her inputs.
pub const Mother = struct {};
/// An output (child star) by its place in the scene's table: `setOutputs(n)`
/// keeps outputs 0…n-1 and parks the rest in the mother.
pub const Output = struct { index: u8 };
/// Singleton on `ecs.id(Waiting)`: how many outputs are shown, and the
/// switch-over and dance clocks `cluster` runs.
pub const Waiting = struct {
    outputs: u8 = output_max,
    /// Seconds since the latest switch began (0: it starts on the next step,
    /// which takes the `from_*` state; done at `switch_time`), and into the dance.
    since: f32 = switch_time,
    clock: f32 = 0,
    /// Each dancer's state as the switch began, by slot (0 the mother, then
    /// outputs by index).
    from_pos: [dancers]Vec3 = @splat(splat(0)),
    from_vel: [dancers]Vec3 = @splat(splat(0)),
    from_scale: [dancers]f32 = @splat(1),
};
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
    ecs.COMPONENT(world, Slot);
    ecs.COMPONENT(world, Thruster);
    ecs.TAG(world, Mother);
    ecs.TAG(world, InputOf);
    ecs.COMPONENT(world, Output);
    ecs.COMPONENT(world, Waiting);
    // Before any star exists: system terms on singletons need them to match.
    set(world, ecs.id(StarField), StarField, .{});
    set(world, ecs.id(Waiting), Waiting, .{});
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
        .{ .id = ecs.id(Ball), .inout = .InOut },
        .{ .id = ecs.id(Output), .inout = .In, .oper = .Optional },
        .{ .id = ecs.id(Waiting), .src = .{ .id = ecs.id(Waiting) }, .inout = .InOut },
    });
    addSystem(world, "pull", ecs.PreUpdate, pull, &.{
        .{ .id = ecs.id(Planet), .inout = .InOutNone },
        .{ .id = ecs.id(StarField), .src = .{ .id = ecs.id(StarField) }, .inout = .In },
    });
    // After pull: gravity first, then the correction.
    addSystem(world, "thrust", ecs.PreUpdate, thrust, &.{
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
const cluster_ball = 5;
const cluster_output = 6;
const cluster_waiting = 7;
// pull's extra terms come after its own two params.
const pull_field = 3;
// thrust's extra term comes after its own four params (fields 0-3).
const thrust_field = 4;
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
    scale: *f32,
    /// Its place in the dance: 0 the mother (the star with a `Home`), then
    /// outputs by index; null for other stars.
    slot: ?usize,
};

/// Cord springs, pair pushes and the home anchor, on every star at once; and
/// with outputs removed (or a switch under way), the waiting dance, which
/// overrides the dancers' velocities so `move` puts them on its paths.
fn cluster(it: *ecs.iter_t) callconv(.c) void {
    var bodies: [max_stars]Body = undefined;
    var n: usize = 0;
    var waiting: ?*Waiting = null;
    while (ecs.iter_next(it)) {
        waiting = &ecs.field(it, Waiting, cluster_waiting).?[0];
        const balls = ecs.field(it, Ball, cluster_ball).?;
        const outs = ecs.field(it, Output, cluster_output);
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
                .scale = &balls[i].scale,
                .slot = if (outs) |o| 1 + @as(usize, o[i].index) else if (homes != null) 0 else null,
            };
            n += 1;
        }
    }
    const bs = bodies[0..n];
    const dt = it.delta_time;
    const w = waiting orelse return springs(bs, dt);
    w.clock = @mod(w.clock + dt, dance_period);
    if (w.outputs == output_max and w.since >= switch_time) return springs(bs, dt);

    // The dance (or a switch): every dancer's place at the end of this step.
    if (w.since == 0) for (bs) |b| if (b.slot) |k| {
        w.from_pos[k] = b.pos;
        w.from_vel[k] = b.vel.*;
        w.from_scale[k] = b.scale.*;
    };
    w.since = @min(w.since + dt, switch_time);
    var masses: [dancers]f32 = @splat(0);
    for (bs) |b| if (b.slot) |j| {
        masses[j] = b.mass;
    };
    const home = for (bs) |b| (if (b.slot == 0) break b.home.?) else return;
    const to = dancePose(w.outputs, w.clock, home, masses);
    const k = w.since / switch_time;
    const ease = k * k * (3 - 2 * k);
    // The old motion, fading: its velocity carries on at the start.
    const coast = switch_coast * (1 - @exp(-w.since / switch_coast));
    for (bs) |b| if (b.slot) |j| {
        const from = w.from_pos[j] + w.from_vel[j] * splat(coast);
        const p = std.math.lerp(from, to.pos[j], splat(ease));
        b.vel.* = (p - b.pos) / splat(dt);
        b.scale.* = std.math.lerp(w.from_scale[j], to.scale[j], ease);
    };
}

/// Cord springs, pair pushes and the home anchor on `bs`, over `dt`.
fn springs(bs: []const Body, dt: f32) void {
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
    for (bs, acc[0..bs.len]) |b, a| b.vel.* += a * splat(dt);
}

/// Shows `n` outputs, clamped to 1…`output_max`; the rest park in the mother.
/// A change starts a switch-over from where the stars are now.
/// @param world *ecs.world_t the scene
/// @param n usize outputs wanted
pub fn setOutputs(world: *ecs.world_t, n: usize) void {
    const w = ecs.get_mut(world, ecs.id(Waiting), Waiting).?;
    const m: u8 = @intCast(std.math.clamp(n, 1, output_max));
    if (m != w.outputs) {
        w.outputs = m;
        w.since = 0;
    }
}

/// How many outputs are shown.
/// @param world *ecs.world_t the scene
/// @returns u8 1…`output_max`
pub fn outputs(world: *ecs.world_t) u8 {
    return ecs.get(world, ecs.id(Waiting), Waiting).?.outputs;
}

/// Where each dancer belongs, and its scale, by slot (0 the mother, then
/// outputs by index), `t` seconds into the dance with `n` outputs shown.
/// At all outputs that is the spawn layout the springs start from; at 1 or
/// 2 the dance, shifted so the barycenter (by `masses`) stays on `home`.
/// @param n u8 outputs shown, 1…`output_max`
/// @param t f32 seconds into the dance
/// @param home Vec3 the mother's anchor
/// @param masses [dancers]f32 each dancer's `Star.mass`, by slot
/// @returns struct { pos, scale } one entry per slot
pub fn dancePose(n: u8, t: f32, home: Vec3, masses: [dancers]f32) struct { pos: [dancers]Vec3, scale: [dancers]f32 } {
    var off: [dancers]Vec3 = @splat(splat(0));
    var scale: [dancers]f32 = @splat(1);
    const u = std.math.tau * t / dance_period;
    const reach: f32 = switch (n) {
        output_max => {
            var pos: [dancers]Vec3 = @splat(home);
            for (pos[1..], 0..) |*p, i| p.* += childStart(i);
            return .{ .pos = pos, .scale = scale };
        },
        2 => blk: {
            // Corners: the mother where the parked output was (240°),
            // outputs 0 and 1 where they started (0° and 120°), so the
            // switch moves little.
            for (off[0 .. n + 1], 0..) |*o, j| {
                const corner = ringFlat(@as(f32, @floatFromInt((j + 2) % 3)) * std.math.tau / 3);
                o.* = corner * splat(triangle_r * (triangle_mid + triangle_swing * @cos(u + std.math.tau * @as(f32, @floatFromInt(j)) / 3)));
            }
            break :blk triangle_r;
        },
        1 => blk: {
            off[0] = ringFlat(0) * splat(cross_reach * @cos(u));
            off[1] = ringFlat(std.math.pi / 2.0) * splat(cross_reach * @sin(u));
            break :blk cross_reach;
        },
        else => unreachable,
    };
    for (&off, &scale, 0..) |*o, *sc, j| {
        if (j > n) {
            o.* = off[0]; // parked in the mother
            sc.* = 0;
        } else sc.* = dance_shrink + (1 - dance_shrink) * @min(1, length(o.*) / reach);
    }
    // Shifted so the stars' mass center sits on `home`.
    const shift = massCenter(&off, &masses) orelse splat(0);
    var pos: [dancers]Vec3 = undefined;
    for (&pos, off) |*p, o| p.* = home + o - shift;
    return .{ .pos = pos, .scale = scale };
}

/// Unit vector at `angle` on the level xz plane (the cluster's): 0 along +x,
/// counter-clockwise seen from above.
fn ringFlat(angle: f32) Vec3 {
    return .{ @cos(angle), 0, -@sin(angle) };
}

/// Where output `i` starts, from the mother: a little off its cord's rest
/// length, so the cluster wobbles.
fn childStart(i: usize) Vec3 {
    return ringFlat(std.math.tau * @as(f32, @floatFromInt(i)) / children.len) * splat(cord_rest * (1 + children[i].stretch));
}

/// Every star's pull on every planet.
fn pull(it: *ecs.iter_t, positions: []const Position, velocities: []Velocity) void {
    const f = &ecs.field(it, StarField, pull_field).?[0];
    const dt = it.delta_time;
    for (positions, velocities) |p, *v| v.v += fieldPull(f, p.v) * splat(dt);
}

/// Advances each planet's slot and fires its thruster while it is off it.
fn thrust(it: *ecs.iter_t, positions: []const Position, velocities: []Velocity, slots: []Slot, thrusters: []Thruster) void {
    const f = &ecs.field(it, StarField, thrust_field).?[0];
    const dt = it.delta_time;
    const aim = 1 - @exp(-thrust_aim * dt); // an idle nozzle's easing this step
    for (positions, velocities, slots, thrusters) |p, *v, *slot, *t| {
        // Compare with the slot where it is now, then move the slot on.
        defer slot.phase = @mod(slot.phase + slot.omega * dt, std.math.tau);
        const o = ring_orbits[slot.ring];
        const ecc_anomaly = eccentricAnomaly(slot.phase, o.e);
        const target = f.center + o.at(ecc_anomaly);
        const target_v = f.drift + o.velocity(ecc_anomaly, slot.omega);
        const off = length(target - p.v) / o.a;
        if (off > thrust_on) t.on = true else if (off < thrust_off) t.on = false;
        var a = (target - p.v) * splat(thrust_k) + (target_v - v.v) * splat(thrust_damp);
        const n = length(a);
        const push = if (n > thrust_aim_min) a / splat(n) else t.dir;
        if (!t.on) {
            // Settle: radial only, so it keeps the orbit's angular momentum.
            const out = p.v - f.center;
            const r2 = dot(out, out);
            if (r2 > 0) v.v -= out * splat(settle * dot(v.v - target_v, out) / r2 * dt);
            // Idle, the nozzle eases toward the push it would give, so it is
            // already (nearly) aimed when it fires: no visible snap.
            t.dir = normalize(std.math.lerp(t.dir, push, splat(aim)));
            t.time = 0;
            continue;
        }
        if (n > thrust_max) a *= splat(thrust_max / n);
        t.dir = push;
        v.v += a * splat(dt);
        t.time += dt;
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
    /// The default framing's `distance`, which `zoomFactor` measures against.
    home_distance: f32,
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
        const d = fitDistance(radius, aspect);
        return .{
            .target = target,
            .distance = d,
            .home_distance = d,
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
        self.home_distance *= k;
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

    /// How far zoomed in from the default framing.
    /// @returns {f32} 1 at the default framing, 2 at half its distance.
    pub fn zoomFactor(self: OrbitCam) f32 {
        return self.home_distance / self.distance;
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
        const p = at + childStart(i - 1);
        child.* = spawnStar(world, p, child_mass, child_radius, child_green);
        setPair(world, child.*, Cord, c.mother, .{ .rest = cord_rest });
        set(world, child.*, Label, .{ .text = data.name });
        set(world, child.*, Output, .{ .index = @intCast(i - 1) });
        f.pos[i] = p;
        f.mass[i] = child_mass;
    }
    f.center = massCenter(f.pos[0..f.n], f.mass[0..f.n]).?;
    set(world, ecs.id(StarField), StarField, f);
    set(world, ecs.id(Barycenter), Position, .{ .v = f.center });
    set(world, ecs.id(Barycenter), PrevPosition, .{ .v = f.center });
    return c;
}

/// Where planet `i` of `n` starts: its ring (0: the default one, 1: the
/// bumped one) and mean anomaly.
const PlanetSlot = struct { ring: u1, phase: f32 };

fn planetSlot(i: usize, n: usize) PlanetSlot {
    return .{
        .ring = @intFromBool(n > planet_ring_max and i % 2 == 1),
        .phase = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)),
    };
}

/// A planet ring: a Kepler ellipse around the barycenter (one focus), on the
/// tilted planet plane.
pub const Orbit = struct {
    /// Semi-major axis and eccentricity.
    a: f32,
    e: f32,
    /// Unit vectors on the plane: toward the near end (periapsis), and 90°
    /// on in the direction of travel.
    peri: Vec3,
    side: Vec3,

    /// The semi-minor axis.
    /// @param o Orbit the ring
    /// @returns f32 its semi-minor axis, world units
    pub fn b(o: Orbit) f32 {
        return o.a * @sqrt(1 - o.e * o.e);
    }

    /// The ellipse's center.
    /// @param o Orbit the ring
    /// @returns Vec3 the center, from the focus
    pub fn center(o: Orbit) Vec3 {
        return o.peri * splat(-o.a * o.e);
    }

    /// A point on the ellipse.
    /// @param o Orbit the ring
    /// @param ecc_anomaly f32 its eccentric anomaly, radians
    /// @returns Vec3 the point, from the focus
    pub fn at(o: Orbit, ecc_anomaly: f32) Vec3 {
        return o.center() + o.peri * splat(o.a * @cos(ecc_anomaly)) + o.side * splat(o.b() * @sin(ecc_anomaly));
    }

    /// A point on the ellipse by time: `at`, after solving Kepler's equation.
    /// @param o Orbit the ring
    /// @param mean_anomaly f32 its mean anomaly, radians
    /// @returns Vec3 the point, from the focus
    pub fn atMean(o: Orbit, mean_anomaly: f32) Vec3 {
        return o.at(eccentricAnomaly(mean_anomaly, o.e));
    }

    /// The velocity of a body on the ellipse.
    /// @param o Orbit the ring
    /// @param ecc_anomaly f32 where it is, as eccentric anomaly (radians)
    /// @param omega f32 the ring's mean motion, rad/s
    /// @returns Vec3 the velocity, relative to the focus
    pub fn velocity(o: Orbit, ecc_anomaly: f32, omega: f32) Vec3 {
        const rate = omega / (1 - o.e * @cos(ecc_anomaly)); // dE/dt
        return (o.peri * splat(-o.a * @sin(ecc_anomaly)) + o.side * splat(o.b() * @cos(ecc_anomaly))) * splat(rate);
    }
};

/// Planet ring 0 (default) and 1 (bumped: larger and turned), built once.
pub const ring_orbits = [2]Orbit{ ringOrbit(0), ringOrbit(1) };

fn ringOrbit(ring: u1) Orbit {
    const k: f32 = @floatFromInt(ring);
    return .{
        .a = planet_ring_r + k * planet_ring_bump,
        .e = planet_ecc,
        .peri = ringDir(k * planet_ring_turn),
        .side = ringDir(k * planet_ring_turn + std.math.pi / 2.0),
    };
}

/// Solves Kepler's equation M = E - e·sin E for the eccentric anomaly E.
/// @param mean_anomaly f32 M, radians
/// @param e f32 eccentricity, below 1
/// @returns f32 E, radians
pub fn eccentricAnomaly(mean_anomaly: f32, e: f32) f32 {
    var ecc = mean_anomaly + e * @sin(mean_anomaly);
    for (0..kepler_rounds) |_| ecc -= (ecc - e * @sin(ecc) - mean_anomaly) / (1 - e * @cos(ecc));
    return ecc;
}

/// Unit vector at `angle` on the (tilted) planet plane: 0 along +x, then
/// counter-clockwise seen from above.
pub fn ringDir(angle: f32) Vec3 {
    return rotate(ringFlat(angle), planet_tilt_axis, planet_tilt);
}

/// The planets' (tilted) plane's normal: up, for `ringDir`'s counter-clockwise.
const ring_normal = rotate(.{ 0, 1, 0 }, planet_tilt_axis, planet_tilt);

/// How far a point is from a planet ring's ellipse: 0 on it, a planet's
/// radius when its sphere just touches it.
/// shortcut: measured along the line from the focus, not the ellipse's
/// normal, so slightly long off the ends of the axes (under 1% at e 0.15);
/// solve for the nearest point if rings get much more eccentric.
/// @param p Vec3 the point
/// @param focus Vec3 the ring's focus (the barycenter)
/// @param ring u1 which ring (see `ring_orbits`)
/// @returns f32 the distance, in world units
pub fn ringGap(p: Vec3, focus: Vec3, ring: u1) f32 {
    const o = ring_orbits[ring];
    const d = p - focus;
    const h = dot(d, ring_normal);
    const flat = d - ring_normal * splat(h);
    const rho = length(flat);
    const cos_t = if (rho > 0) dot(flat, o.peri) / rho else 1;
    // The ellipse's distance from the focus that way: a(1 - e²) / (1 + e·cos θ).
    return std.math.hypot(rho - o.a * (1 - o.e * o.e) / (1 + o.e * cos_t), h);
}

/// `n` planets laid out by `planetSlot` around the current barycenter (so
/// spawn the cluster first), each an input of `mother`. Each ring's planets
/// share one period, from the stars' mean pull on them as a point mass:
/// μ = inward pull × r², averaged (the cluster is lumpy, so it varies a
/// little round the ring).
pub fn spawnPlanets(world: *ecs.world_t, mother: ecs.entity_t, comptime n: usize) [n]ecs.entity_t {
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    var mu = [2]f32{ 0, 0 }; // summed g·M estimates, per ring
    var on_ring = [2]f32{ 0, 0 };
    for (0..n) |i| {
        const slot = planetSlot(i, n);
        const d = ring_orbits[slot.ring].atMean(slot.phase);
        mu[slot.ring] += -dot(fieldPull(f, f.center + d), normalize(d)) * dot(d, d);
        on_ring[slot.ring] += 1;
    }
    var out: [n]ecs.entity_t = undefined;
    for (&out, 0..) |*e, i| {
        const slot = planetSlot(i, n);
        const o = ring_orbits[slot.ring];
        const ecc_anomaly = eccentricAnomaly(slot.phase, o.e);
        // Kepler's third law: ω² a³ = μ. Plus the barycenter's own drift, so
        // the orbit is around it.
        const omega = @sqrt(@max(0, mu[slot.ring] / on_ring[slot.ring]) / (o.a * o.a * o.a));
        const v = o.velocity(ecc_anomaly, omega);
        e.* = spawnPlanet(world, mother, f.center + o.at(ecc_anomaly), f.drift + v, planets[i % planets.len]);
        set(world, e.*, Slot, .{ .ring = slot.ring, .phase = slot.phase, .omega = omega });
        set(world, e.*, Thruster, .{ .dir = normalize(v) }); // trailing, until a push builds up
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
/// `pairTarget(it, 2)`), then terms 3… = the `extra` components. Rel is
/// `Cord` (child stars) or `InputOf` (planets). Caller owns it (`ecs.query_fini`).
pub fn linkQuery(world: *ecs.world_t, comptime Rel: type, comptime extra: []const type) !*ecs.query_t {
    var desc: ecs.query_desc_t = .{};
    desc.terms[0] = .{ .id = ecs.id(Position) };
    desc.terms[1] = .{ .id = ecs.id(PrevPosition), .oper = .Optional };
    desc.terms[2] = .{ .id = ecs.pair(ecs.id(Rel), ecs.Wildcard) };
    inline for (extra, 3..) |T, k| desc.terms[k] = .{ .id = ecs.id(T) };
    return ecs.query_init(world, &desc);
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

test "OrbitCam: zoomFactor is 1 at the default framing and grows zooming in" {
    const a = 800.0 / 450.0;
    var cam = OrbitCam.framing(.{ 0, 0, 0 }, 5, a);
    try expectEqual(@as(f32, 1), cam.zoomFactor());
    cam.distance /= 2;
    try expectApproxEqAbs(@as(f32, 2), cam.zoomFactor(), 1e-5);
    // A flip to portrait keeps the zoom.
    cam.reframe(a, 450.0 / 800.0);
    try expectApproxEqAbs(@as(f32, 2), cam.zoomFactor(), 1e-5);
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
            // The thrusters hold each planet within about 0.1 of its ring's
            // semi-major axis from its slot (see the slot test), so near its
            // ring and plane.
            const ring = planetSlot(i, planet_count).ring;
            const a = ring_orbits[ring].a;
            try expect(ringGap(positionOf(world, e), b, ring) / a < 0.12);
            try expect(@abs(dot(positionOf(world, e) - b, ring_normal)) / a < 0.13);
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

test "planets: Kepler ellipses (one ring, or a bumped one for odd planets past the max), one period per ring, one plane, colours differ" {
    inline for (.{ planet_count, planet_ring_max + 2 }) |n| {
        const world = ecs.init();
        defer _ = ecs.fini(world);
        register(world);
        const sc = spawnScene(world, n);
        const f = ecs.get(world, ecs.id(StarField), StarField).?;
        var omega = [2]?f32{ null, null };
        var mu = [2]f32{ 0, 0 };
        var on_ring = [2]f32{ 0, 0 };
        for (sc.ps, 0..) |e, i| {
            const slot = ecs.get(world, e, Slot).?.*;
            try expectEqual(@as(u1, @intFromBool(n > planet_ring_max and i % 2 == 1)), slot.ring);
            // The same mean anomaly apart.
            try expectApproxEqAbs(std.math.tau * @as(f32, @floatFromInt(i)) / n, slot.phase, 1e-5);
            const o = ring_orbits[slot.ring];
            const d = positionOf(world, e) - f.center;
            const v = ecs.get(world, e, Velocity).?.v - f.drift;
            try expect(distance(d, o.atMean(slot.phase)) < 1e-3);
            try expect(distance(normalize(cross(d, v)), ring_normal) < 1e-4); // on the plane
            // One period per ring, and vis-viva speed for it: v² = μ(2/r - 1/a), μ = ω²a³.
            if (omega[slot.ring]) |w0| try expectApproxEqAbs(w0, slot.omega, 1e-6) else omega[slot.ring] = slot.omega;
            const gm = slot.omega * slot.omega * o.a * o.a * o.a;
            try expectApproxEqAbs(gm * (2 / length(d) - 1 / o.a), dot(v, v), 1e-3);
            mu[slot.ring] += -dot(fieldPull(f, positionOf(world, e)), normalize(d)) * dot(d, d);
            on_ring[slot.ring] += 1;
            const b = ecs.get(world, e, Ball).?;
            try expectEqual(@as(f32, planet_radius), b.radius);
            try expectEqual(planets[i % planets.len].rgba, b.rgba);
            try std.testing.expectEqualStrings(planets[i % planets.len].name, ecs.get(world, e, Label).?.text);
        }
        // That period is Kepler's for the ring's mean pull: ω²a³ = μ.
        for (0..2) |ring| if (omega[ring]) |w| {
            const a = ring_orbits[ring].a;
            try expectApproxEqAbs(mu[ring] / on_ring[ring], w * w * a * a * a, 1e-2);
        };
    }
}

test "planets: the inner ring takes ~29 s a lap" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    const lap = std.math.tau / ecs.get(world, sc.ps[0], Slot).?.omega;
    try expect(lap > 27 and lap < 31);
}

test "eccentricAnomaly solves Kepler's equation" {
    for ([_]f32{ 0.15, 0.5 }) |e| {
        for (0..32) |k| {
            const m = std.math.tau * @as(f32, @floatFromInt(k)) / 32;
            const ecc = eccentricAnomaly(m, e);
            try expectApproxEqAbs(m, ecc - e * @sin(ecc), 1e-5);
        }
    }
}

test "the two rings stay over two planet radii apart" {
    // The true nearest distance, by sampling both ellipses.
    const samples = 360;
    var nearest: f32 = std.math.inf(f32);
    for (0..samples) |i| {
        const p = ring_orbits[0].at(std.math.tau * @as(f32, @floatFromInt(i)) / samples);
        for (0..samples) |j| nearest = @min(nearest, distance(p, ring_orbits[1].at(std.math.tau * @as(f32, @floatFromInt(j)) / samples)));
    }
    try expect(nearest > 2 * planet_radius);
}

test "a planet spawned mid-wobble starts with no radial motion relative to the drifting barycenter" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, .{ 0, 0, 0 });
    step(world, 200); // the barycenter is drifting by now
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    try expect(length(f.drift) > 1e-3);
    const p = spawnPlanets(world, c.mother, 1)[0];
    const d = positionOf(world, p) - f.center;
    // It starts at its ring's near end: no radial motion relative to the barycenter.
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
            const ring = planetSlot(i, planet_count).ring;
            try expect(ringGap(positionOf(world, e), b, ring) / ring_orbits[ring].a < 0.1);
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

    const cords = try linkQuery(world, Cord, &.{});
    defer ecs.query_fini(cords);
    const inputs = try linkQuery(world, InputOf, &.{ Slot, Ball });
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

test "ring_orbits: the barycenter at a focus, ring 1 larger and turned" {
    for (ring_orbits) |o| {
        // Near and far ends: a(1 ∓ e) from the focus.
        try expectApproxEqAbs(o.a * (1 - o.e), length(o.at(0)), 1e-4);
        try expectApproxEqAbs(o.a * (1 + o.e), length(o.at(std.math.pi)), 1e-4);
        // Focal property: the distances to both foci sum to 2a.
        const p = o.at(1.1);
        try expectApproxEqAbs(2 * o.a, length(p) + distance(p, o.center() * splat(2)), 1e-4);
    }
    try expectApproxEqAbs(@as(f32, 0), dot(ring_orbits[0].peri, ring_orbits[1].peri), 1e-6); // turned 90°
    try expectEqual(@as(u2, 2), planet_rings); // 12 planets: two rings
}

/// Where `e`'s slot is now, and how far off it the planet is (in semi-major axes).
fn slotOff(world: *ecs.world_t, e: ecs.entity_t) f32 {
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    const s = ecs.get(world, e, Slot).?;
    const o = ring_orbits[s.ring];
    return distance(positionOf(world, e), f.center + o.atMean(s.phase)) / o.a;
}

test "ringGap: distance to the ring's ellipse, in and out of its plane" {
    const c: Vec3 = .{ 1, 2, 3 };
    const o = ring_orbits[1];
    for ([_]f32{ 0, 0.7, 2, std.math.pi, 4 }) |ecc| {
        const p = o.at(ecc);
        const out = normalize(p);
        try expectApproxEqAbs(@as(f32, 0), ringGap(c + p, c, 1), 1e-4);
        try expectApproxEqAbs(@as(f32, 0.5), ringGap(c + p + out * splat(0.5), c, 1), 1e-4);
        try expectApproxEqAbs(@as(f32, 3), ringGap(c + p - out * splat(3), c, 1), 1e-4);
        try expectApproxEqAbs(@as(f32, 0.5), ringGap(c + p + ring_normal * splat(0.5), c, 1), 1e-4);
    }
}

test "thrusters: on its slot a planet coasts" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    step(world, 1);
    for (sc.ps) |e| try expect(!ecs.get(world, e, Thruster).?.on);
}

test "thrusters: a displaced planet fires until it is back on its slot" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    const p = sc.ps[0];
    const b = positionOf(world, ecs.id(Barycenter));
    set(world, p, Position, .{ .v = b + (positionOf(world, p) - b) * splat(1.3) }); // 30% out
    step(world, 1);
    const t = ecs.get(world, p, Thruster).?;
    try expect(t.on);
    // It pushes back in, toward the barycenter.
    try expect(dot(t.dir, positionOf(world, p) - b) < 0);
    var steps: usize = 0;
    while (ecs.get(world, p, Thruster).?.on) : (steps += 1) {
        try expect(steps < 20 * 60);
        step(world, 1);
    }
    try expect(slotOff(world, p) < thrust_off + 0.01);
}

test "thrusters: nozzles are already aimed when they fire (no snap at ignition)" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    var prev: [planet_count]Thruster = undefined;
    var ignitions: usize = 0;
    var worst: f32 = 1;
    for (0..60 * 60) |_| {
        for (sc.ps, &prev) |e, *t| t.* = ecs.get(world, e, Thruster).?.*;
        step(world, 1);
        for (sc.ps, prev) |e, before| {
            const t = ecs.get(world, e, Thruster).?;
            if (t.on and !before.on) {
                ignitions += 1;
                worst = @min(worst, dot(before.dir, t.dir));
            }
        }
    }
    try expect(ignitions > 0);
    try expect(worst > @cos(std.math.degreesToRadians(15.0))); // measured: 8°
}

test "thrusters: every planet stays near its slot (and the even spacing) for two minutes" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    for (0..2 * 60 * 60) |_| {
        step(world, 1);
        // A 10-minute probe stayed within 0.10 radii.
        for (sc.ps) |e| try expect(slotOff(world, e) < 0.13);
    }
}

test "dancePose: periodic, level, barycenter on home, shrinks at the centre, parks the rest in the mother" {
    const home: Vec3 = .{ 1, 0, -2 };
    const masses = [dancers]f32{ 1, 0.5, 0.7, 0.3 }; // any masses: the barycenter still holds
    for ([_]u8{ 1, 2 }) |n| {
        var min_scale: f32 = 1;
        for (0..240) |s| {
            const t = dance_period * @as(f32, @floatFromInt(s)) / 240;
            const a = dancePose(n, t, home, masses);
            const later = dancePose(n, t + dance_period, home, masses);
            for (a.pos, later.pos) |p, q| try expect(distance(p, q) < 1e-3);
            try expect(distance(massCenter(&a.pos, &masses).?, home) < 1e-4);
            for (a.pos, a.scale, 0..) |p, sc, j| {
                try expect(distance(p, home) < 2 * cord_rest);
                try expectApproxEqAbs(home[1], p[1], 1e-5); // level
                if (j > n) {
                    try expect(distance(p, a.pos[0]) < 1e-5);
                    try expectEqual(@as(f32, 0), sc);
                } else {
                    try expect(sc >= dance_shrink - 1e-5 and sc <= 1);
                    min_scale = @min(min_scale, sc);
                }
            }
        }
        try expect(min_scale < dance_shrink + 0.03);
    }
}

test "setOutputs: 3 → 2 → 1 → 3 without jumps; parked outputs sit in the mother; mass kept" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const c = spawnCluster(world, splat(0));
    step(world, 30);
    const stars = [_]ecs.entity_t{c.mother} ++ c.children;
    const mass = starMass(world);
    var prev: [stars.len]Vec3 = undefined;
    for (stars, &prev) |e, *v| v.* = ecs.get(world, e, Velocity).?.v;
    const steps: usize = @intFromFloat(@ceil((switch_time + dance_period) / step_dt));
    for ([_]u8{ 2, 1, 3 }) |n| {
        setOutputs(world, n);
        try expectEqual(n, outputs(world));
        for (0..steps) |s| {
            step(world, 1);
            // No jump: a teleport of even 0.1 in one step would change velocity by ~6.
            for (stars, &prev) |e, *v| {
                const now = ecs.get(world, e, Velocity).?.v;
                try expect(length(now - v.*) < 1);
                v.* = now;
            }
            // Dancing, the barycenter holds on the mother's anchor.
            if (n < output_max and @as(f32, @floatFromInt(s)) * step_dt > switch_time)
                try expect(length(ecs.get(world, ecs.id(StarField), StarField).?.center) < 1e-3);
        }
        for (c.children, 0..) |e, i| {
            const sc = ecs.get(world, e, Ball).?.scale;
            if (i < n) try expect(sc > 0) else {
                try expectEqual(@as(f32, 0), sc);
                try expect(distance(positionOf(world, e), positionOf(world, c.mother)) < 1e-3);
            }
        }
        try expectApproxEqAbs(mass, starMass(world), 1e-6);
    }
    // Back at all outputs: full size, on springs again.
    for (stars) |e| try expectEqual(@as(f32, 1), ecs.get(world, e, Ball).?.scale);
}

test "setOutputs clamps to 1…output_max" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    _ = spawnCluster(world, splat(0));
    setOutputs(world, 0);
    try expectEqual(@as(u8, 1), outputs(world));
    setOutputs(world, 9);
    try expectEqual(output_max, outputs(world));
}

fn starMass(world: *ecs.world_t) f32 {
    const f = ecs.get(world, ecs.id(StarField), StarField).?;
    var total: f32 = 0;
    for (f.mass[0..f.n]) |m| total += m;
    return total;
}

test "planets keep their orbits through output switches" {
    const world = ecs.init();
    defer _ = ecs.fini(world);
    register(world);
    const sc = spawnScene(world, planet_count);
    for ([_]u8{ 2, 1, 3, 1 }) |n| {
        setOutputs(world, n);
        for (0..20 * 60) |_| {
            step(world, 1);
            for (sc.ps) |e| try expect(slotOff(world, e) < 0.13);
        }
    }
}
