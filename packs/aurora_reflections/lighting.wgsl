override shadow_strength: f32 = 0.90;
override lighting_strength: f32 = 1.0;
override night_lift: f32 = 0.85;
// Linear blending lifts dark surfaces more strongly than the old display-space mix.
override haze_strength: f32 = 0.15;

fn aurora_surface_haze(colour: vec3<f32>, position: vec3<f32>, sky_light: f32) -> vec3<f32> {
    let distance = length(position);
    let distance_fraction = max(distance - 24.0, 0.0) / max(frame.render_distance, 64.0);
    let air = 1.0 - exp(-distance_fraction * 1.8);
    let daylight_haze = mix(vec3<f32>(0.67, 0.77, 0.86), vec3<f32>(0.93, 0.64, 0.43), aurora_twilight() * 0.8);
    let haze_colour = mix(vec3<f32>(0.055, 0.075, 0.12), daylight_haze, aurora_day());
    // The visible surface's interpolated skylight gates haze. Camera light would
    // brighten an unlit cave when viewed from outdoors and pop at block boundaries.
    let exposed = smoothstep(0.10, 0.65, sky_light);
    let amount = min(air * haze_strength, 0.45) * aurora_fog_visibility(distance)
        * (1.0 - aurora_immersion()) * exposed * aurora_effect_visibility() * (1.0 - frame.rain * 0.65)
        * (1.0 - clamp(frame.night_vision, 0.0, 1.0));
    return mix(colour, horizon_srgb_to_linear(haze_colour), amount);
}

fn aurora_surface_light_forest(base_albedo: vec3<f32>, normal: vec3<f32>, light: vec2<f32>, ambient_occlusion: f32, visibility: f32, contact: f32, transmission: f32) -> vec3<f32> {
    let day = aurora_day();
    let dusk = aurora_twilight();
    let weather = 1.0 - clamp(frame.rain * 0.8 + frame.thunder * 0.2, 0.0, 1.0);
    let sky_access = pow(clamp(light.y, 0.0, 1.0), 3.0);
    let local_access = pow(clamp(light.x, 0.0, 1.0), 4.0);
    let ao = pow(clamp(ambient_occlusion, 0.0, 1.0), 1.15);
    let up = clamp(normal.y * 0.5 + 0.5, 0.0, 1.0);

    // Diffuse hemisphere illumination, in linear light. AO affects the sky
    // and bounce approximation, not the strength of a directly visible sun.
    let sky_colour = mix(vec3(0.38, 0.55, 1.0), vec3(0.68, 0.79, 1.0), day);
    let sky_power = mix(0.095 * night_lift, 0.26, day);
    let sky_fill = sky_colour * sky_access * sky_power * mix(0.42, 1.0, up) * ao * contact;
    let ground_fill = vec3(0.13, 0.115, 0.085) * sky_access * day * (1.0 - up * 0.55) * ao * contact;
    let cave_floor = vec3(0.0015 + 0.004 * clamp(frame.brightness, 0.0, 1.0)) * ao;

    let incidence = max(dot(normal, frame.sun_direction), 0.0);
    let solar = smoothstep(-0.015, 0.12, frame.sun_direction.y);
    let direct_weight = incidence * solar * weather * smoothstep(0.35, 0.90, light.y);
    let sun_colour = mix(vec3(1.0, 0.93, 0.80), vec3(1.0, 0.54, 0.27), dusk * 0.8);
    let sunlight = sun_colour * 1.28 * direct_weight * mix(1.0, visibility, shadow_strength);
    // Block-light level has no source colour/type in this API. This is a warm
    // approximation; it includes the engine's dynamic handheld light level.
    let local = vec3(1.0, 0.68, 0.38) * local_access * 1.65 * mix(0.65, 1.0, ao);
    let albedo = horizon_srgb_to_linear(clamp(base_albedo, vec3(0.0), vec3(1.0)));
    let radiance = albedo * (sky_fill + ground_fill + cave_floor + sunlight + local + sun_colour * transmission);
    return max(radiance, vec3(0.0));
}

fn aurora_direct_weight(normal: vec3<f32>, sky_light: f32) -> f32 {
    let weather = 1.0 - clamp(frame.rain * 0.8 + frame.thunder * 0.2, 0.0, 1.0);
    return max(dot(normal, frame.sun_direction), 0.0) * smoothstep(-0.015, 0.12, frame.sun_direction.y)
        * weather * smoothstep(0.35, 0.90, sky_light);
}

// Models share the linear lighting calculation; only semantic leaf terrain transmits.
fn aurora_surface_light(base_albedo: vec3<f32>, normal: vec3<f32>, light: vec2<f32>, ambient_occlusion: f32, visibility: f32) -> vec3<f32> {
    return aurora_surface_light_forest(base_albedo, normal, light, ambient_occlusion, visibility, 1.0, 0.0);
}
