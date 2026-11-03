fn sky(input: SkyInput) -> vec4<f32> {
    return aurora_sky(input.direction, input.color);
}
