## Aurora Shaders 0.10.1-rc.1

First public prerelease for the Aurora-compatible Horizon renderer on macOS / Apple Silicon. Starting at Medium, water reflects on-screen geometry. Medium adapts its reflection budget to the weather, from 32 steps in clear skies to 24 in full rain.

**Downloads**

- `Aurora-RC1-source-kit.zip` is the starting point for a new installation. Unpack it and open `INSTALL.md` for the source-based client setup and Minecraft Java 26.3 resource preparation.
- `Aurora-HDR-presets-0.10.1-rc.1.zip` contains Low, Medium, High and Ultra for clients with Aurora shader API `0.1-aurora-hdr.1`. The High archive uses the historical filename `aurora-reflections`.
- Individual `.hshader` archives are available below. Download `SHA256SUMS` alongside the assets you want to verify.

**Tested on Apple M3 Pro / Metal.** On the rainy shoreline at an eight-chunk render distance, Medium averaged 121.6 FPS at 1920×1080 with a 1% low of 64.3 FPS. At 2560×1440 it averaged 83.7 FPS with a 1% low of 46.0 FPS. All four release packs were installed from the ZIP and exercised in the game. Test coverage and additional scene results are in the repository. This build targets the patched renderer and has been verified on one Mac configuration.
