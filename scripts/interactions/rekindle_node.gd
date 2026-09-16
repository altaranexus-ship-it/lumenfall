class_name RekindleNode
extends StaticBody3D
## The heart of LUMENFALL: a dormant beacon the player kindles with carried light.
## Design-locked state machine (AGE-18 core-loop-spec v1.0):
##   DORMANT -> CARRYING -> KINDLED  (DIMMING ships in v2, gated by GameConfig)
## All tunables are design-locked; local copies that drift from GameConfig warn.

signal state_changed(node_id: String, new_state: String)
signal kindled(node_id: String)
signal kindle_progress_changed(ratio: float)

enum RState { DORMANT, CARRYING, KINDLED }

@export var node_id := "rekindle_01"
@export var start_kindled := false

# design-lock mirrors (warned against GameConfig at ready)
@export var kindle_time := 1.2
@export var dim_time := 6.0
@export var propagation_tiers := 3
@export var propagation_radius_step := 8.0  # tier N reaches nodes within step * N metres

const STATE_NAMES := {RState.DORMANT: "DORMANT", RState.CARRYING: "CARRYING", RState.KINDLED: "KINDLED"}

var state: int = RState.DORMANT
var _hold_time := 0.0
var _dim_left := 0.0

@onready var _flame: OmniLight3D = $Flame
@onready var _beacon_mesh: MeshInstance3D = $BeaconMesh
@onready var _flame_mesh: MeshInstance3D = $FlameMesh
@onready var _area: Area3D = $Area


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("rekindle")
	if kindle_time != GameConfig.KINDLE_TIME:
		push_warning("RekindleNode %s: kindle_time drifts from design lock." % node_id)
	if propagation_tiers != GameConfig.PROPAGATION_TIERS:
		push_warning("RekindleNode %s: propagation_tiers drifts from design lock." % node_id)
	if dim_time != GameConfig.DIM_TIME:
		push_warning("RekindleNode %s: dim_time drifts from design lock." % node_id)
	if start_kindled:
		_set_state(RState.KINDLED)
	else:
		_set_state(RState.DORMANT)
	_appear()


func _process(delta: float) -> void:
	if state == RState.CARRYING:
		_appear()
		var holding := Input.is_action_pressed("interact")
		if holding:
			_hold_time += delta
			kindle_progress_changed.emit(clampf(_hold_time / GameConfig.KINDLE_TIME, 0.0, 1.0))
			if _hold_time >= GameConfig.KINDLE_TIME:
				_complete_kindle()
		else:
			_hold_time = 0.0
			kindle_progress_changed.emit(0.0)
	elif state == RState.KINDLED:
		_flame.light_energy = 1.4 + 0.25 * sin(Time.get_ticks_msec() * 0.004)
		if GameConfig.DIMMING_ENABLED:
			# v2 path; harmless in v1 since the flag is false
			_dim_left -= delta
			if _dim_left <= 0.0:
				_set_state(RState.DORMANT)


func get_prompt(carrier: Node) -> String:
	match state:
		RState.DORMANT:
			return "Kindle (hold E)" if carrier != null and carrier.has_method("is_carrying") and carrier.is_carrying() else "Needs lumen"
		RState.CARRYING:
			return "Kindle (hold E)"
		_:
			return ""


func can_focus(_carrier: Node) -> bool:
	return state != RState.KINDLED


## Entry point when the player offers their lumen (from LightCarrier via Interactable).
func receive_lumen(carrier: Node) -> bool:
	if state != RState.DORMANT:
		return false
	if not carrier.has_method("consume_lumen") or not carrier.consume_lumen():
		return false
	_set_state(RState.CARRYING)
	_hold_time = 0.0
	return true


func _complete_kindle() -> void:
	_set_state(RState.KINDLED)
	_dim_left = GameConfig.DIM_TIME
	# Expanding wave from the SOURCE: tier N lights every dormant node within
	# propagation_radius_step * N metres of this node (design-lock: "tier N
	# reaches nodes within step * N metres"). A hop-only chain dies when no
	# node sits inside tier 1, so the wave widens from the source instead.
	for tier in range(1, GameConfig.PROPAGATION_TIERS + 1):
		_propagate_light(tier, GameConfig.PROPAGATION_TIERS)
	var tree := get_tree()
	if tree != null:
		var checkpoint := tree.get_first_node_in_group("checkpoint")
		if checkpoint != null and checkpoint.has_method("notify_kindled"):
			checkpoint.notify_kindled()


## Kindling propagates through nearby dormant nodes, tier by tier.
func _propagate_light(tier: int, max_tiers: int) -> void:
	if tier > max_tiers:
		return
	var tree := get_tree()
	if tree == null:
		return
	for other in tree.get_nodes_in_group("rekindle"):
		if other == self or not (other is RekindleNode):
			continue
		if other.state == RState.DORMANT and global_position.distance_to(other.global_position) <= propagation_radius_step * float(tier):
			other.receive_ambient_grace(tier, max_tiers)


## v1: propagation grants CARRYING grace (a lit wick, waiting for the hold).
func receive_ambient_grace(tier: int, max_tiers: int) -> void:
	if state != RState.DORMANT:
		return
	_set_state(RState.CARRYING)
	_hold_time = 0.0
	# chain continues outward without needing the player
	_propagate_from.call_deferred(tier + 1, max_tiers)


func _propagate_from(tier: int, max_tiers: int) -> void:
	_propagate_light(tier, max_tiers)


func is_kindled() -> bool:
	return state == RState.KINDLED


func _set_state(next: int) -> void:
	state = next
	state_changed.emit(node_id, STATE_NAMES[next])
	if next == RState.KINDLED:
		kindled.emit(node_id)


func _appear() -> void:
	var lit := state != RState.DORMANT
	if _flame != null:
		_flame.visible = lit
		_flame.light_energy = 1.4 if state == RState.KINDLED else 0.5
	if _flame_mesh != null:
		_flame_mesh.visible = lit
		var mat := _flame_mesh.material_override as StandardMaterial3D
		if mat == null:
			mat = _flame_mesh.get_surface_override_material(0) as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = 2.2 if state == RState.KINDLED else 0.9
	if _beacon_mesh != null:
		var bmat := _beacon_mesh.material_override as StandardMaterial3D
		if bmat == null:
			bmat = _beacon_mesh.get_surface_override_material(0) as StandardMaterial3D
		if bmat != null:
			bmat.emission_enabled = state != RState.DORMANT
			bmat.emission_energy_multiplier = 1.6 if state == RState.KINDLED else 0.5


## Save/load support.
func state_name() -> String:
	return STATE_NAMES[state]


func restore_state(name_str: String) -> void:
	for k in STATE_NAMES:
		if STATE_NAMES[k] == name_str:
			_set_state(k)
			_appear()
			return
	push_warning("RekindleNode %s: unknown saved state %s" % [node_id, name_str])

