fn post(input: PostInput) -> vec4<f32> {
    return vec4(display(input.color.rgb), input.color.a);
}
