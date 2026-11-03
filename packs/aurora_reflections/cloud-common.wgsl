// Original world-space cloud banks. Shared bounds keep the marcher, history and
// foreground reconstruction consistent. World units are blocks.
override cloud_coverage: f32 = 0.52;
override cloud_density: f32 = 0.85;
const CLOUD_BASE: f32 = 160.0;
const CLOUD_TOP: f32 = 244.0;
const CLOUD_RANGE: f32 = 1800.0;

fn cloud_drift(seconds: f32) -> vec3<f32> {
    let phase = seconds * 0.001745329252;
    return vec3(sin(phase) * 370.0, 0.0, cos(phase) * 126.0);
}

// q is world position advected once per ray. Two rotated horizontal noise
// fields set the footprint of a bank and its height; there are no cell centres.
// One column describes both the volume boundary and the amount of cloud
// overhead. Reusing its ceiling for lighting keeps thin banks translucent.
fn cloud_column(q: vec3<f32>) -> vec2<f32> {
    let h = (q.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE);
    if h <= 0.0 || h >= 1.0 { return vec2(-2.0, 0.0); }
    let axis = vec2(0.8660254, 0.5);
    let along = vec2(dot(q.xz, axis), dot(q.xz, vec2(-axis.y, axis.x)));
    let broad = aurora_noise_slice(along / vec2(232.0, 155.0) + vec2(1.3, -2.7), 57);
    let warped = q.xz + vec2(38.0, -26.0) * (broad + 0.45 * h);
    let lobes = aurora_noise_slice(warped / vec2(66.0, 77.0), 33);
    let load = (broad * 0.53 + lobes * 0.47 - (0.74 - cloud_coverage * 0.49 - frame.rain * 0.09)) * 3.8;
    let bottom = 0.06 + 0.22 * (1.0 - lobes);
    let top = 0.19 + 0.76 * smoothstep(-0.22, 0.88, load);
    return vec2(min(load, min((h - bottom) * 2.9, (top - h) * 2.2)), (top - h) * (CLOUD_TOP - CLOUD_BASE));
}

fn cloud_bulk_density(q: vec3<f32>) -> f32 {
    return smoothstep(0.0, 0.76, cloud_column(q).x) * cloud_density * 0.046;
}

// Density, blocks of cloud overhead. Expensive noise is confined to the
// boundary region. Global vertical taper prevents a cut plane at slab bounds.
fn cloud_medium(q: vec3<f32>) -> vec2<f32> {
    let col = cloud_column(q);
    if col.x <= -0.52 { return vec2(0.0); }
    let h = (q.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE);
    let layer = smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(0.92, 1.0, h));
    let coarse = aurora_noise3(q / vec3(40.0, 25.0, 36.0));
    let edge = col.x + (coarse - 0.5) * 0.77;
    if edge <= -0.135 { return vec2(0.0); }
    var field = edge;
    if edge < 0.91 {
        field += (aurora_noise3(vec3(q.z + 0.3 * q.x, q.y, 0.3 * q.z - q.x) / 13.0) - 0.5) * 0.27;
    }
    let local_top = clamp(col.y + (coarse - 0.5) * 19.0, 0.0, CLOUD_TOP - q.y);
    return vec2(smoothstep(0.0, 0.77, field) * layer * cloud_density * 0.046, local_top);
}

fn cloud_interval(origin: vec3<f32>, ray: vec3<f32>) -> vec2<f32> {
    if abs(ray.y) < 0.0001 {
        if origin.y <= CLOUD_BASE || origin.y >= CLOUD_TOP { return vec2(0.0); }
        return vec2(0.0, CLOUD_RANGE);
    }
    let a = (CLOUD_BASE - origin.y) / ray.y;
    let b = (CLOUD_TOP - origin.y) / ray.y;
    return vec2(max(min(a, b), 0.0), min(max(a, b), CLOUD_RANGE));
}
