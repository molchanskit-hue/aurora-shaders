override cloud_steps: i32 = 16;

fn post(input: PostInput) -> vec4<f32> {
    if frame.dimension != 0 || !aurora_air_or_managed_water() || cloud_density <= 0.0 || cloud_coverage <= 0.0 {
        return vec4(0.0, 0.0, 0.0, 1.0);
    }
    let position = view_position(input.uv, max(input.depth, 0.00001));
    let ray = normalize(position);
    let origin = frame.camera_position;
    let advected_origin = origin + cloud_drift(frame.time);
    let interval = cloud_interval(origin, ray);
    let start = interval.x;
    var end = interval.y;
    if input.depth > 0.0 { end = min(end, length(position)); }
    if end <= start { return vec4(0.0, 0.0, 0.0, 1.0); }
    let span = end - start;
    let sun = frame.sun_direction;
    let daylight = aurora_day();
    let evening = 1.0 - smoothstep(0.02, 0.35, sun.y);
    let sun_colour = horizon_srgb_to_linear(mix(vec3(1.0, 0.96, 0.88), vec3(1.0, 0.48, 0.22), evening));
    let ambient = horizon_srgb_to_linear(mix(vec3(0.045, 0.062, 0.10), vec3(0.52, 0.59, 0.68), daylight));
    let weather = 1.0 - clamp(frame.rain * 0.55 + frame.thunder * 0.25, 0.0, 0.8);
    let forward = pow(max(dot(ray, sun), 0.0), 8.0);
    var transmittance = 1.0;
    var radiance = vec3(0.0);
    let jitter = fract(aurora_hash3(vec3<i32>(vec2<i32>(input.pixel), 13))
        + f32(frame.frame_index % 1024u) * 0.61803398875);
    // Long, grazing rays need more samples than short vertical crossings.
    // Equal intervals bound the longest gaps; full-stratum jitter avoids
    // coherent bands as the ray length changes across the screen.
    let steps = clamp(i32(ceil(span / 28.0)), max(4, cloud_steps / 2), cloud_steps * 3);
    let step_size = span / f32(steps);
    for (var i = 0; i < steps; i += 1) {
        let distance = start + (f32(i) + jitter) * step_size;
        let p = advected_origin + ray * distance;
        let medium = cloud_medium(p);
        let density = medium.x * (1.0 - smoothstep(1100.0, CLOUD_RANGE, distance));
        if density > 0.00001 {
            let height = clamp((p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE), 0.0, 1.0);
            // A short eroded probe gives relief to scalloped edges; the far
            // broad probe accounts for neighbouring banks without a light march.
            var sunlight = 0.0;
            let sky_fill = exp(-medium.y * (0.009 + medium.x * 0.30));
            if daylight > 0.001 {
                let path = clamp(medium.y / max(sun.y, 0.14), 6.0, 88.0);
                let near_step = min(path * 0.40, 16.0);
                let near_d = cloud_medium(p + sun * near_step).x;
                let far_d = cloud_bulk_density(p + sun * (path * 0.75));
                let optical = (density * 0.12 + near_d * 0.55 + far_d * 0.33) * path;
                sunlight = (exp(-optical * 1.75) * (0.83 + forward * 0.38)
                    + 0.21 * exp(-optical * 0.38)) * daylight;
            }
            let local_light = ambient * (0.50 + sky_fill * 0.60 + height * 0.10)
                + sun_colour * sunlight * 0.95;
            let light = mix(local_light * weather, horizon_srgb_to_linear(frame.fog_color),
                smoothstep(500.0, 1500.0, distance) * 0.70);
            let alpha = 1.0 - exp(-density * step_size);
            radiance += light * (transmittance * alpha);
            transmittance *= 1.0 - alpha;
        }
        if transmittance < 0.015 { break; }
    }
    let visibility = aurora_effect_visibility();
    return vec4(radiance * visibility, mix(1.0, transmittance, visibility));
}
