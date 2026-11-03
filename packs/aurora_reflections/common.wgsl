// Shared by terrain and model shadow receivers.
override shadow_tent_radius: i32 = 8;

// Shared math. Horizon injects Frame and the stage-specific input types.
fn aurora_luma(rgb: vec3<f32>) -> f32 {
    return dot(rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn aurora_day() -> f32 {
    return smoothstep(-0.16, 0.12, frame.sun_direction.y);
}

fn aurora_twilight() -> f32 {
    let elevation = frame.sun_direction.y;
    return (1.0 - smoothstep(0.10, 0.50, abs(elevation)))
        * smoothstep(-0.25, -0.04, elevation)
        * (1.0 - frame.rain * 0.8);
}

fn aurora_effect_visibility() -> f32 {
    return 1.0 - clamp(max(frame.blindness, frame.darkness), 0.0, 1.0);
}

fn aurora_fog_visibility(distance: f32) -> f32 {
    let end = max(frame.fog_end, 1.0);
    let start = clamp(frame.fog_start, 0.0, max(end - 1.0, 0.0));
    return 1.0 - smoothstep(start, end, distance);
}

// Normalized, symmetric nine-tap Gaussian kernel (centre, then distances 1..4).
const AURORA_BLUR: array<f32, 5> = array<f32, 5>(
    0.2270270270, 0.1945945946, 0.1216216216, 0.0540540541, 0.0162162162
);

// The engine retains native fog for unsupported dimensions and status effects.
fn aurora_immersion() -> f32 { return clamp(frame.water.x * frame.water.y, 0.0, 1.0); }
fn aurora_air_or_managed_water() -> bool {
    return frame.eye_in == 0u || (frame.eye_in == 1u && frame.water.y > 0.5);
}
