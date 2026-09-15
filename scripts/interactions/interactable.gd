class_name Interactable
extends Area3D
## Base for anything the player can focus and interact with (E).
## Subclasses override get_prompt() and interact(carrier).

@export var prompt := "Interact"
@export var enabled := true


func can_focus(_carrier: Node) -> bool:
	return enabled


func get_prompt(_carrier: Node) -> String:
	prompt = "Interact"
	return prompt


func interact(_carrier: Node) -> void:
	pass
