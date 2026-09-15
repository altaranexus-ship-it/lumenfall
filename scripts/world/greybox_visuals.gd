extends Node3D
## Greybox map dressing: assigns readable materials so the smoke run and
## screenshots distinguish ground / platforms / climb walls / hazards / beacons.

const COL_GROUND := Color(0.23, 0.25, 0.29)
const COL_PLATFORM := Color(0.35, 0.38, 0.44)
const COL_CLIMB := Color(0.24, 0.4, 0.33)
const COL_HAZARD := Color(0.55, 0.16, 0.14)
const COL_NODE := Color(0.45, 0.47, 0.52)
const COL_FLAME := Color(1.0, 0.78, 0.4)


func _ready() -> void:
	_apply_mesh_material(self, "Ground", COL_GROUND)
	_apply_mesh_material(self, "PlatformA", COL_PLATFORM)
	_apply_mesh_material(self, "PlatformB", COL_PLATFORM)
	_apply_mesh_material(self, "ClimbWall", COL_CLIMB)
	_apply_mesh_material(self, "Hazard", COL_HAZARD)
	for rn in get_tree().get_nodes_in_group("rekindle"):
		_apply_mesh_material(rn, "BeaconMesh", COL_NODE)
		_apply_mesh_material(rn, "FlameMesh", COL_FLAME, true)


func _apply_mesh_material(root: Node, child_name: String, col: Color, emissive := false) -> void:
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
