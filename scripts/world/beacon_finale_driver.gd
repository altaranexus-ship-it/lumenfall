class_name BeaconFinaleDriver
extends RefCounted
## AGE-27 hero shader 3/3 — Beacon Finale wiring.
## Drives the beacon_finale.gdshader on a beacon column mesh via one uniform,
## mapped from the RekindleNode state machine (single source of truth):
##   DORMANT/CARRYING -> ignite 0 (stone; CARRYING raises the mote charge beat)
##   KINDLED          -> ignite tweens 0 -> 1 (sweep + surge + settled breathing)
## One-shot tween per transition; zero per-frame CPU outside tweens.

const SHADER := preload("res://shaders/beacon_finale.gdshader")

var _mat: ShaderMaterial
var _tween: Tween
var _charge: float = 0.0


## Build the ShaderMaterial for a beacon column mesh (call once at _ready).
static func material_for(mesh: MeshInstance3D, column_height: float) -> BeaconFinaleDriver:
	var d := BeaconFinaleDriver.new()
	d._mat = ShaderMaterial.new()
	d._mat.shader = SHADER
	d._mat.set_shader_parameter("column_height", column_height)
	mesh.material_override = d._mat
	return d


## React to a RekindleNode state transition.
func on_state(state: int, kindle_time: float) -> void:
	if _mat == null:
		return
	match state:
		0: # DORMANT
			_set_charge(0.0)
			_animate_ignite(0.0, 0.8)
		1: # CARRYING — gathering beat: motes rise on the dormant stone
			_set_charge(1.0)
		2: # KINDLED — the payoff beat
			_set_charge(0.0)
			_animate_ignite(1.0, maxf(kindle_time * 0.8, 1.0))


func _set_charge(v: float) -> void:
	_charge = v
	if _mat != null:
		_mat.set_shader_parameter("charge", v)


func _animate_ignite(target: float, dur: float) -> void:
	# Tweens need the SceneTree; run via the material's engine-time fallback if
	# we ever lack one (headless probe) — the shader is TIME-driven regardless.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_mat.set_shader_parameter("ignite", target)
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	# The material is shared per mesh; animate a proxy holder via the tween on
	# a method — set_shader_parameter directly, step-interpolated by Tween.
	_tween = tree.create_tween()
	_tween.tween_method(func(v: float) -> void:
		if _mat != null:
			_mat.set_shader_parameter("ignite", v),
		_mat.get_shader_parameter("ignite") as float, target, dur)
