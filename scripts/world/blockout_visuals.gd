extends Node3D
## Blockout map dressing (AGE-22/48): assigns readable materials by node-name
## prefix so smoke runs and screenshots distinguish zones. Purely visual —
## no gameplay logic here.


const COL_HUB_STONE := Color(0.26, 0.28, 0.33)
const COL_WALK_PLANK := Color(0.33, 0.42, 0.44)
const COL_CLIMB := Color(0.24, 0.4, 0.33)
const COL_WALL := Color(0.3, 0.32, 0.37)
const COL_WATER := Color(0.12, 0.25, 0.45)
const COL_DEEP := Color(0.2, 0.22, 0.26)
const COL_BRASS := Color(0.65, 0.5, 0.25)
const COL_NODE := Color(0.45, 0.47, 0.52)
const COL_FLAME := Color(1.0, 0.78, 0.4)


func _ready() -> void:
	_dress(self)
	for rn in get_tree().get_nodes_in_group("rekindle"):
		_apply(rn, "BeaconMesh", COL_NODE)
		_apply(rn, "FlameMesh", COL_FLAME, true)


func _dress(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			child.material_override = _mat_for(child.name)
		if child is Node3D:
			_dress(child)


func _mat_for(node_name: StringName) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.85
	var n := String(node_name)
	if n.begins_with("Climb") or n.begins_with("Ledge"):
		mat.albedo_color = COL_CLIMB
	elif n.begins_with("Water") or n.begins_with("Pool"):
		mat.albedo_color = COL_WATER
		mat.emission_enabled = true
		mat.emission = COL_WATER
		mat.emission_energy_multiplier = 0.25
	elif n.begins_with("Wall") or n.begins_with("Shaft"):
		mat.albedo_color = COL_WALL
	elif n.begins_with("Pillar") or n.begins_with("Lamp"):
		mat.albedo_color = COL_BRASS
		mat.emission_enabled = true
		mat.emission = COL_BRASS
		mat.emission_energy_multiplier = 0.15
	elif n.begins_with("LWalk") or n.begins_with("RWalk") or n.begins_with("Approach") \
			or n.begins_with("Terrace") or n.begins_with("Link") or n.begins_with("Bridge") \
			or n.begins_with("SB") or n.begins_with("Vista"):
		mat.albedo_color = COL_WALK_PLANK
	elif n.begins_with("Dais"):
		mat.albedo_color = COL_HUB_STONE.lightened(0.15)
	elif n.begins_with("HubGround") or n.begins_with("Channel") or n.begins_with("ArcadeFloor") \
			or n.begins_with("Plinth") or n.begins_with("BeaconPlatform") or n.begins_with("Npc"):
		mat.albedo_color = COL_DEEP
	else:
		mat.albedo_color = COL_HUB_STONE
	return mat


func _apply(root: Node, child_name: String, col: Color, emissive := false) -> void:
	var mesh_node := root.get_node_or_null(NodePath(child_name))
	if mesh_node == null or not (mesh_node is MeshInstance3D):
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.85
	if emissive:
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 0.9
	mesh_node.material_override = mat
