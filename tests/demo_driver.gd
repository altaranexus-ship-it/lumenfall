extends Node
## DemoDriver — CLAW-75 showcase autopilot.
## Plays the REAL greybox map through the REAL input actions (Input.action_press),
## rendered via Godot Movie Maker. Cinematic phases with a scripted camera rail;
## switches to the player's first-person camera for the gameplay phase.
## No mocks: every kindle goes through the game's own state machine.

var cam: Camera3D          # cinematic rail camera
var player_cam: Camera3D   # the player's own camera
var player: CharacterBody3D
var carrier: Node
var map: Node3D

var phase := 0
var t := 0.0
var phase_t := 0.0
var cam_pos := Vector3.ZERO
var cam_look := Vector3.ZERO

const FPS := 30.0


func _ready() -> void:
	await get_tree().process_frame
	map = load("res://scenes/greybox_map.tscn").instantiate()
	get_tree().root.add_child(map)
	get_tree().current_scene = map
	await get_tree().process_frame
	await get_tree().physics_frame

	player = get_tree().get_first_node_in_group("player")
	carrier = player.get_node("LightCarrier")
	player_cam = player.get_node("Pitch/Camera3D")

	cam = Camera3D.new()
	cam.fov = 65.0
	get_tree().root.add_child(cam)
	cam.make_current()

	# Seed the debug overlay into an ON state so the HUD is visible in frame.
	var ov: CanvasLayer = get_tree().root.get_node_or_null("DebugOverlay")
	if ov != null:
		ov.visible = true
	print("DEMO ready: player=%s carrier=%s" % [player != null, carrier != null])


func _process(delta: float) -> void:
	t += delta
	phase_t += delta
	match phase:
		0: _p0_establish(delta)      # 0.0-5.0  dark world, beacons dormant (rail)
		1: _p1_approach(delta)       # 5.0-14.0 walk toward Rekindle1 (player cam)
		2: _p2_offer_and_kindle(delta)  # 14.0-19.5 offer lumen + hold E
		3: _p3_propagation(delta)    # 19.5-26.0 wave lights node2/node3 (rail)
		4: _p4_run_glide(delta)      # 26.0-34.0 sprint + jump + glide (player cam)
		5: _p5_climb(delta)          # 34.0-41.0 climb wall (player cam)
		6: _p6_outro(delta)          # 41.0-47.0 lit world beauty pass (rail)
		7:                           # done — movie maker flushes on quit
			if true:
				print("DEMO complete at t=%.1f" % t)
				get_tree().quit(0)


func _set_phase(p: int, at: float) -> void:
	if phase == p - 1 and t >= at:
		phase = p
		phase_t = 0.0
		_release_all()


func _release_all() -> void:
	for a in ["move_left", "move_right", "move_forward", "move_back", "jump", "sprint", "interact"]:
		Input.action_release(a)


# ---------------------------------------------------------------- phase logic
func _p0_establish(delta: float) -> void:
	# Slow dolly across the dark grove: from near spawn toward the dormant beacon.
	var k := clampf(t / 5.0, 0.0, 1.0)
	cam_pos = Vector3(6.0 - 2.0 * k, 2.6 + 0.4 * sin(t * 0.7), 8.0 - 3.0 * k)
	cam_look = Vector3(0.0, 1.5, 0.0)
	_apply_rail()
	_set_phase(1, 5.0)


func _p1_approach(delta: float) -> void:
	if phase_t < 0.05:
		player_cam.make_current()
		_face_target(player, Vector3(0, 1, 0))  # face Rekindle1 at origin
	# Walk forward toward Rekindle1 (player spawns at (0,1.2,10), beacon at origin).
	Input.action_press("move_forward")
	# Cut to run after 3s of walking, stop at 8.2s when close.
	if phase_t > 3.0:
		Input.action_press("sprint")
	if player.global_position.distance_to(Vector3(0, 1, 0)) < 1.9 or phase_t > 8.5:
		_release_all()
		_set_phase(2, t)
		print("DEMO phase2 at t=%.1f dist=%.2f" % [t, player.global_position.distance_to(Vector3(0, 1, 0))])


func _p2_offer_and_kindle(delta: float) -> void:
	# Stand still, face the beacon, offer the lumen (E press → receive_lumen),
	# then HOLD E through kindle_time — exactly the human flow.
	if phase_t < 0.05:
		_face_target(player, Vector3(0, 1.4, 0))
	if phase_t > 0.4 and phase_t < 0.55:
		Input.action_press("interact")
	elif phase_t >= 0.55 and phase_t < 0.7:
		Input.action_release("interact")
	elif phase_t >= 0.7:
		# hold to kindle (game polls Input.is_action_pressed("interact"))
		Input.action_press("interact")
	_p3_gate()


func _p3_gate() -> void:
	var rn1: Node = map.get_node("Rekindle1")
	if phase_t > 6.0 or (rn1 != null and rn1.is_kindled() and phase_t > 1.0):
		_release_all()
		_set_phase(3, t)
		print("DEMO phase3 at t=%.1f kindled=%s" % [t, rn1.is_kindled()])


func _p3_propagation(delta: float) -> void:
	# Rail shot: watch the wave widen from node1 to node2/node3.
	var k := clampf(phase_t / 6.5, 0.0, 1.0)
	cam.make_current()
	cam_pos = Vector3(-3.0 - 4.0 * k, 3.2 + 1.6 * k, 4.0 - 1.0 * k)
	cam_look = Vector3(-5.0 - 5.0 * k, 2.0 + 2.0 * k, -10.0 - 8.0 * k)
	_apply_rail()
	_p4_gate()


func _p4_gate() -> void:
	if phase_t > 6.5:
		_set_phase(4, t)
		player_cam.make_current()
		_face_target(player, Vector3(-8, 1, 4))
		print("DEMO phase4 at t=%.1f" % t)


func _p4_run_glide(delta: float) -> void:
	# Sprint back toward spawn, jump + glide over the hazard strip at z=6.
	Input.action_press("sprint")
	Input.action_press("move_back")
	if phase_t > 2.0 and phase_t < 2.15:
		Input.action_press("jump")
	elif phase_t >= 2.15:
		Input.action_release("jump")
	if phase_t > 7.5:
		_release_all()
		_set_phase(5, t)
		print("DEMO phase5 at t=%.1f pos=%s" % [t, player.global_position])


func _p5_climb(delta: float) -> void:
	# Turn toward the climb wall at (6,2,-14) and climb it.
	if phase_t < 0.05:
		_face_target(player, Vector3(6, 2, -14))
	# Walk toward the wall, then hold forward against it to cling + climb.
	Input.action_press("move_forward")
	if phase_t > 4.0:
		Input.action_press("jump")  # jump against wall -> _cling_wall -> climb
	if phase_t > 6.8:
		_release_all()
		_set_phase(6, t)
		print("DEMO phase6 at t=%.1f pos=%s state=%d" % [t, player.global_position, player.move_state])


func _p6_outro(delta: float) -> void:
	# Final beauty pass: high rail over the whole lit map.
	cam.make_current()
	var k := clampf(phase_t / 6.0, 0.0, 1.0)
	cam_pos = Vector3(10.0 - 4.0 * k, 9.0 + 2.0 * k, 12.0 - 2.0 * k)
	cam_look = Vector3(-4.0, 1.5, -8.0)
	_apply_rail()
	if phase_t > 6.0:
		phase = 7


func _apply_rail() -> void:
	cam.global_position = cam_pos
	# keep the horizon level: look_at with up = Y
	if (cam_look - cam_pos).length() > 0.1:
		cam.look_at(cam_look, Vector3.UP)


func _face_target(node: CharacterBody3D, target: Vector3) -> void:
	var d := target - node.global_position
	d.y = 0.0
	if d.length() < 0.05:
		return
	node.rotation.y = atan2(-d.x, -d.z) + PI  # -Z forward convention
