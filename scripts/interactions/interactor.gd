class_name Interactor
extends Node3D
## Player-side interaction scanner. Keeps the nearest in-range Interactable
## focused; forwards the interact action. Range is design-locked (2.5 m).

const RANGE := GameConfig.INTERACT_RANGE

signal focus_changed(interactable: Interactable)

var focused: Interactable = null


func _physics_process(_delta: float) -> void:
	var best: Interactable = null
	var best_d := RANGE
	for node in get_tree().get_nodes_in_group("interactable"):
		var it := node as Interactable
		if it == null or not it.can_focus(_carrier()):
			continue
		var d := global_position.distance_to(it.global_position)
		if d <= best_d:
			best_d = d
			best = it
	if best != focused:
		focused = best
		focus_changed.emit(focused)


func _unhandled_input(event: InputEvent) -> void:
	if focused != null and event.is_action_pressed("interact"):
		focused.interact(_carrier())


func _carrier() -> Node:
	var p := get_parent()
	if p == null:
		return null
	var lc := p.get_node_or_null("LightCarrier")
	return lc if lc != null else p


func try_interact() -> void:
	if focused != null:
		focused.interact(_carrier())
