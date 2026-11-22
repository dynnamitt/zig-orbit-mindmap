# zig-orbit-mindmap

[![Zig 0.17](https://img.shields.io/badge/Zig-0.17-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![WebGL](https://img.shields.io/badge/WebGL-live_demo-990000?logo=webgl&logoColor=white)](https://dynnamitt.github.io/zig-orbit-mindmap/)
[![WebAssembly](https://img.shields.io/badge/WebAssembly-emscripten-654FF0?logo=webassembly&logoColor=white)](https://emscripten.org/)

A 3D star system as an IPO (input → process → output) mind map, in Zig 0.17 with
[raylib-zig](https://github.com/raylib-zig/raylib-zig) for window + rendering and
[zflecs](https://github.com/zig-gamedev/zflecs) for ECS. Both come in as Zig packages pinned in `build.zig.zon`.

- **Process:** the warm-white mother star, in the middle.
- **Outputs:** green child stars, tied to her by glowing cords.
- **Inputs:** planets that orbit the cluster's centre of gravity, pulled by every star. Each has a dashed line to the mother and a thruster that fires to bring it back to its slot on the ring.

Drag (or one finger) to orbit the camera; scroll (or pinch) to zoom. The window resizes freely, and
in the browser it fills the viewport in either orientation.

```sh
zig build test               # headless ECS unit tests
zig build run                # launch (Linux needs X11/GL dev headers, see .github/workflows/ci.yml)
zig build run -- --portrait  # start in a portrait window
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall   # browser build → zig-out/web/
```

## Updating deps

```sh
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#<commit>
zig fetch --save git+https://github.com/zig-gamedev/zflecs#<commit>
```

Live demo, redeployed from `main` on every push: https://dynnamitt.github.io/zig-orbit-mindmap/
