extends CanvasLayer
## Debug overlay (QA gate Q-17): build id + commit hash first, live telemetry
## second. Toggled with F9. Input lives here so fail-reset cannot strand it
## hidden while the player-state gate would block the player's handler.

@onready var _build_label: Label = $Panel/VBox/BuildLabel
@onready var _info_label: Label = $Panel/VBox/InfoLabel

var _refresh_accum := 0.0


func _ready() -> void:
	_build_label.text = "LUMENFALL %s (engine %s)" % [BuildInfo.label(), BuildInfo.engine_version()]


func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum < 0.15:
		return
	_refresh_accum = 0.0
	var tree := get_tree()
	var player := tree.get_first_node_in_group("player")
	var pos := "-"
	var vel := "-"
	var pstate := "-"
	if player != null and player is Node3D:
		pos = str((player as Node3D).global_position.snapped(Vector3(0.05, 0.05, 0.05)))
		if "velocity" in player:
			vel = str(player.velocity.length())
		if "move_state" in player and "state_changed" in player:
			pstate = _move_state_name(int(player.move_state))
		if "glide_active" in player:
			pstate += "/GLIDE" if player.glide_active() else ""
	var carrying := "-"
	if player != null:
		var carrier := (player as Node).get_node_or_null("LightCarrier")
		if carrier != null and "is_carrying" in carrier:
			carrying = "lumen" if carrier.is_carrying() else "empty"
	var kindled := 0
	var total := 0
	for rn in tree.get_nodes_in_group("rekindle"):
		total += 1
		if rn.is_kindled():
			kindled += 1
	var save := "none"
	if SaveManager.has_save():
		save = SaveManager.load_data().get("checkpoint_id", "?")
	_info_label.text = "fps %d | pos %s | speed %s | state %s | carry %s | nodes %d/%d | save %s" % [
		Engine.get_frames_per_second(), pos, vel, pstate, carrying, kindled, total, save,
	]


func _move_state_name(v: int) -> String:
	match v:
		0: return "GROUNDED"
		1: return "AIRBORNE"
		2: return "CLIMBING"
		3: return "GLIDING"
		_: return "?"
