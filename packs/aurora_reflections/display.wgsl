// One display transform for the final world pass and the first-person hand.
// All inputs are scene-linear; do not apply this before bloom/refraction.
override exposure: f32 = 0.95;
override colour_strength: f32 = 0.75;
fn display(radiance: vec3<f32>) -> vec3<f32> {
    let c = max(radiance, vec3(0.0)) * exposure;
    let peak = max(c.r, max(c.g, c.b));
    // A smooth shoulder with unit slope at its join. Scale all channels together
    // to preserve hue; finite highlights approach display white without clipping.
    let mapped = select(peak, 0.5 + 0.5 * (1.0 - exp(-(peak - 0.5) / 0.5)), peak > 0.5);
    let linear = c * mapped / max(peak, 0.000001);
    var encoded = horizon_linear_to_srgb(linear);
    let graded = mix(vec3(aurora_luma(encoded)), encoded, 1.02);
    let curve = graded + 0.045 * graded * (1.0 - graded) * (2.0 * graded - 1.0);
    encoded = mix(encoded, curve, colour_strength * aurora_effect_visibility());
    return clamp(encoded, vec3(0.0), vec3(1.0));
}
