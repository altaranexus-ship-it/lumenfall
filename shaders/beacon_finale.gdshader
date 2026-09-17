shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;
// unshaded + no lighting path: the beacon finale IS the light source of its
// scene moment. All cost goes into the fragment look; ~60 ALU worst case.

// ============================================================================
// LUMENFALL hero shader 3/3 -- Beacon Finale
// Issue: AGE-27 · Godot 4.x, gl_compatibility. Climax shader for the beacon
// column at the end of the vertical slice (v3 MASTERY puzzle payoff).
//
// Story beat (AGE-18 taxonomy): the last node kindles -> the whole Aerie
// answers. The dormant grey column ignites from the player's touchpoint and
// floods upward: ignition sweep -> full-column incandescence -> settled
// slow-breathing beacon that anchors the district skyline.
//
//   state -> uniform int  (0=DORMANT 1=CARRYING 2=KINDLED, mirrors RekindleNode.RState)
//
// Perf: no loops, no arrays, 3 noise fetches, 0 texture samples.
// ============================================================================

group_uniforms Lookdev;
uniform vec3 core_white : source_color = vec3(1.0, 0.95, 0.82);
uniform vec3 flame_orange : source_color = vec3(1.0, 0.6, 0.2);
uniform vec3 deep_ember : source_color = vec3(0.45, 0.1, 0.03);
uniform vec3 stone_cold : source_color = vec3(0.09, 0.085, 0.1);
// Column height in metres (sweep scheduling scales with it).
uniform float column_height = 18.0;

group_uniforms State;
uniform float ignite = 0.0;  // 0 dormant -> 1 fully lit
uniform float charge = 0.0;  // optional pre-beat gathering 0..1
uniform float breathe_speed = 0.4; // settled-state breathing cycles/sec

group_uniforms Debug;
uniform float finale_debug = 0.0; // 1 = ignore scene lights entirely (lookdev)

// --- same cheap 2D value noise family as the other two heroes (consistency) --
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
	return 0.65 * vnoise(p) + 0.35 * vnoise(p * 2.13 + 17.7);
}

void fragment() {
	float h = VERTEX.y;                              // metres up the column
	float hn = clamp(h / column_height, 0.0, 1.0);   // normalized height 0..1
	float t = TIME;

	// --- ignition sweep: flame front races bottom -> top as IGNITE rises ----
	float front = ignite * (1.0 + 0.15) - hn;        // front passes each height
	float swept = smoothstep(0.0, 0.12, front);      // 0 below front, 1 above
	// scorch rim just behind the front -- the "catching" moment
	float rim = smoothstep(0.0, 0.05, front) * (1.0 - smoothstep(0.05, 0.2, front));

	// --- living flame texture (2 octaves, domain uses height+time) ----------
	float flame = ember_noise(vec2(h * 0.8 - t * 1.6, atan(VERTEX.x, VERTEX.z) * 1.4 + t * 0.35));
	flame = smoothstep(0.32, 0.78, flame);

	// --- charge beat: rising motes gathering at the touchpoint --------------
	float motes = ember_noise(vec2(h * 3.0, t * 2.2));
	motes = smoothstep(0.6, 0.95, motes) * charge;

	// --- settled breathing: slow luminance tide after full ignition ---------
	float breathe = 0.88 + 0.12 * sin(t * breathe_speed * 6.2831 - hn * 2.2);

	// --- compose ------------------------------------------------------------
	// dormant stone gets a faint cold response when charged (anticipation)
	vec3 stone = stone_cold * (0.7 + 0.3 * vnoise(vec2(VERTEX.x, VERTEX.z) * 5.0))
				+ deep_ember * motes * 0.6;

	// flame column color: white-hot core low, orange body, ember fade at top
	vec3 flame_col = mix(flame_orange, core_white, clamp((0.55 - hn) * 1.8, 0.0, 1.0));
	flame_col = mix(deep_ember, flame_col, hn * 1.6 + 0.25);

	float body = swept * flame * breathe;
	float energy = body * (0.55 + 0.45 * ignite) + rim * 1.6 + motes * 0.8;
	// extra surge right at full ignition (the beat the player remembers)
	float surge = smoothstep(0.92, 1.0, ignite) * (0.4 + 0.3 * sin(t * 9.0)) * (1.0 - hn * 0.4);

	vec3 emission = stone + flame_col * energy + core_white * surge * hn * 0.6;

	// final alpha stays 1 -- column is opaque; the look is all emission.
	ALBEDO = mix(stone, flame_col * 0.35, body * 0.5);
	EMISSION = emission;
	ROUGHNESS = 0.9;

	if (finale_debug > 0.5) {
		ALBEDO = vec3(0.0);
		EMISSION = flame_col * energy * 1.4 + core_white * surge;
	}
}
