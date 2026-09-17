shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;
// unshaded chosen at runtime by FLAME (see uniform hints); kept shaded default so
// the beacon body still receives scene light (rekindle world-light coupling).

// ============================================================================
// LUMENFALL hero shader 1/3 -- Rekindle Pulse
// Issue: AGE-27 (shader lookdev) · Engine: Godot 4.x (gl_compatibility target)
// Perf budget: 60fps @1080p GTX1060 / Apple M1. Compatibility-safe: no arrays,
// no loops over uniform counts, ~40 ALU in fragment worst case, 0 samples.
//
// Visual language (AGE-18 GDD): "quiet warm agency" -- a dormant world waiting
// for the last lamplighter. DORMANT = cold, faint ember under ash. CARRYING =
// waking warmth, anticipation shimmer. KINDLED = settled incandescent bloom.
//
// Integration contract (RekindleNode drives via material instance):
//   state -> uniform int  (0=DORMANT 1=CARRYING 2=KINDLED)
//   kindle hold progress (0..1) -> uniform float KINDLE_PROGRESS
//   propagation tier (0..N, 0 = source node) -> uniform float TIER
//   Time is TIME (engine-provided). No per-frame CPU writes besides the above.
// ============================================================================

group_uniforms Lookdev;
// Flame dyes: candle-orange core into warm ember rim. 3-stop ramp, no texture.
uniform vec3 ember_core : source_color = vec3(1.0, 0.86, 0.55);
uniform vec3 ember_mid : source_color = vec3(1.0, 0.62, 0.24);
uniform vec3 ember_rim : source_color = vec3(0.55, 0.16, 0.05);
// Ash skin of the dormant beacon.
uniform vec3 ash_color : source_color = vec3(0.11, 0.10, 0.115);
// Height band of the pulse sweep in object space (beacon is ~2.2m tall, origin at base).
uniform float pulse_height = 1.1; // metres, centre of the rising pulse
uniform float pulse_band = 0.9;   // metres, half-height of the sweep band

group_uniforms State;
uniform int lumen_state = 0;        // 0 DORMANT, 1 CARRYING, 2 KINDLED (RekindleNode.RState)
uniform float kindle_progress = 0.0; // 0..1 hold progress (CARRYING), freezes at 1 on kindle
uniform float tier = 0.0;            // 0 = source node, 1..N = propagated tiers
uniform float pulse_speed = 0.45;    // cycles/sec of the rising pulse (D6 lookdev)

group_uniforms Debug;
uniform float flame_debug = 0.0; // 1 = pure flame output (lookdev captures)

// --- cheap hash/noise: 2D value noise, 2 octaves, zero textures -------------
vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i).x;
	float b = hash2(i + vec2(1.0, 0.0)).x;
	float c = hash2(i + vec2(0.0, 1.0)).x;
	float d = hash2(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float ember_noise(vec2 p) {
	// 2 octaves is the measured sweet spot for wobble at 60fps budget.
	return 0.65 * vnoise(p) + 0.35 * vnoise(p * 2.13 + 17.7);
}

void fragment() {
	// Object-space up (Godot model-space Y). OBJ-space UV built from VERTEX
	// (model space) so the pulse rises in world terms regardless of node scale.
	float h = VERTEX.y; // metres from node base (beacon origin at base)

	// --- rising pulse band -------------------------------------------------
	float t = TIME * pulse_speed;
	float phase = fract(t + 0.17 * tier); // tiers lag slightly: visible cascade
	// band centre rises base->top each cycle
	float band_c = pulse_height - pulse_band + phase * (2.0 * pulse_band);
	float band = 1.0 - clamp(abs(h - band_c) / pulse_band, 0.0, 1.0);
	// soften edges, sharpen crest
	band = band * band * (3.0 - 2.0 * band);

	// --- flicker (wobble of the band and of the whole emission) ------------
	// domain-wobbled noise sampled on (height, time) -- cheap 2D instead of 3D
	float wob = ember_noise(vec2(h * 1.7, t * 2.4));
	float flicker = 0.85 + 0.30 * wob;

	// --- state mixing -------------------------------------------------------
	float dormant_w = 1.0 - float(lumen_state != 0); // 1 when DORMANT
	float kindled_w = float(lumen_state == 2);
	float carrying_w = float(lumen_state == 1);

	// ember veins in the ash: crack noise, visible faintly when dormant
	float veins = ember_noise(vec2(VERTEX.x, VERTEX.z) * 3.1 + h * 2.0);
	veins = smoothstep(0.55, 0.85, veins);

	// pulse amplitude by state: dormant = faint ember, carrying = anticipation,
	// kindled = full incandescent sweep
	float amp = dormant_w * 0.18 + carrying_w * (0.35 + 0.65 * kindle_progress) + kindled_w * 1.0;
	// tiers decay the pulse so the cascade reads outward
	amp *= 1.0 / (1.0 + 0.35 * tier);

	// --- compose emission ---------------------------------------------------
	// ramp position: veins glow dormant, band dominates lit states
	float ramp = clamp(veins * dormant_w + band * amp * flicker + 0.04 * flicker, 0.0, 1.5);
	vec3 flame_col = (ramp < 0.5)
		? mix(ember_rim, ember_mid, ramp * 2.0)
		: mix(ember_mid, ember_core, clamp(ramp * 2.0 - 1.0, 0.0, 1.0));
	vec3 ash = ash_color * (0.55 + 0.45 * vnoise(vec2(VERTEX.x, VERTEX.z) * 6.3));

	vec3 emission = ash * dormant_w * (1.0 - band * 0.4) + flame_col * ramp;

	// ALBEDO: ash skin everywhere; emission carries the light story.
	ALBEDO = ash;
	ROUGHNESS = 0.85;
	SPECULAR = 0.15;
	EMISSION = emission;

	// FLAME debug/lookdev mode: pure additive flame, no PBR terms.
	// (RekindleNode sets this on the FlameMesh material only.)
	if (flame_debug > 0.5) {
		float core = clamp(ramp * 1.4, 0.0, 1.0);
		ALBEDO = flame_col * core;
		EMISSION = flame_col * (0.6 + 1.6 * ramp);
		ROUGHNESS = 1.0;
	}
}
