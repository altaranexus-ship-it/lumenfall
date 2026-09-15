class_name PlayerController
extends CharacterBody3D
## 3C controller: walk / run / jump / climb / glide. Camera-relative movement.
## No death - hazards relocate the player to the last safe ground (GDD v1).
## FAIL_RESET_MAX only bounds rekindle recovery, not player mortality.

signal state_changed(new_state: String)
signal gliding_changed(active: bool)
signal safe_position_updated(transform: Transform3D)

enum MoveState { GROUNDED, AIRBORNE, CLIMBING, GLIDING }

@export var walk_speed := 4.0
@export var run_speed := 7.0
@export var acceleration := 22.0
@export var air_control := 0.5
@export var jump_velocity := 5.2
@export var climb_speed := 3.0
@export var glide_fall_speed := 1.6
@export var glide_min_height := 1.2
@export var climbable_mask := 8  # physics layer 4 = climbable
@export var mouse_sensitivity := 0.0022
@export var pitch_min := -1.2
@export var pitch_max := 0.9

@onready var _pitch: Node3D = $Pitch
@onready var _climb_ray: RayCast3D = $ClimbRay

var move_state: int = MoveState.AIRBORNE
var input_enabled := true
var _was_on_floor := false
var _safe_transform := Transform3D(Basis.IDENTITY, Vector3.ZERO)
var _safe_cooldown := 0.0


func _ready() -> void:
	add_to_group("player")
	if walk_speed != GameConfig.WALK_SPEED or run_speed != GameConfig.RUN_SPEED:
		push_warning("PlayerController: speed constants drift from GameConfig.")
	_safe_transform = global_transform


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch.rotation.x = clampf(_pitch.rotation.x - event.relative.y * mouse_sensitivity, pitch_min, pitch_max)


func _physics_process(delta: float) -> void:
	_update_safe_anchor(delta)
	match move_state:
		MoveState.CLIMBING:
			_process_climb(delta)
		_:
			_process_locomotion(delta)
	move_and_slide()
	_update_state_after_move()


func _input_vector() -> Vector2:
	if not input_enabled:
		return Vector2.ZERO
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


func _process_locomotion(delta: float) -> void:
	var gliding := _is_gliding()
	var iv := _input_vector()
	var direction := (transform.basis * Vector3(iv.x, 0.0, iv.z)).normalized()
	var running := input_enabled and Input.is_action_pressed("sprint")
	var target_speed := run_speed if running else walk_speed
	var control := 1.0 if is_on_floor() else air_control
	var target := direction * target_speed
	velocity.x = move_toward(velocity.x, target.x, acceleration * control * delta)
	velocity.z = move_toward(velocity.z, target.z, acceleration * control * delta)

	if Input.is_action_just_pressed("jump") and input_enabled:
		if is_on_floor():
			velocity.y = jump_velocity
		elif _cling_wall():
			_enter_climb()
			return

	if not is_on_floor():
		if gliding and velocity.y < -glide_fall_speed:
			velocity.y = move_toward(velocity.y, -glide_fall_speed, GameConfig.GRAVITY * delta)
			if not _glide_flag:
				_glide_flag = true
				gliding_changed.emit(true)
		else:
			velocity.y -= GameConfig.GRAVITY * delta
			if _glide_flag:
				_glide_flag = false
				gliding_changed.emit(false)
	elif _glide_flag:
		_glide_flag = false
		gliding_changed.emit(false)


var _glide_flag := false


func _is_gliding() -> bool:
	return input_enabled and Input.is_action_pressed("jump") and not is_on_floor() and velocity.y < 0.0 and _height_above_ground() > glide_min_height


func _height_above_ground() -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position + Vector3.DOWN * 60.0, 1)
	var hit := space.intersect_ray(q)
	return global_position.y - hit["position"].y if hit else INF


func _cling_wall() -> bool:
	return _climb_ray.is_colliding()


func _enter_climb() -> void:
	move_state = MoveState.CLIMBING
	velocity = Vector3.ZERO
	state_changed.emit("CLIMBING")


func _exit_climb(push_back := true) -> void:
	move_state = MoveState.AIRBORNE
	if push_back:
		var n := _climb_ray.get_collision_normal() if _climb_ray.is_colliding() else -global_transform.basis.z
		velocity = (n + Vector3.UP * 0.6).normalized() * 2.0
	state_changed.emit("AIRBORNE")


func _process_climb(delta: float) -> void:
	if not _cling_wall() or (input_enabled and Input.is_action_just_pressed("jump")):
		_exit_climb(not input_enabled)
		return
	var iv := _input_vector()
	var wall_normal := _climb_ray.get_collision_normal()
	var up := Vector3.UP
	var right := up.cross(wall_normal).normalized()
	var climb_dir := (up * -iv.y + right * iv.x)
	if climb_dir.length_squared() > 0.01:
		climb_dir = climb_dir.normalized()
	velocity = climb_dir * climb_speed


func _update_state_after_move() -> void:
	if move_state == MoveState.CLIMBING:
		return
	var next := MoveState.GROUNDED if is_on_floor() else MoveState.AIRBORNE
	if next != move_state:
		move_state = next
		state_changed.emit("GROUNDED" if next == MoveState.GROUNDED else "AIRBORNE")
	_was_on_floor = is_on_floor()


func _update_safe_anchor(delta: float) -> void:
	_safe_cooldown = maxf(0.0, _safe_cooldown - delta)
	if is_on_floor() and not _near_checkpoint_zone() and _safe_cooldown <= 0.0:
		_safe_transform = global_transform
		_safe_cooldown = 0.25
		safe_position_updated.emit(global_transform)


func _near_checkpoint_zone() -> bool:
	var group := get_tree().get_nodes_in_group("checkpoint")
	for cp in group:
		if cp is Node3D and global_position.distance_to(cp.global_position) <= GameConfig.CHECKPOINT_RADIUS:
			return true
	return false


## Hazard contact: relocate to last safe ground. No death in v1.
func relocate_to_safe_ground() -> void:
	velocity = Vector3.ZERO
	global_transform = _safe_transform
	move_state = MoveState.AIRBORNE
	state_changed.emit("AIRBORNE")


func glide_active() -> bool:
	return _glide_flag


func last_safe_transform() -> Transform3D:
	return _safe_transform


func set_input_enabled(enabled: bool) -> void:
	input_enabled = enabled
