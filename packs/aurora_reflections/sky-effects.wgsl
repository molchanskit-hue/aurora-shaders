// Original procedural sky. No image assets or shader code from another pack.
override celestial_size: f32 = 1.0;
override aurora_strength: f32 = 0.65;
override aurora_steps: i32 = 10;

fn aurora_hash3(cell: vec3<i32>) -> f32 {
    let c = bitcast<vec3<u32>>(cell);
    var h = (c.x * 1597334677u) ^ (c.y * 3812015801u) ^ (c.z * 2798796415u);
    h = (h ^ (h >> 16u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    return f32((h ^ (h >> 16u)) >> 8u) / 16777216.0;
}

fn aurora_noise3(p: vec3<f32>) -> f32 {
    let c = vec3<i32>(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(aurora_hash3(c), aurora_hash3(c + vec3(1, 0, 0)), u.x);
    let b = mix(aurora_hash3(c + vec3(0, 1, 0)), aurora_hash3(c + vec3(1, 1, 0)), u.x);
    let d = mix(aurora_hash3(c + vec3(0, 0, 1)), aurora_hash3(c + vec3(1, 0, 1)), u.x);
    let e = mix(aurora_hash3(c + vec3(0, 1, 1)), aurora_hash3(c + vec3(1, 1, 1)), u.x);
    return mix(mix(a, b, u.y), mix(d, e, u.y), u.z);
}

// The curtain uses integer Y slices of noise3. Four corner hashes give the
// exact same value as eight-corner 3D noise, without evaluating the unused plane.
fn aurora_noise_slice(p: vec2<f32>, y: i32) -> f32 {
    let c = vec2<i32>(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(aurora_hash3(vec3(c.x, y, c.y)),
        aurora_hash3(vec3(c.x + 1, y, c.y)), u.x);
    let b = mix(aurora_hash3(vec3(c.x, y, c.y + 1)),
        aurora_hash3(vec3(c.x + 1, y, c.y + 1)), u.x);
    return mix(a, b, u.y);
}

fn aurora_celestials(ray: vec3<f32>) -> vec3<f32> {
    let aa = 1.5 / max(frame.resolution.y, 1.0);
    let sun_radius = 0.022 * celestial_size;
    let sun_distance = length(ray - frame.sun_direction);
    let sun = 1.0 - smoothstep(sun_radius - aa, sun_radius + aa, sun_distance);
    let sun_colour = mix(vec3(1.0, 0.48, 0.16), vec3(1.0, 0.95, 0.78),
        smoothstep(0.0, 0.28, frame.sun_direction.y));
    var light = horizon_srgb_to_linear(sun_colour) * sun * 6.0;

    let radius = 0.027 * celestial_size;
    let right = normalize(cross(vec3(0.0, 0.0, 1.0), frame.moon_direction));
    let up = cross(frame.moon_direction, right);
    let q = vec2(dot(ray, right), dot(ray, up)) / radius;
    let distance = length(ray - frame.moon_direction);
    let disc = 1.0 - smoothstep(radius - aa, radius + aa, distance);
    if disc > 0.0 {
        let normal = vec3(q, sqrt(max(1.0 - dot(q, q), 0.0)));
        let phase = frame.atmosphere.x * 0.7853981634;
        let illumination = smoothstep(-0.03, 0.05, dot(normal, vec3(sin(phase), 0.0, cos(phase))));
        let surface = 0.66 + 0.34 * aurora_noise3(vec3(q * 5.0, 7.0));
        light += horizon_srgb_to_linear(vec3(0.70, 0.82, 1.0)) * surface * (0.025 + 0.95 * illumination) * disc;
    }
    return light * smoothstep(-0.025, 0.035, ray.y) * (1.0 - frame.rain) * (1.0 - frame.thunder);
}

// Folded north-facing emission sheets. The vertical profile is continuous;
// quality samples integrate thickness rather than discrete altitude bands.
fn aurora_fold(x: f32, sheet: f32, phase: f32) -> vec2<f32> {
    let a = x * 0.0013 + phase + sheet * 2.1;
    let b = x * 0.0036 - phase * 1.4 + sheet;
    return vec2(sin(a) * 300.0 + sin(b) * 80.0,
        cos(a) * 0.39 + cos(b) * 0.288);
}

fn aurora_curtains(ray: vec3<f32>) -> vec3<f32> {
    let night = 1.0 - smoothstep(-0.30, -0.10, frame.sun_direction.y);
    let visibility = night * smoothstep(0.02, 0.18, ray.y)
        * smoothstep(0.18, 0.55, -ray.z) * (1.0 - frame.rain) * (1.0 - frame.thunder);
    if visibility < 0.001 || aurora_strength < 0.001 { return vec3(0.0); }
    let clock = frame.time * 0.001745329252;
    let phase = sin(clock * 7.0) * 0.65 + cos(clock * 3.0) * 0.25;
    var colour = vec3(0.0);
    // Upper-atmosphere curtains remain north of the observer across the world.
    // Horizontal parallax is intentionally neglected at this artistic sky scale.
    let origin = vec3(0.0, frame.camera_position.y, 0.0);
    for (var sheet = 0; sheet < 2; sheet += 1) {
        let layer = f32(sheet);
        let base_z = -2600.0 - layer * 950.0;
        // The full folded sheet plus its finite 100-block thickness. Clip in
        // height too, so empty sky never evaluates filament noise.
        let near_distance = max(0.0, max((base_z + 480.0) / ray.z,
            (1105.0 + layer * 120.0 - origin.y) / ray.y));
        let far_distance = min((base_z - 480.0) / ray.z,
            (2375.0 + layer * 320.0 - origin.y) / ray.y);
        if far_distance <= near_distance { continue; }
        // Integrate the whole volume instead of choosing a Newton root. A ray
        // can cross several folds; tangencies must fade continuously as well.
        let span = far_distance - near_distance;
        let steps = i32(ceil(span / (240.0 / f32(aurora_steps))));
        let step_size = span / f32(steps);
        for (var i = 0; i < steps; i += 1) {
            let distance = near_distance + (f32(i) + 0.5) * step_size;
            let p = origin + ray * distance;
            let fold = aurora_fold(p.x, layer, phase);
            let sample = (p.z - base_z - fold.x) / 100.0;
            if abs(sample) >= 1.0 {
                // |d residual / dt| <= |ray.z| + (0.39 + 0.288) * |ray.x|.
                // Skip only midpoint samples proven outside the finite sheet;
                // this retains the integration lattice inside every fold.
                let bound = abs(ray.z) + 0.68 * abs(ray.x);
                let empty_distance = max(0.0, (abs(sample) - 1.0) * 100.0 - 0.01) / bound;
                i += max(0, i32(floor(empty_distance / step_size)) - 1);
                continue;
            }
            let base = 1190.0 + sin(p.x * 0.0018 + phase + layer) * 85.0 + layer * 120.0;
            let h = (p.y - base) / (1100.0 + layer * 200.0);
            if h <= 0.0 || h >= 1.0 { continue; }
            let x = p.x + sin(phase * 1.3 + h * 2.0) * h * 28.0;
            let strands = aurora_noise_slice(vec2(x * 0.028, sin(clock * 9.0) * 3.0), sheet * 7);
            let fine = aurora_noise_slice(vec2(x * 0.082, cos(clock * 11.0) * 3.0), sheet * 11 + 3);
            let filaments = 0.22 + 0.78 * pow(strands * 0.7 + fine * 0.3, 1.4);
            let envelope = smoothstep(0.0, 0.045, h) * exp(-h * 3.1)
                * (1.0 - smoothstep(0.70, 1.0, h));
            let green = vec3(0.08, 0.82, 0.32);
            let upper = mix(vec3(0.06, 0.40, 0.53), vec3(0.43, 0.13, 0.48), smoothstep(0.35, 0.95, h));
            let tint = mix(green, upper, smoothstep(0.10, 0.85, h));
            let thickness = exp(-sample * sample * 3.0)
                * (1.0 - smoothstep(0.85, 1.0, abs(sample)));
            let slope = abs(ray.z - fold.y * ray.x);
            colour += tint * filaments * envelope * thickness
                * (1.0 - layer * 0.40) * min(1.0, 1.8 * slope) * step_size / 200.0;
        }
    }
    return colour * visibility * aurora_strength * 1.65;
}
