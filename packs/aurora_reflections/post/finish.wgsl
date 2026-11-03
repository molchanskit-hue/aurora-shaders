override glow_radius: f32 = 3.0;
override glow_threshold: f32 = 1.0;
override glow_strength: f32 = 0.10;
override glow_filter_radius: i32 = 2;
const BLOOM_WEIGHTS = array<f32, 5>(1.0, 4.0, 6.0, 4.0, 1.0);

fn bloom_weight(offset: i32) -> f32 {
    if glow_filter_radius == 1 {
        return select(0.25, 0.5, offset == 0);
    }
    return BLOOM_WEIGHTS[offset + 2] / 16.0;
}

fn bloom(input: PostInput) -> vec4<f32> {
    // Match the filters' second moment: 3 taps need sqrt(2) wider spacing.
    let spacing = select(1.0, 1.41421356237, glow_filter_radius == 1);
    let delta = vec2(glow_radius * spacing * frame.resolution.y / 1080.0) / frame.resolution;
    var light = vec3(0.0);
    for (var y = -glow_filter_radius; y <= glow_filter_radius; y += 1) {
        for (var x = -glow_filter_radius; x <= glow_filter_radius; x += 1) {
            let colour = textureSampleLevel(previous, linear_sampler,
                input.uv + vec2<f32>(f32(x), f32(y)) * delta, 0.0).rgb;
            // Extract only energy above the threshold. Bright diffuse sand no
            // longer contributes its entire base colour to a screen-wide veil.
            let luma = aurora_luma(colour);
            let bright = colour * max(luma - glow_threshold, 0.0) / max(luma, 0.0001);
            light += bright * bloom_weight(x) * bloom_weight(y);
        }
    }
    return vec4(input.color.rgb + light * glow_strength * aurora_effect_visibility(), input.color.a);
}

// Calibrated for scene-linear addition before the common display transform.
override ray_strength: f32 = 0.20;
override ray_steps: i32 = 16;

fn sunlight(input: PostInput) -> vec4<f32> {
    let enabled = smoothstep(0.05, 0.18, frame.sun_direction.y)
        * (1.0 - aurora_immersion()) * (1.0 - frame.rain) * aurora_effect_visibility();
    // The sky already includes atmospheric light. The local, low-sample shadow
    // integral is only used for finite scene segments, never projected over sky.
    if input.depth <= 0.0 || frame.dimension != 0 || frame.eye_in != 0u || sun_shadow.parameters.w < 0.5
        || enabled < 0.001 || ray_strength <= 0.0 { return input.color; }
    let position = view_position(input.uv, max(input.depth, 0.00001));
    let ray = normalize(position);
    let distance = min(length(position), sun_shadow.parameters.z);
    // Forward scattering is strongest when looking towards the light.
    let cosine = dot(ray, frame.sun_direction);
    let phase = 0.36 / pow(max(1.64 - 1.6 * cosine, 0.04), 1.5);
    let extinction = 0.005;
    var scattering = 0.0;
    for (var i = 0; i < ray_steps; i += 1) {
        // Quadratic intervals resolve nearby foliage instead of copying one
        // cutout silhouette at regularly spaced sample planes. Fixed sampling
        // avoids new frame-to-frame noise; weights integrate extinction exactly.
        let lo = f32(i) / f32(ray_steps);
        let hi = f32(i + 1) / f32(ray_steps);
        let a = lo * lo * distance;
        let b = hi * hi * distance;
        let d = (a + b) * 0.5;
        scattering += sun_volume_visibility(ray * d) * (exp(-a * extinction) - exp(-b * extinction));
    }
    let warm = 1.0 - smoothstep(0.05, 0.5, frame.sun_direction.y);
    let colour = mix(vec3(1.0, 0.93, 0.78), vec3(1.0, 0.58, 0.28), warm);
    // Additive single scattering, deliberately bounded to this local shadow map.
    let light = horizon_srgb_to_linear(colour) * scattering * min(phase, 3.0) * ray_strength * enabled;
    return vec4(input.color.rgb + light, input.color.a);
}

override underwater_density: f32 = 1.0;

fn submersion(input: PostInput) -> vec4<f32> {
    // Run after glow composite: absorb both the restored scene and its bloom.
    let wet = aurora_immersion();
    if wet <= 0.00001 { return input.color; }
    // Scene depth includes solid terrain/entities. Transparent layers remain approximate.
    var distance = 128.0;
    if input.depth > 0.0000001 {
        distance = min(length(view_position(input.uv, input.depth)), 128.0);
    }
    let source = max(input.color.rgb, vec3<f32>(0.0));
    let transmission = exp(-vec3<f32>(0.145, 0.050, 0.033) * distance * underwater_density);
    // Local light gates scattered light, so caves/night do not acquire a bright veil.
    let daylight = mix(0.035, 1.0, aurora_day()) * (1.0 - frame.rain * 0.35);
    let sky_light = pow(clamp(frame.eye_light.y, 0.0, 1.0), 2.0);
    let light = clamp(sky_light * daylight + frame.eye_light.x * 0.45, 0.0, 1.0);
    let body = horizon_srgb_to_linear(vec3<f32>(0.009, 0.075, 0.092)) * light;
    let submerged = source * vec3<f32>(0.84, 0.98, 1.0) * transmission
        + body * (vec3<f32>(1.0) - transmission);
    return vec4<f32>(mix(source, submerged, wet), input.color.a);
}

// Sunlight and absorption use only the current pixel after bloom. Avoid two
// full-size FP16 round trips; keep display in its own pass so upscaling still
// happens after the world-resolution lighting work.
fn post(input: PostInput) -> vec4<f32> {
    var stage = input;
    stage.color = bloom(input);
    stage.color = sunlight(stage);
    stage.color = submersion(stage);
    return stage.color;
}
