extends Node
## SaveManager - checkpoint save/load + rekindle-state journal (autoload).
## Human-readable JSON at user://savegame.json so QA can inspect/diff saves.
## Schema versioned; unknown fields on load are ignored (forward tolerant).

const SAVE_PATH := "user://savegame.json"
const SCHEMA_VERSION := 1

signal checkpoint_saved(checkpoint_id: String)
signal state_loaded


func save_checkpoint(checkpoint_id: String, player_transform: Transform3D, rekindle_states: Dictionary) -> bool:
	var data := {
		"schema": SCHEMA_VERSION,
		"build_label": BuildInfo.label(),
		"checkpoint_id": checkpoint_id,
		"player": {
			"position": [player_transform.origin.x, player_transform.origin.y, player_transform.origin.z],
		},
		"rekindle": rekindle_states,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: cannot write %s (err %d)" % [SAVE_PATH, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	checkpoint_saved.emit(checkpoint_id)
	return true


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func load_data() -> Dictionary:
	if not has_save():
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary and int(parsed.get("schema", -1)) <= SCHEMA_VERSION:
		return parsed
	push_warning("SaveManager: save missing or schema too new, ignoring.")
	return {}


func apply_loaded_state(root: Node) -> bool:
	var data := load_data()
	if data.is_empty():
		return false
	var player := root.get_node_or_null("Player") as CharacterBody3D
	if player != null:
		var pos: Array = data.get("player", {}).get("position", [])
		if pos.size() == 3:
			player.velocity = Vector3.ZERO
			player.global_transform.origin = Vector3(pos[0], pos[1], pos[2])
	var states: Dictionary = data.get("rekindle", {})
	for node in _all_rekindle_nodes(root):
		var id := str(node.get("node_id"))
		if states.has(id):
			node.restore_state(str(states[id]))
	state_loaded.emit()
	return true


func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))


# -- static helpers used by RekindleNode journaling --

static func transform_to_dict(t: Transform3D) -> Dictionary:
	var o := t.origin
	return {"position": [o.x, o.y, o.z]}


static func transform_from_dict(d: Dictionary) -> Transform3D:
	var pos: Array = d.get("position", [0.0, 0.0, 0.0])
	return Transform3D(Basis.IDENTITY, Vector3(pos[0], pos[1], pos[2]))


static func collect_rekindle_states(root: Node) -> Dictionary:
	var out := {}
	for node in _all_rekindle_nodes(root):
		out[str(node.get("node_id"))] = node.call("state_name")
	return out


static func _all_rekindle_nodes(root: Node) -> Array:
	return root.find_children("*", "RekindleNode", true, false)
