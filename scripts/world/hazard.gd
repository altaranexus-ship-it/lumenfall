extends Area3D
## Hazard volume: relocates the player to the last safe ground. The lumen is
## never lost (GDD v1: no-death failure; recovery reposition only).

func _ready() -> void:
	body_entered.connect(_on_body)


func _on_body(body: Node3D) -> void:
	if body is PlayerController and body.has_method("relocate_to_safe_ground"):
		body.relocate_to_safe_ground()
