shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;
// unshaded: cascade rings are pure light events -- they must not receive scene
// lighting or shadows, and unshaded skips the whole lighting path (perf).

// ============================================================================
// LUMENFALL hero shader 2/3 -- District Cascade Propagation
// Issue: AGE-27 · Godot 4.x, gl_compatibility. Ground-plane wave that rolls
// outward from a kindled node, tier by tier (design-lock: tier N reaches
// nodes within propagation_radius_step * N metres -- GameConfig 8.0m steps).
//
// Driven entirely by shader uniforms + TIME; zero per-frame CPU after spawn:
//   CASCADE_ORIGIN : world XZ of the kindled source (set once on kindle)
//   CASCADE_START  : engine time at kindle (Time.get_ticks_msec based, set once)
//   TIER_RADIUS    : GameConfig.propagation_radius_step (design lock, 8.0)
//   TIERS          : GameConfig.propagation_tiers (design lock, 3)
// The wave front sweeps each tier band in sequence; leading edge is a hot rim,
// interior cools back to floor ash. Additive blend over the greybox floor.
//
// Perf: ~30 ALU fragment, 0 texture samples, 1 uniform-driven wave.
// ============================================================================

group_uniforms Cascade;
uniform vec3 cascade_origin = vec3(0.0);   // world XZ of source node
uniform float cascade_start = 0.0;         // seconds (engine timebase) at kindle
uniform float tier_radius = 8.0;           // GameConfig.PROPAGATION_RADIUS_STEP
uniform float tiers = 3.0;                 // GameConfig.PROPAGATION_TIERS
uniform float tier_sweep_time = 0.6;       // seconds for the front to cross one tier band

group_uniforms Palette;
uniform vec3 cascade_hot : source_color = vec3(1.0, 0.82, 0.5);
uniform vec3 cascade_mid : source_color = vec3(0.95, 0.5, 0.16);
uniform vec3 cascade_cool : source_color = vec3(0.3, 0.12, 0.06);
uniform float cascade_intensity = 1.0;

void fragment() {
	vec2 to_p = VERTEX.xz - cascade_origin.xz; // VERTEX is model space; plane node sits at world origin XZ (see integration note)
	float dist = length(to_p);

	float t = max(TIME - cascade_start, 0.0);

	// Which tier band is this pixel in? Band i covers [i*R, (i+1)*R).
	float band_f = dist / tier_radius;
	float band_i = floor(band_f);
	float in_band = clamp(band_f - band_i, 0.0, 1.0); // 0 at inner edge, 1 at outer

	// Front arrival time for this pixel's band, staggered per tier.
	float arrive = cascade_start + band_i * tier_sweep_time;
	float local_t = clamp((TIME - arrive) / tier_sweep_time, 0.0, 1.0);

	// Leading edge: hot rim just inside the front, sweeps across the band.
	float rim = smoothstep(0.0, 0.15, local_t) * (1.0 - smoothstep(0.15, 0.55, local_t));
	// Interior afterglow: cools as the front passes.
	float afterglow = (1.0 - rim) * local_t * (1.0 - local_t) * 2.2;

	// Fade the whole cascade with distance and tier count (energy conservation):
	// tier N is dimmer than the source flash -- the wave loses heat as it travels.
	float energy = cascade_intensity / (1.0 + 0.4 * band_i);
	// Kill everything beyond the last tier band (wave has left the district).
	float horizon = 1.0 - step(tiers, band_i);

	// cheap angular shimmer so the ring is not a perfect circle
	float ang = atan(to_p.y, to_p.x);
	float shimmer = 0.82 + 0.18 * sin(ang * 9.0 + TIME * 3.0 + band_i * 2.1);

	float glow = (rim * 1.0 + afterglow * 0.55) * energy * horizon * shimmer;

	// 3-stop ramp hot->mid->cool across the glow value
	float g = clamp(glow, 0.0, 1.2);
	vec3 col = (g < 0.5) ? mix(cascade_cool, cascade_mid, g * 2.0)
						: mix(cascade_mid, cascade_hot, clamp(g * 2.0 - 1.0, 0.0, 1.0));

	// Radial alpha so the quad edge never shows a hard seam.
	float edge_fade = 1.0 - smoothstep(tiers * tier_radius * 0.85, tiers * tier_radius, dist);

	ALBEDO = col;
	ALPHA = clamp(glow, 0.0, 1.0) * edge_fade;
	// PREMULTIPLY not needed; blend_mix with additive-feel via bright unshaded color.
	EMISSION = col * glow * 0.5;
}
