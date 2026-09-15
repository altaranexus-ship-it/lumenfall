class_name LightCarrier
extends Node3D
## Player-side light carry logic. CARRY_STACK = 1 (design lock): one lumen,
## never destroyed - offering a lumen to a node that cannot take it returns it.

signal lumen_changed(carrying: bool)

@onready var _hand: OmniLight3D = $HandLight

var _carrying := false


func _ready() -> void:
	_grant_lumen()  # v1: the player begins with the single lumen
	if GameConfig.CARRY_STACK != 1:
		push_warning("LightCarrier: v1 assumes CARRY_STACK == 1.")


func is_carrying() -> bool:
	return _carrying


## Give the lumen to something (called by RekindleNode.accept flow or hazards).
## Returns true if the lumen left our hands.
func consume_lumen() -> bool:
	if not _carrying:
		return false
	_carrying = false
	_hand.visible = false
	lumen_changed.emit(false)
	return true


## The lumen is never destroyed: misroutes and hazards hand it back.
func grant_lumen() -> void:
	_grant_lumen()


func _grant_lumen() -> void:
	_carrying = true
	_hand.visible = true
	lumen_changed.emit(true)
