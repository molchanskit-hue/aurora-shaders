override sunset_strength: f32 = 0.85;

fn aurora_sky(direction: vec3<f32>, original: vec4<f32>) -> vec4<f32> {
    // Preserve Horizon's environment colours outside ordinary Overworld air.
    if frame.dimension != 0 || !aurora_air_or_managed_water() {
        return vec4(horizon_srgb_to_linear(original.rgb), original.a);
    }
    let height = max(direction.y, 0.0);
    let horizon = exp(-height * 2.8);
    let day = mix(vec3<f32>(0.20, 0.42, 0.72), vec3<f32>(0.63, 0.78, 0.88), horizon);
    let night = mix(vec3<f32>(0.015, 0.027, 0.065), vec3<f32>(0.055, 0.075, 0.13), horizon);
    var colour = mix(night, day, aurora_day());

    // A broad warm band follows the sun; the opposite horizon keeps a violet dusk.
    let facing_sun = smoothstep(-0.45, 0.85, dot(direction, frame.sun_direction));
    let twilight_colour = mix(vec3<f32>(0.52, 0.37, 0.57), vec3<f32>(1.0, 0.49, 0.22), facing_sun);
    let twilight = aurora_twilight() * sunset_strength * exp(-height * 2.4);
    colour = mix(colour, twilight_colour, twilight);

    // Angular halo in the sky only; clouds and terrain are drawn over it by Horizon.
    let halo = pow(max(dot(direction, frame.sun_direction), 0.0), 48.0);
    colour += vec3<f32>(1.0, 0.72, 0.42) * halo
        * (0.025 + 0.10 * aurora_twilight()) * aurora_day() * (1.0 - frame.rain);

    // Keep the engine's fog at the join to the horizon; rain/effects retain vanilla cues.
    colour = mix(frame.fog_color, colour, smoothstep(-0.02, 0.055, direction.y));
    let weather = clamp(frame.rain * 0.8 + frame.thunder * 0.2, 0.0, 1.0);
    let effects = max(frame.blindness, max(frame.darkness, frame.night_vision));
    colour = mix(colour, original.rgb, max(weather, effects));
    colour = horizon_srgb_to_linear(colour);
    colour += (aurora_celestials(direction) + aurora_curtains(direction)) * aurora_effect_visibility();
    return vec4<f32>(max(colour, vec3<f32>(0.0)), 1.0);
}
