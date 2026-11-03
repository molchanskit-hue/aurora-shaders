fn post(input: PostInput) -> vec4<f32> {
    let scene = textureSampleLevel(scene_color, linear_sampler, input.uv, 0.0);
    let position = view_position(input.uv, max(input.depth, 0.00001));
    let ray = normalize(position);
    // An exact full-resolution foreground test keeps silhouettes clear of interpolated clouds.
    if input.depth > 0.0 && abs(ray.y) > 0.0001 {
        let a = (CLOUD_BASE - frame.camera_position.y) / ray.y;
        let b = (CLOUD_TOP - frame.camera_position.y) / ray.y;
        let start = max(min(a, b), 0.0);
        if max(a, b) < 0.0 || length(position) < start { return scene; }
    }
    let size = vec2<i32>(textureDimensions(previous));
    let grid = input.uv * vec2<f32>(size) - 0.5;
    let cell = vec2<i32>(floor(grid));
    let f = fract(grid);
    let max_cell = size - vec2(1);
    var volume = vec4(0.0);
    var total = 0.0;
    for (var y = 0; y < 2; y += 1) {
        for (var x = 0; x < 2; x += 1) {
            let sample_cell = clamp(cell + vec2(x, y), vec2(0), max_cell);
            let pixel = sample_cell;
            let uv = (vec2<f32>(pixel) + 0.5) / vec2<f32>(size);
            let depth = depth_at(uv);
            var compatible = 0.0;
            if depth == 0.0 && input.depth == 0.0 { compatible = 1.0; }
            if depth > 0.0 && input.depth > 0.0 {
                let delta = abs(length(view_position(uv, depth)) - length(position));
                compatible = exp(-delta / max(2.0, length(position) * 0.02));
            }
            let weight = select(1.0 - f.x, f.x, x == 1)
                * select(1.0 - f.y, f.y, y == 1) * compatible;
            volume += textureLoad(previous, sample_cell, 0) * weight;
            total += weight;
        }
    }
    if total < 0.0001 { return scene; }
    volume /= total;
    return vec4(scene.rgb * volume.a + volume.rgb, scene.a);
}
