// Model shadow receiver; uses the same stable filter as material.wgsl.
// Receiver-plane depth correction and a continuous, texel-aligned tent filter.
// A face parallel to sunlight has no direct solar contribution; its ambient
// lighting must not inherit the unstable depth of a zero-area shadow projection.
fn aurora_surface_visibility(position: vec3<f32>, normal: vec3<f32>, dx: vec3<f32>, dy: vec3<f32>) -> f32 {
    let radius = shadow_tent_radius; // Hardware-filtered pairs: radius² comparisons.
    let incidence = abs(dot(normal, frame.sun_direction));
    let direct = smoothstep(0.02, 0.15, incidence);
    if sun_shadow.parameters.w < 0.5 || direct <= 0.0 { return 1.0; }
    if dot(position, position) >= sun_shadow.parameters.z * sun_shadow.parameters.z { return 1.0; }
    let clip = sun_shadow.matrix * vec4(position, 1.0);
    let uv = clip.xy * vec2(0.5, -0.5) + vec2(0.5);
    let texel = sun_shadow.parameters.x;
    let border = texel * f32(radius + 1);
    if any(uv < vec2(border)) || any(uv > vec2(1.0 - border))
        || clip.z <= 0.0 || clip.z >= 1.0 { return 1.0; }
    let light_dx = (sun_shadow.matrix * vec4(dx, 0.0)).xyz;
    let light_dy = (sun_shadow.matrix * vec4(dy, 0.0)).xyz;
    let plane = cross(light_dx, light_dy);
    let n = plane / max(length(plane), 1e-20);
    let divisor = select(-max(abs(n.z), 0.0001), max(abs(n.z), 0.0001), n.z >= 0.0);
    let gradient = vec2(-2.0 * n.x, 2.0 * n.y) / divisor;
    // The hardware comparison filters four texels within each tap. Cover its
    // footprint too; using only one reference for the entire PCF kernel causes
    // moving self-shadow bands as the light rotates across a sloped receiver.
    let bias = 0.00015 * horizon_sun_bias_scale + texel * (abs(gradient.x) + abs(gradient.y));
    // Pair neighbouring tent weights into bilinear taps. Their positions and
    // weights vary continuously across texel boundaries, without frame noise.
    // Each axis sums to radius squared; the 2D normalization is radius^4.
    let fraction = fract(uv / texel - vec2(0.5));
    var visibility = 0.0;
    for (var y = 0; y < radius; y += 1) {
        for (var x = 0; x < radius; x += 1) {
            let start = vec2<f32>(f32(1 - radius + x * 2), f32(1 - radius + y * 2));
            let a = max(vec2(0.0), vec2(f32(radius)) - abs(start - fraction));
            let b = max(vec2(0.0), vec2(f32(radius)) - abs(start + vec2(1.0) - fraction));
            let w = a + b;
            let offset = (start + b / w - fraction) * texel;
            let reference = clip.z + dot(gradient, offset) - bias;
            visibility += textureSampleCompareLevel(sun_shadow_depth, sun_shadow_sampler, uv + offset, reference) * w.x * w.y;
        }
    }
    let edge = smoothstep(0.0, 0.08, min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y)));
    let range = 1.0 - smoothstep(sun_shadow.parameters.y, sun_shadow.parameters.z, length(position));
    return mix(1.0, visibility / f32(radius * radius * radius * radius), edge * range * direct);
}


// The same scene-linear lighting as terrain; engine applies display() to the hand. Derivatives are supplied
// by the renderer before its alpha test and per-model eligibility branches.
fn entity(input: EntityInput) -> vec4<f32> {
    let vanilla = vec4(horizon_srgb_to_linear(input.vanilla.rgb), input.vanilla.a);
    if frame.dimension != 0 || !aurora_air_or_managed_water() { return vanilla; }
    let geometric = cross(input.position_dx, input.position_dy);
    let unit = geometric / max(length(geometric), 1e-12);
    let normal = select(-unit, unit, dot(unit, -input.position) >= 0.0);
    var visibility = 1.0;
    if aurora_direct_weight(normal, input.light.y) > 0.0001 {
        visibility = aurora_surface_visibility(input.position, normal, input.position_dx, input.position_dy);
    }
    let lit = aurora_surface_light(input.albedo.rgb, normal, input.light, 1.0, visibility);
    let guard = aurora_effect_visibility() * (1.0 - clamp(frame.night_vision, 0.0, 1.0));
    let amount = lighting_strength * guard * (1.0 - aurora_immersion());
    var colour = aurora_surface_haze(mix(vanilla.rgb, lit, amount), input.position, input.light.y);
    return vec4(colour, input.vanilla.a);
}
