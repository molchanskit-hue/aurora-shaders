// Material-only shadow filter; uses the atmosphere.2 fork bindings.
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

// Preserve full-resolution transmission, refraction, lighting and alpha. Only
// the additive change from replacing the analytic reflection is reconstructed.
// Evaluate fine derivatives after material branches reconverge. Ineligible
// receivers (shoreline, underside, immersion) carry zero validity in .w.
fn material(input: MaterialInput) -> Surface {
    var contribution = vec4(0.0);
    let surface = aurora_shade(input, &contribution);
    let pixel = vec2<u32>(input.screen_uv * frame.resolution);
    let side = vec2(1.0) - 2.0 * vec2<f32>(pixel & vec2(1u));
    let across_x = dpdxFine(contribution) * side.x;
    let across_y = dpdyFine(contribution) * side.y;
    if contribution.w < 0.5 { return surface; }
    let shift = 0.24 * (across_x.rgb * step(0.5, contribution.w + across_x.w)
        + across_y.rgb * step(0.5, contribution.w + across_y.w));
    return Surface(vec4(max(surface.color.rgb + shift, vec3(0.0)), surface.color.a), surface.scene_composited);
}

fn aurora_shade(input: MaterialInput, contribution: ptr<function, vec4<f32>>) -> Surface {
    // Derivatives must execute before any per-material divergent branch.
    let dx = dpdx(input.position);
    let dy = dpdy(input.position);
    let cross_normal = cross(dx, dy);
    // Near the waterline, valid screen-space derivatives can be far below 1e-6.
    // Preserve their unit normal so the grazing-surface fade still recognises a top face.
    let geometric = cross_normal / max(length(cross_normal), 0.000000000001);
    let footprint = max(length(dx.xz), length(dy.xz));
    let base = input.albedo * input.tint;
    let legacy = base * vec4<f32>(input.lightmap, 1.0);
    let vanilla = vec4(horizon_srgb_to_linear(legacy.rgb), legacy.a);
    if input.is_water && input.translucent && frame.dimension == 0 && aurora_air_or_managed_water() {
        return aurora_depth_water(input, vanilla, geometric, footprint, contribution);
    }
    // Other translucent materials and submerged views keep engine behaviour.
    if frame.dimension != 0 || !aurora_air_or_managed_water() || input.translucent {
        return Surface(vanilla, false);
    }

    // lighting.rgb is unshaded biome tint; alpha is AO, with zero reserved
    // for meshes that do not supply it (fluids / LOD / legacy construction).
    if input.lighting.a <= 0.0 { return Surface(vanilla, false); }
    let normal = select(-geometric, geometric, dot(geometric, -input.position) >= 0.0);
    var visibility = 1.0;
    if aurora_direct_weight(normal, input.light.y) > 0.0001 {
        visibility = aurora_surface_visibility(input.position, normal, dx, dy);
    }
    let contact = aurora_contact_ambient(input, normal);
    let transmission = aurora_leaf_light(input, normal);
    let lit = aurora_surface_light_forest(input.albedo.rgb * input.lighting.rgb, normal,
        input.light, input.lighting.a, visibility, contact, transmission);
    let guard = aurora_effect_visibility() * (1.0 - clamp(frame.night_vision, 0.0, 1.0));
    let amount = lighting_strength * guard * (1.0 - aurora_immersion());
    let colour = aurora_surface_haze(mix(vanilla.rgb, lit, amount), input.position, input.light.y);
    return Surface(vec4(colour, vanilla.a), false);
}

// Only this stage can read the pre-translucent snapshot. The shared wave/sky
// functions remain usable by the sky and post stages, without these bindings.
override water_density: f32 = 1.0;
override refraction_strength: f32 = 0.7;
override depth_strength: f32 = 1.0;
override ssr_strength: f32 = 1.0;
override ssr_steps: i32 = 48;

// Same-frame, material-only SSR. All positions are camera-relative; the view
// matrix rotates them into camera axes. The snapshot uses reversed-Z (sky=0).
// No history, frame noise or reflection of the water itself is sampled here.
struct AuroraReflectionProbe {
    uv: vec2<f32>,
    gap: f32,
    depth: f32,
}
fn aurora_reflection_probe(clip: vec4<f32>) -> AuroraReflectionProbe {
    if clip.w <= 0.10 { return AuroraReflectionProbe(vec2(-1.0), -1.0, 0.0); }
    let uv = clip.xy / clip.w * vec2(0.5, -0.5) + vec2(0.5);
    if any(uv <= vec2(0.0)) || any(uv >= vec2(1.0)) {
        return AuroraReflectionProbe(uv, -1.0, 0.0);
    }
    let depth = pre_translucent_depth_at(uv);
    if depth <= 0.0000001 { return AuroraReflectionProbe(uv, -1.0, 0.0); }
    // Reversed-Z comparisons need no linearisation. Project origin/direction
    // once, then interpolate homogeneous coordinates along the world-space ray.
    return AuroraReflectionProbe(uv, depth - clip.z / clip.w, depth);
}

// Depth-aware bilinear coverage: neighbours across a depth edge contribute sky,
// not a foreground colour. This smooths texel steps without a history buffer.
fn aurora_reflection_radiance(uv: vec2<f32>, depth: f32) -> vec4<f32> {
    let size = vec2<i32>(textureDimensions(pre_translucent_depth));
    let coord = uv * vec2<f32>(size) - vec2(0.5);
    let base = vec2<i32>(floor(coord));
    let fraction = fract(coord);
    let reference = aurora_scene_position(uv, depth);
    let tolerance = max(0.12, length(reference) * 0.003);
    var colour = vec3(0.0);
    var coverage = 0.0;
    for (var y = 0; y <= 1; y += 1) {
        for (var x = 0; x <= 1; x += 1) {
            let pixel = clamp(base + vec2(x, y), vec2<i32>(0), size - 1);
            let sample_depth = textureLoad(pre_translucent_depth, pixel, 0);
            let sample_uv = (vec2<f32>(pixel) + vec2(0.5)) / vec2<f32>(size);
            let point = aurora_scene_position(sample_uv, max(sample_depth, 0.0000001));
            let distance = abs(length(point) - length(reference));
            let weight = select(1.0 - fraction.x, fraction.x, x == 1)
                * select(1.0 - fraction.y, fraction.y, y == 1)
                * (1.0 - smoothstep(tolerance, tolerance * 2.0, distance))
                * select(0.0, 1.0, sample_depth > 0.0000001);
            colour += textureLoad(pre_translucent_color, pixel, 0).rgb * weight;
            coverage += weight;
        }
    }
    return vec4(colour / max(coverage, 0.000001), coverage);
}

// Returns linear radiance and confidence; misses keep the analytic sky.
fn aurora_scene_reflection(position: vec3<f32>, direction: vec3<f32>) -> vec4<f32> {
    if ssr_strength <= 0.0 || direction.y <= 0.015 { return vec4(0.0); }
    let origin = (frame.view * vec4(position + vec3(0.0, 0.045, 0.0), 1.0)).xyz;
    let ray = (frame.view * vec4(direction, 0.0)).xyz;
    let origin_clip = frame.projection * vec4(origin, 1.0);
    let ray_clip = frame.projection * vec4(ray, 0.0);
    var previous_t = 0.08;
    var previous = aurora_reflection_probe(origin_clip + ray_clip * previous_t);
    // Quadratic spacing concentrates samples near the receiver. The bounded
    // march may miss thin distant geometry; it never invents off-screen colour.
    for (var step = 1; step <= ssr_steps; step += 1) {
        let fraction = f32(step) / f32(ssr_steps);
        let t = 0.08 + 64.0 * fraction * fraction;
        let probe = aurora_reflection_probe(origin_clip + ray_clip * t);
        if any(probe.uv <= vec2(0.0)) || any(probe.uv >= vec2(1.0)) { break; }
        if probe.depth > 0.0 && probe.gap >= 0.0 && previous.gap < 0.0 {
            var lo = previous_t;
            var hi = t;
            var hit = probe;
            for (var refine = 0; refine < 6; refine += 1) {
                let mid = (lo + hi) * 0.5;
                let candidate = aurora_reflection_probe(origin_clip + ray_clip * mid);
                if candidate.depth > 0.0 && candidate.gap >= 0.0 {
                    hi = mid;
                    hit = candidate;
                } else { lo = mid; }
            }
            // A discontinuity is not a surface intersection. Reject crossings
            // far behind a foreground silhouette, and underwater/receiver hits.
            let tolerance = 0.12 + hi * 0.003;
            let scene_point = aurora_scene_position(hit.uv, hit.depth);
            let scene_view = frame.view * vec4(scene_point, 1.0);
            let gap = scene_view.z - (origin.z + ray.z * hi);
            if gap >= -0.01 && gap < tolerance && scene_point.y > position.y + 0.015 && hi > 0.16 {
                let edge = min(min(hit.uv.x, 1.0-hit.uv.x), min(hit.uv.y, 1.0-hit.uv.y));
                let confidence = smoothstep(0.008, 0.095, edge)
                    * (1.0 - smoothstep(40.0, 64.0, hi))
                    * (1.0 - smoothstep(tolerance * 0.5, tolerance, gap))
                    * smoothstep(0.015, 0.08, direction.y) * ssr_strength;
                let sample = aurora_reflection_radiance(hit.uv, hit.depth);
                return vec4(sample.rgb, confidence * sample.a);
            }
        }
        previous_t = t;
        previous = probe;
    }
    return vec4(0.0);
}

fn aurora_scene_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view = frame.projection_inverse * clip;
    return (frame.view_inverse * vec4<f32>(view.xyz / max(view.w, 0.000001), 0.0)).xyz;
}

// Validate all four texels used by bilinear colour sampling, not just the
// nearest depth texel. Otherwise foreground colours can bleed into a shoreline.
fn aurora_nearest_refracted_depth(uv: vec2<f32>) -> f32 {
    let size = vec2<i32>(textureDimensions(pre_translucent_depth));
    let p = clamp(vec2<i32>(floor(uv * vec2<f32>(size) - 0.5)), vec2<i32>(0), size - 2);
    let a = textureLoad(pre_translucent_depth, p, 0);
    let b = textureLoad(pre_translucent_depth, p + vec2<i32>(1, 0), 0);
    let c = textureLoad(pre_translucent_depth, p + vec2<i32>(0, 1), 0);
    let d = textureLoad(pre_translucent_depth, p + vec2<i32>(1, 1), 0);
    return max(max(a, b), max(c, d));
}

fn aurora_depth_water(input: MaterialInput, vanilla: vec4<f32>, geometric: vec3<f32>, footprint: f32, contribution: ptr<function, vec4<f32>>) -> Surface {
    let surface_water = aurora_water(vanilla, input.tint.rgb, input.lightmap,
        input.position, input.light.y, geometric, footprint);
    // Finish fading the top model before the camera crosses its mesh.
    let surface_weight = 1.0 - smoothstep(0.0, 0.5, aurora_immersion());
    var fallback = mix(vanilla, surface_water, surface_weight);
    let top = smoothstep(0.55, 0.90, abs(geometric.y));
    let guard = aurora_effect_visibility() * (1.0 - clamp(frame.night_vision, 0.0, 1.0));
    // Fade the grazing surface before it crosses the camera's clipping plane.
    // World post still supplies immersion; waterfall sides keep their opacity.
    let waterline = mix(1.0, smoothstep(0.015, 0.12, abs(input.position.y)),
        top * guard * water_strength * frame.water.y);
    fallback.a *= waterline;
    // Use the exact native fog factor at this fragment. Frame.fog_start alone
    // is not sufficient: environmental and render-distance fog have two ranges.
    let fog = clamp(input.fog.a, 0.0, 1.0);
    let nearby = (1.0 - smoothstep(48.0, 72.0, length(input.position)))
        * (1.0 - smoothstep(0.70, 0.95, fog));
    let amount = water_strength * depth_strength * top * guard * nearby * surface_weight * waterline;
    if amount <= 0.0001 { return Surface(fallback, false); }

    let uv = input.screen_uv;
    let d = pre_translucent_depth_at(uv);
    let clip = frame.projection * frame.view * vec4<f32>(input.position, 1.0);
    let surface_depth = clip.z / clip.w;
    if d >= surface_depth { return Surface(fallback, false); }
    let ray = input.position / max(length(input.position), 0.0001);
    var thickness = 32.0;
    if d > 0.0000001 {
        thickness = clamp(dot(aurora_scene_position(uv, d) - input.position, ray), 0.0, 32.0);
    }
    let world_xz = input.position.xz + frame.camera_position.xz;
    let slope = aurora_wave_slope(world_xz, footprint) * wave_strength * (1.0 + frame.rain * 0.35);
    let upward = select(-geometric, geometric, geometric.y >= 0.0);
    let normal = normalize(upward + vec3<f32>(-slope.x, 0.0, -slope.y));
    // Project the ripple direction into camera axes. A capped pixel offset
    // fades in with thickness and out at grazing angles and screen edges.
    let normal_view = (frame.view * vec4<f32>(-slope.x, 0.0, -slope.y, 0.0)).xy;
    let view = -ray;
    let ndv = clamp(dot(normal, view), 0.0, 1.0);
    let edge = smoothstep(0.0, 0.04, min(min(uv.x, 1.0-uv.x), min(uv.y, 1.0-uv.y)));
    let offset = clamp(normal_view, vec2<f32>(-0.3), vec2<f32>(0.3)) * vec2<f32>(1.0, -1.0)
        * 30.0 * (frame.resolution.y / 1080.0) / frame.resolution
        * refraction_strength * smoothstep(0.0, 1.5, thickness)
        * smoothstep(0.05, 0.30, ndv) * edge;
    let margin = 1.5 / frame.resolution;
    let candidate = clamp(uv + offset, margin, vec2<f32>(1.0) - margin);
    let candidate_d = pre_translucent_depth_at(candidate);
    var sample_uv = uv;
    if candidate_d > 0.0000001 && aurora_nearest_refracted_depth(candidate) < surface_depth - 0.000001 {
        let bottom = aurora_scene_position(candidate, candidate_d);
        let candidate_thickness = dot(bottom - input.position, ray);
        // Don't drag a bank/foreground object across the waterline. Large
        // discontinuities also fall back to the undistorted sample.
        if bottom.y < input.position.y - 0.02 && candidate_thickness > 0.0
            && abs(candidate_thickness - thickness) < max(1.0, thickness * 0.35) {
            sample_uv = candidate;
            thickness = min(candidate_thickness, 32.0);
        }
    }
    let behind = textureSampleLevel(pre_translucent_color, scene_sampler, sample_uv, 0.0).rgb;
    let original = textureSampleLevel(pre_translucent_color, scene_sampler, uv, 0.0).rgb;
    // Beer–Lambert-style absorption in linear radiance.
    // The coefficients are art-directed, not a calibrated optical simulation.
    let transmission = exp(-vec3<f32>(0.32, 0.115, 0.075) * thickness * water_density);
    let body = horizon_srgb_to_linear(mix(vec3<f32>(0.018, 0.095, 0.115), input.tint.rgb * vec3<f32>(0.06, 0.19, 0.17), 0.22) * input.lightmap);
    // Remove only the air-fog segment between camera and water, then reapply
    // it after composing the water. Keep any residual background fog in place.
    let unfogged = max((behind - input.fog.rgb * fog) / max(1.0 - fog, 0.05), vec3<f32>(0.0));
    let transmitted = unfogged * transmission + body * (vec3<f32>(1.0) - transmission);
    let reflected = reflect(-view, normal);
    let exposure = smoothstep(0.15, 0.85, input.light.y);
    let reflectivity = (0.02 + 0.98 * pow(1.0 - ndv, 5.0)) * exposure * 0.72;
    let sky_dir = normalize(vec3<f32>(reflected.x, max(reflected.y, 0.02), reflected.z));
    let sky = aurora_sky(sky_dir, vec4<f32>(frame.sky_color, 1.0)).rgb;
    let scene_reflection = aurora_scene_reflection(input.position, reflected);
    // The snapshot already contains camera-to-hit fog. Remove only the shorter
    // camera-to-water segment, which is reapplied below to the complete surface.
    let reflected_scene = max((scene_reflection.rgb - input.fog.rgb * fog)
        / max(1.0 - fog, 0.05), vec3(0.0));
    let reflected_colour = mix(sky, reflected_scene, scene_reflection.a);
    let weather = 1.0 - clamp(frame.rain * 0.9 + frame.thunder * 0.1, 0.0, 1.0);
    let sun = pow(max(dot(reflected, frame.sun_direction), 0.0), 160.0)
        * smoothstep(0.0, 0.12, frame.sun_direction.y);
    let moon = pow(max(dot(reflected, frame.moon_direction), 0.0), 110.0)
        * smoothstep(0.0, 0.15, frame.moon_direction.y);
    let sun_colour = mix(vec3<f32>(1.0, 0.85, 0.63), vec3<f32>(1.0, 0.50, 0.23), aurora_twilight());
    let glint = (horizon_srgb_to_linear(sun_colour) * sun * 3.0 + vec3<f32>(0.20, 0.29, 0.44) * moon * 0.22) * exposure * weather;
    let colour = mix(mix(transmitted, reflected_colour, reflectivity)
        + glint * (1.0 - scene_reflection.a), input.fog.rgb, fog);
    // Algebraic difference between the SSR result and the local sky-only
    // result, after Fresnel, glint suppression, fog and the near-water fade.
    *contribution = vec4(((reflected_scene - sky) * reflectivity - glint)
        * (scene_reflection.a * (1.0 - fog) * amount), 1.0);
    let legacy_composite = mix(original, mix(fallback.rgb, input.fog.rgb, fog), fallback.a);
    return Surface(vec4<f32>(max(mix(legacy_composite, colour, amount), vec3<f32>(0.0)), 1.0), true);
}

// forest.1: stable, same-frame screen-space occlusion applied only to ambient light.
// Four fixed directions, two distances; no random rotation or temporal history.
override contact_strength: f32 = 0.70;
override contact_radius: f32 = 2.4;
override leaf_transmission: f32 = 0.65;
const CONTACT_DIRECTIONS = array<vec2<f32>, 4>(
    vec2(1.0,0.0), vec2(0.0,1.0), vec2(-1.0,0.0), vec2(0.0,-1.0)
);
fn aurora_contact_ambient(input: MaterialInput, normal: vec3<f32>) -> f32 {
    if contact_strength <= 0.0 || input.translucent || input.light.y < 0.05 { return 1.0; }
    let distance_fade = 1.0 - smoothstep(40.0, 64.0, length(input.position));
    if distance_fade <= 0.0 { return 1.0; }
    let view = (frame.view * vec4(input.position, 1.0)).xyz;
    let view_normal = (frame.view * vec4(normal, 0.0)).xyz;
    let uv_radius = min(vec2(abs(frame.projection[0][0]), abs(frame.projection[1][1]))
        * contact_radius * 0.5 / max(-view.z, 0.25), vec2(96.0) / frame.resolution);
    let depth_size = vec2<f32>(textureDimensions(contact_depth));
    var occlusion = 0.0;
    for (var i = 0; i < 4; i += 1) {
        var horizon = 0.0;
        for (var j = 1; j <= 2; j += 1) {
            let fraction = f32(j) / 2.0;
            let candidate = input.screen_uv + CONTACT_DIRECTIONS[i] * uv_radius * fraction * fraction;
            if any(candidate <= vec2(0.0)) || any(candidate >= vec2(1.0)) { continue; }
            // Reconstruct the actual texel centre, not the unsnapped query ray.
            let uv = (floor(candidate * depth_size) + vec2(0.5)) / depth_size;
            let depth = contact_depth_at(uv);
            if depth <= 0.0 { continue; }
            let sample = frame.projection_inverse * vec4(uv * vec2(2.0, -2.0) + vec2(-1.0, 1.0), depth, 1.0);
            let delta = sample.xyz / sample.w - view;
            let d = length(delta);
            if d <= 0.04 || d >= contact_radius { continue; }
            // Reject coplanar samples and distant foreground edges to avoid dark halos.
            let elevation = max((dot(view_normal, delta) - 0.035) / d - 0.08, 0.0);
            let falloff = 1.0 - smoothstep(contact_radius * 0.3, contact_radius, d);
            horizon = max(horizon, elevation * falloff);
        }
        occlusion += horizon;
    }
    let amount = min(occlusion * 0.40, 0.85) * contact_strength * distance_fade
        * select(1.0, 0.65, input.is_leaves);
    return 1.0 - amount;
}

fn aurora_leaf_light(input: MaterialInput, normal: vec3<f32>) -> f32 {
    if !input.is_leaves || leaf_transmission <= 0.0 || frame.sun_direction.y <= 0.03
        || sun_shadow.parameters.w < 0.5 { return 0.0; }
    let back = max(dot(-normal, frame.sun_direction), 0.0);
    if back <= 0.0 { return 0.0; }
    // A short offset through this leaf cell approximates thin-leaf transmission.
    // Buildings / dense canopies beyond that cell still block the sun.
    let clip = sun_shadow.matrix * vec4(input.position + frame.sun_direction * 0.65, 1.0);
    let uv = clip.xy * vec2(0.5, -0.5) + vec2(0.5);
    let texel = sun_shadow.parameters.x;
    if any(uv < vec2(texel * 2.0)) || any(uv > vec2(1.0 - texel * 2.0))
        || clip.z <= 0.0 || clip.z >= 1.0 { return 0.0; }
    var visibility = 0.0;
    for (var y = -1; y <= 1; y += 2) {
        for (var x = -1; x <= 1; x += 2) {
            visibility += textureSampleCompareLevel(sun_shadow_depth, sun_shadow_sampler,
                uv + vec2(f32(x),f32(y)) * texel * 0.5, clip.z - 0.0003 * horizon_sun_bias_scale);
        }
    }
    let forward = pow(max(dot(normalize(input.position), frame.sun_direction), 0.0), 8.0);
    let daylight = smoothstep(0.03, 0.18, frame.sun_direction.y);
    let weather = 1.0 - clamp(frame.rain * 0.8 + frame.thunder * 0.2, 0.0, 1.0);
    return leaf_transmission * back * (0.22 + 0.78 * forward) * daylight * weather
        * pow(input.light.y, 2.0) * visibility * 0.25 * 0.9;
}
