// Surface-only fallback and analytic waves. Scene-aware composition is in material.wgsl.
override water_strength: f32 = 1.0;
override wave_strength: f32 = 0.65;
override water_opacity: f32 = 0.42;

// Analytic derivatives of a smooth, non-tiled gradient-noise height field.
// Independent rotations, scales and transport speeds break up long parallel
// crests. Nothing is seeded by screen position or frame index.
const WATER_GRADIENTS = array<vec2<f32>, 8>(
    vec2(1.0, 0.0), vec2(0.70710678, 0.70710678),
    vec2(0.0, 1.0), vec2(-0.70710678, 0.70710678),
    vec2(-1.0, 0.0), vec2(-0.70710678, -0.70710678),
    vec2(0.0, -1.0), vec2(0.70710678, -0.70710678)
);

fn aurora_water_gradient(cell: vec2<i32>, seed: i32) -> vec2<f32> {
    return WATER_GRADIENTS[min(u32(aurora_hash3(vec3(cell, seed)) * 8.0), 7u)];
}

// Return height and its exact x/y derivatives, continuous across cell borders.
fn aurora_water_noise(p: vec2<f32>, seed: i32) -> vec3<f32> {
    let cell = vec2<i32>(floor(p));
    let f = fract(p);
    let a = aurora_water_gradient(cell, seed);
    let b = aurora_water_gradient(cell + vec2(1, 0), seed);
    let c = aurora_water_gradient(cell + vec2(0, 1), seed);
    let d = aurora_water_gradient(cell + vec2(1, 1), seed);
    let h = vec4(dot(a, f), dot(b, f - vec2(1.0, 0.0)),
        dot(c, f - vec2(0.0, 1.0)), dot(d, f - vec2(1.0)));
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let du = 30.0 * f * f * (f - 1.0) * (f - 1.0);
    let height = mix(mix(h.x, h.y, u.x), mix(h.z, h.w, u.x), u.y);
    let gradient = mix(mix(a, b, u.x), mix(c, d, u.x), u.y)
        + du * vec2(mix(h.y - h.x, h.w - h.z, u.y), mix(h.z - h.x, h.w - h.y, u.x));
    return vec3(height, gradient);
}

fn aurora_water_band(p: vec2<f32>, footprint: f32, axis: vec2<f32>,
    frequency: f32, amplitude: f32, speed: f32, seed: i32) -> vec2<f32> {
    let cross_axis = vec2(-axis.y, axis.x);
    let q = vec2(dot(p, axis), dot(p, cross_axis)) * frequency
        + vec2(speed, speed * -0.37) * frame.time + vec2(f32(seed) * 0.17);
    let gradient = aurora_water_noise(q, seed).yz;
    let attenuation = 1.0 - smoothstep(0.22, 0.70, footprint * frequency);
    return (axis * gradient.x + cross_axis * gradient.y) * frequency * amplitude * attenuation;
}

fn aurora_wave_slope(p: vec2<f32>, footprint: f32) -> vec2<f32> {
    return aurora_water_band(p, footprint, vec2(0.93969262, 0.34202014), 0.65, 0.095, 0.28, 17)
        + aurora_water_band(p, footprint, vec2(-0.42261826, 0.90630779), 1.47, 0.038, -0.47, 53)
        + aurora_water_band(p, footprint, vec2(0.61566148, -0.78801075), 3.10, 0.013, 0.67, 97)
        + aurora_water_band(p, footprint, vec2(-0.97814760, -0.20791169), 6.60, 0.0038, -0.89, 131);
}

fn aurora_water(vanilla: vec4<f32>, tint: vec3<f32>, lightmap: vec3<f32>,
    position: vec3<f32>, sky_light: f32, geometric: vec3<f32>, footprint: f32) -> vec4<f32> {
    // Keep the original sides of waterfalls and the underside of overhangs.
    let top = smoothstep(0.55, 0.90, abs(geometric.y));
    let guard = aurora_effect_visibility() * (1.0 - clamp(frame.night_vision, 0.0, 1.0));
    let amount = water_strength * top * guard;
    if amount <= 0.0 { return vanilla; }
    let upward = select(-geometric, geometric, geometric.y >= 0.0);
    let world_xz = position.xz + frame.camera_position.xz;
    let slope = aurora_wave_slope(world_xz, footprint) * wave_strength * (1.0 + frame.rain * 0.35);
    let normal = normalize(upward + vec3<f32>(-slope.x, 0.0, -slope.y));
    let view = -position / max(length(position), 0.0001);
    let reflected = reflect(-view, normal);
    let fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(normal, view), 0.0, 1.0), 5.0);

    // Sky exposure suppresses outdoor reflection/glints in unlit interiors.
    // This is not a shadow map: it cannot reproduce directional tree shadows.
    let exposure = smoothstep(0.15, 0.85, sky_light);
    let sky_dir = normalize(vec3<f32>(reflected.x, max(reflected.y, 0.02), reflected.z));
    let sky = aurora_sky(sky_dir, vec4<f32>(frame.sky_color, 1.0)).rgb;
    let reflection = fresnel * exposure * 0.72;

    // Retain a little biome tint and animated texture detail, with a teal body.
    // Alpha is artistic absorption; depth of the lake is unavailable here.
    let body = horizon_srgb_to_linear(mix(vec3<f32>(0.025, 0.21, 0.25), tint * vec3<f32>(0.12, 0.43, 0.36), 0.28) * lightmap);
    let water_colour = mix(body, vanilla.rgb, 0.14);
    let alpha = mix(water_opacity, 0.96, reflection);
    // Weight reflection for straight-alpha blending so it stays visible.
    let reflected_weight = min(reflection / max(alpha, 0.01), 1.0);
    var colour = mix(water_colour, sky, reflected_weight);

    let weather = 1.0 - clamp(frame.rain * 0.9 + frame.thunder * 0.1, 0.0, 1.0);
    let solar = pow(max(dot(reflected, frame.sun_direction), 0.0), 160.0);
    let lunar = pow(max(dot(reflected, frame.moon_direction), 0.0), 110.0);
    let sun_colour = mix(vec3<f32>(1.0, 0.85, 0.63), vec3<f32>(1.0, 0.50, 0.23), aurora_twilight());
    let specular = horizon_srgb_to_linear(sun_colour) * solar * smoothstep(0.0, 0.12, frame.sun_direction.y) * 3.0
        + vec3<f32>(0.20, 0.29, 0.44) * lunar * smoothstep(0.0, 0.15, frame.moon_direction.y) * 0.22;
    colour += specular * exposure * weather / max(alpha, 0.01);
    return mix(vanilla, vec4<f32>(max(colour, vec3<f32>(0.0)), alpha), amount);
}
