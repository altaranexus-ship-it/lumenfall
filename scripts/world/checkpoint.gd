class_name Checkpoint
extends Area3D
## Checkpoint zone: saving is automatic inside CHECKPOINT_RADIUS when the
## player's anchor node is KINDLED, or on entering with any kindled state.

signal checkpoint_saved(id: String)

@export var checkpoint_id := "cp_grove"

var _saved := false


func _ready() -> void:
	add_to_group("checkpoint")
	body_entered.connect(_on_body)


func notify_kindled() -> void:
	# a kindle inside the radius (or anywhere) is worth a checkpoint refresh
	if _player_inside():
		_save()


func _on_body(body: Node3D) -> void:
	if body is PlayerController:
		_save()


func _player_inside() -> bool:
	for body in get_overlapping_bodies():
		if body is PlayerController:
			return true
	return false


func _save() -> bool:
	var tree := get_tree()
	var player := tree.get_first_node_in_group("player") as CharacterBody3D
	if player == null:
		return false
	var ok := SaveManager.save_checkpoint(checkpoint_id, player.global_transform, SaveManager.collect_rekindle_states(tree.current_scene))
	if ok and not _saved:
		_saved = true
		checkpoint_saved.emit(checkpoint_id)
	return ok
