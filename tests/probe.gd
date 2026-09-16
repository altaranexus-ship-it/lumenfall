extends SceneTree
## One-shot probe: input action semantics + overlay ready, headless.


func _init() -> void:
	await process_frame
	print("PROBE has_action(interact)=", InputMap.has_action("interact"))
	print("PROBE is_pressed_before=", Input.is_action_pressed("interact"))
	Input.action_press("interact")
	print("PROBE is_pressed_after=", Input.is_action_pressed("interact"))
	await process_frame
	print("PROBE is_pressed_next_frame=", Input.is_action_pressed("interact"))
	var ov: PackedScene = load("res://scenes/core/debug_overlay.tscn")
	var inst: Node = ov.instantiate()
	root.add_child(inst)
	await process_frame
	var lbl: Label = inst.get_node("Panel/VBox/BuildLabel")
	print("PROBE overlay label=", lbl.text)
	quit(0)
