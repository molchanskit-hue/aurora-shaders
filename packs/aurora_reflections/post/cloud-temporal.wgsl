override cloud_history_strength: f32 = 0.90;

fn cloud_reference_distance(ray: vec3<f32>) -> f32 {
    let bounds = cloud_interval(frame.camera_position, ray);
    let span = max(bounds.y - bounds.x, 0.0);
    var weight = 0.0;
    var moment = 0.0;
    var transmission = 1.0;
    // Four broad-mass probes approximate the visible cloud surface rather than a
    // fixed horizontal plane. This is still a proxy, not a stored cloud-depth buffer.
    let advected_origin = frame.camera_position + cloud_drift(frame.time);
    for (var i = 0; i < 4; i += 1) {
        let lo = f32(i) / 4.0;
        let hi = f32(i + 1) / 4.0;
        let segment = span * (hi * hi - lo * lo);
        let distance = bounds.x + span * lo * lo + segment * 0.5;
        let density = cloud_bulk_density(advected_origin + ray * distance);
        let alpha = 1.0 - exp(-density * segment);
        let w = alpha * transmission;
        moment += distance * w;
        weight += w;
        transmission *= 1.0 - alpha;
    }
    return clamp(select(bounds.x + span * 0.4, moment / max(weight, 0.0001), weight > 0.01), 8.0, CLOUD_RANGE);
}

fn post(input: PostInput) -> vec4<f32> {
    let current = input.color;
    if frame.dimension != 0 || !aurora_air_or_managed_water() || input.depth > 0.0 {
        return current;
    }
    let size = vec2<f32>(textureDimensions(previous));
    let pixel = vec2<i32>(input.pixel);
    var low = current;
    var high = current;
    var total = 4.0;
    var filtered = current * total;
    // Modest opacity-aware spatial filtering covers newly exposed pixels where
    // history is invalid. Only cloud radiance/transmittance are filtered.
    for (var y = -1; y <= 1; y += 1) {
        for (var x = -1; x <= 1; x += 1) {
            if x == 0 && y == 0 { continue; }
            let p = clamp(pixel + vec2(x,y), vec2(0), vec2<i32>(size)-1);
            let uv = (vec2<f32>(p) + 0.5) / size;
            if depth_at(uv) > 0.0 { continue; }
            let sample = textureLoad(previous, p, 0);
            low = min(low, sample);
            high = max(high, sample);
            let w = exp(-abs(sample.a - current.a) * 2.0);
            filtered += sample * w;
            total += w;
        }
    }
    filtered /= total;
    if post_history.camera_delta.w < 0.5 || cloud_history_strength <= 0.0 || filtered.a > 0.9995 {
        return filtered;
    }
    let ray = normalize(view_position(input.uv, 0.00001));
    let distance = cloud_reference_distance(ray);
    let point = ray * distance + post_history.camera_delta.xyz
        + cloud_drift(post_history.clock.y) - cloud_drift(post_history.clock.x);
    let clip = post_history.previous_view_projection * vec4(point, 1.0);
    if clip.w <= 0.0 { return filtered; }
    let uv = vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    let margin = 1.5 / size;
    if any(uv < margin) || any(uv > 1.0 - margin) || history_depth_at(uv) > 0.0 { return filtered; }
    let motion = length((uv - input.uv) * size);
    if motion > 20.0 { return filtered; }
    let padding = (high - low) * 0.06 + 0.003;
    let history = clamp(textureSampleLevel(history_color, linear_sampler, uv, 0.0), low-padding, high+padding);
    let confidence = 1.0 - smoothstep(0.25, 0.70, abs(history.a - filtered.a));
    let weight = cloud_history_strength * confidence * (1.0 - smoothstep(2.0,20.0,motion));
    return mix(filtered, history, weight);
}
