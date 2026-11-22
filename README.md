# zig-orbit-mindmap

[![Zig 0.17](https://img.shields.io/badge/Zig-0.17-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![WebGL](https://img.shields.io/badge/WebGL-live_demo-990000?logo=webgl&logoColor=white)](https://dynnamitt.github.io/zig-orbit-mindmap/)
[![WebAssembly](https://img.shields.io/badge/WebAssembly-emscripten-654FF0?logo=webassembly&logoColor=white)](https://emscripten.org/)

![The star system: the mother star and three green child stars, with twelve labelled planets on amber and cyan orbit rings over a starfield](screen-001.png)

A 3D star system as an IPO (input → process → output) mind map, in Zig 0.17 with
[raylib-zig](https://github.com/raylib-zig/raylib-zig) for window + rendering and
[zflecs](https://github.com/zig-gamedev/zflecs) for ECS. Both come in as Zig packages pinned in `build.zig.zon`.

- **Process:** the warm-white mother star, in the middle.
- **Outputs:** phosphor-green child stars, tied to her by glowing cords.
- **Inputs:** planets on elliptical orbits around the cluster's centre of gravity, pulled by every star. Each has a dashed line to the mother's ring, in the colour of its orbit ring (amber inner, cyan outer) and brighter toward the centre, and a thruster that fires to bring it back to its slot on the ring.
- **Backdrop:** a shader starfield that turns with the camera.

Drag (or one finger) to orbit the camera; scroll (or pinch) to zoom. The − and + buttons at the top left remove and add outputs: with one or two left, the stars switch to a "waiting" dance. The window resizes freely, and
in the browser it fills the viewport in either orientation.

```sh
zig build test               # headless ECS unit tests
zig build run                # launch (Linux needs X11/GL dev headers, see .github/workflows/ci.yml)
zig build run -- --portrait  # start in a portrait window
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall   # browser build → zig-out/web/
```

## Note to self: perf, Zig vs Rust (wasm size)

This repo against [hex-terrain](https://github.com/dynnamitt/hex-terrain) (Rust, Bevy 0.18), measured 2026-11-22.
MB = 10⁶ bytes; gzip is level 9.

| Build | wasm | wasm, gzip | wasm + JS, gzip | vs Zig, gzip |
|---|--:|--:|--:|--:|
| **Zig**, as deployed (`ReleaseSmall`, `850bb04`) | 0.47 MB | 0.21 MB | 0.25 MB | 1× |
| **Rust**, `make wasm` as it is (`--release`, `7254558`) | 70.93 MB | 14.35 MB | 14.37 MB | 57× |
| Rust, its unused `wasm-release` profile | 65.43 MB | 13.05 MB | 13.06 MB | 52× |
| Rust, that profile + `wasm-opt -Oz` | 28.75 MB | 9.26 MB | 9.28 MB | 37× |
| Rust, also `opt-level="z"`, fat LTO, 1 codegen unit, `strip=true` | 18.65 MB | 6.48 MB | 6.49 MB | 26× |

- **Flags first:** Rust gets 3.8× smaller (2.2× gzipped) with no source change. About 20 MB of the deployed
  wasm is just function names, and it never goes through `wasm-opt` (emcc already runs it for Zig).
- **Then the stack:** the remaining 26× is not Zig vs Rust as languages. It is raylib + Flecs (both C, Flecs
  cut down to the add-ons used here) vs Bevy (wgpu, PBR, egui, …), and two different apps.
- **Count the JS:** emscripten's glue is 18% of the Zig download, wasm-bindgen's under 1% of the Rust one.
- **Size only:** frame time, startup and memory are not measured.

## Updating deps

```sh
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#<commit>
zig fetch --save git+https://github.com/zig-gamedev/zflecs#<commit>
```

Live demo, redeployed from `main` on every push: https://dynnamitt.github.io/zig-orbit-mindmap/
