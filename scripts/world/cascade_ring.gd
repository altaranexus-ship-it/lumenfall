class_name CascadeRing
extends MeshInstance3D
## AGE-27 hero shader 2/3 — District Cascade Propagation ring.
## Spawned by RekindleNode on kindle. A ground-plane wave rolls outward from
## the kindled source, tier by tier, matching the AGE-21 tier-sweep rule
## (tier N reaches nodes within propagation_radius_step * N metres).
## Zero per-frame CPU after spawn: origin/start/extent are set once, the
## shader animates from TIME alone.

const SHADER := preload("res://shaders/district_cascade.gdshader")

## Spawn an additive cascade ring on the ground at `origin` (world XZ).
## Returns the ring instance (already queued for self-cleanup), or null.
static func spawn(parent: Node, origin: Vector3, tier_radius: float, tiers: int) -> CascadeRing:
	if parent == null:
		return null
	var ring := CascadeRing.new()
	ring.name = "CascadeRing"
	# Quad big enough to cover the outermost tier band, centred on the source.
	# PlaneMesh is XZ-facing by default (normal +Y), so no extra rotation.
	var extent := tier_radius * float(tiers) + 1.0
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(extent * 2.0, extent * 2.0)
	mesh.subdivide_depth = 0
	mesh.subdivide_width = 0
	ring.mesh = mesh
	# Sit just above the floor to avoid z-fighting with the ground plane.
	var pos := Vector3(origin.x, origin.y + 0.06, origin.z)
	ring.position = pos
	# render_priority above opaque ground; transparent queue sorts back-to-front.
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.material_override = ShaderMaterial.new()
	var mat: ShaderMaterial = ring.material_override
	mat.shader = SHADER
	mat.set_shader_parameter("cascade_origin", pos)
	# Engine timebase for cascade_start: match shader TIME (seconds since scene load).
	mat.set_shader_parameter("cascade_start", float(Time.get_ticks_msec()) / 1000.0)
	mat.set_shader_parameter("tier_radius", tier_radius)
	mat.set_shader_parameter("tiers", float(tiers))
	parent.add_child(ring)
	ring._start_life(extent * 2.0)
	return ring


var _life := 0.0
var _size := 32.0


func _start_life(size_m: float) -> void:
	_size = size_m
	set_process(true)


func _process(delta: float) -> void:
	# Wave fully crosses the outermost band; hold a beat; fade quad; free.
	_life += delta
	var mat := material_override as ShaderMaterial
	if mat == null:
		queue_free()
		return
	# Visibility window: sweep time per band comes from the shader uniform
	# (0.6 s default) — total sweep = tiers * 0.6, plus afterglow + fade tail.
	var tiers := mat.get_shader_parameter("tiers") as float
	var sweep := tiers * 0.6
	if _life > sweep + 3.0:
		# Scale alpha to zero over the last second, then free.
		var fade := clampf(1.0 - (_life - (sweep + 3.0)) / 1.0, 0.0, 1.0)
		mat.set_shader_parameter("cascade_intensity", fade)
		if fade <= 0.0:
			queue_free()
