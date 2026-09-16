extends Node
## Headless smoke test for the LUMENFALL foundation slice (AGE-21).
## Run: godot --headless --path . res://tests/smoke_test.tscn
## Exit code 0 = all assertions passed; 1 = failure (message on stdout).
## Boots the REAL greybox map, so autoloads, scene wiring, and physics are live.

var _failures: PackedStringArray = []


func _ready() -> void:
	# Hard watchdog: never let a crashed assertion strand the process.
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("SMOKE_RESULT=TIMEOUT")
		get_tree().quit(2))

	# Boot the real map as the current scene, exactly like a normal run.
	# Wait one frame first: root is busy adding THIS node during _ready.
	await get_tree().process_frame
	var map: PackedScene = load("res://scenes/greybox_map.tscn")
	var map_instance := map.instantiate()
	get_tree().root.add_child(map_instance)
	get_tree().current_scene = map_instance
	# Let one full frame run so @onready + _ready + first physics tick settle.
	await get_tree().process_frame
	await get_tree().physics_frame

	print("BUILD_LABEL=%s" % BuildInfo.label())
	_assert(BuildInfo.build_id() != "unknown" and BuildInfo.build_id() != "PENDING", "Q-17 build_id stamped")
	_assert(BuildInfo.commit_short() != "unknown" and BuildInfo.commit_short() != "PENDING", "Q-17 commit hash stamped")

	# --- node graph sanity ---------------------------------------------------
	var player := get_tree().get_first_node_in_group("player")
	_assert(player != null, "player present in map")
	var rekindle := get_tree().get_nodes_in_group("rekindle")
	_assert(rekindle.size() == 3, "3 rekindle nodes in map (got %d)" % rekindle.size())
	var carrier: Node = player.get_node("LightCarrier")
	_assert(carrier.is_carrying(), "player starts carrying the lumen (v1)")
	_assert(Interactor != null, "interactor class resolves")

	# --- rekindle state machine: DORMANT -> CARRYING -> KINDLED ---------------
	var rn1: RekindleNode = map_instance.get_node("Rekindle1")
	var rn2: RekindleNode = map_instance.get_node("Rekindle2")
	var rn3: RekindleNode = map_instance.get_node("Rekindle3")
	_assert(rn1.state == RekindleNode.RState.DORMANT, "node1 starts DORMANT")
	_assert(not rn1.is_kindled(), "node1 not kindled at start")

	# No lumen, no kindle: a node cannot be offered to an empty-handed player.
	_assert(carrier.consume_lumen(), "lumen can be consumed (handed to node)")
	_assert(not carrier.is_carrying(), "carrier empty after consume")
	_assert(not rn1.receive_lumen(carrier), "receive_lumen rejected without lumen")

	# Offering with lumen: DORMANT -> CARRYING, then hold for kindle_time.
	_assert(rn1.receive_lumen(carrier) == false, "cannot offer while player has no lumen")
	carrier.grant_lumen()
	_assert(rn1.receive_lumen(carrier), "offer accepted: DORMANT -> CARRYING")
	_assert(rn1.state == RekindleNode.RState.CARRYING, "node1 CARRYING after offer")
	_assert(not carrier.is_carrying(), "lumen transferred to node")

	# Simulate the hold through the REAL input path: Input.action_press works
	# headless (verified via probe.gd), and rekindle_node._process polls
	# Input.is_action_pressed("interact") each frame while CARRYING.
	Input.action_press("interact")
	var t := 0.0
	while t < GameConfig.KINDLE_TIME + 0.2:
		await get_tree().physics_frame
		t += 1.0 / 60.0
	Input.action_release("interact")
	_assert(rn1.is_kindled(), "node1 KINDLED after hold >= kindle_time")

	# Propagation: node1->node2 distance ~10.7 m, node2->node3 ~10.8 m; tier
	# radius step 8 => tier1 reaches <=8 m (none), tier2 <=16 m (node2), tier3
	# <=24 m (node3) chained from node2. Allow a few frames for deferred chain.
	for i in 8:
		await get_tree().process_frame
	_assert(rn2.state != RekindleNode.RState.DORMANT, "propagation lit node2 (grace)")
	_assert(rn3.state != RekindleNode.RState.DORMANT, "propagation chained to node3")

	# --- no-lumen rule + second kindle path ----------------------------------
	# node2/node3 are in CARRYING grace; the player (empty) cannot kindle them
	# again, and a CARRYING node cannot accept another lumen.
	_assert(not rn2.receive_lumen(carrier), "CARRYING node rejects re-offer")

	# --- save / load round-trip ----------------------------------------------
	var states_before := SaveManager.collect_rekindle_states(map_instance)
	_assert(states_before.get("rekindle_01", "") == "KINDLED", "journal captured KINDLED for node1")
	var player_body := player as CharacterBody3D
	var spawn_pos: Vector3 = player_body.global_position
	var ok := SaveManager.save_checkpoint("cp_test", player_body.global_transform, states_before)
	_assert(ok, "save_checkpoint wrote file")
	_assert(SaveManager.has_save(), "has_save true after write")

	# Wreck live state, then restore from disk.
	rn1._set_state(RekindleNode.RState.DORMANT)
	_assert(not rn1.is_kindled(), "node1 downgraded for restore test")
	player_body.global_transform = Transform3D(Basis.IDENTITY, Vector3(50.0, 30.0, 50.0))
	_assert(SaveManager.apply_loaded_state(map_instance), "apply_loaded_state restored")
	_assert(rn1.is_kindled(), "node1 KINDLED again after load")
	_assert(player_body.global_position.distance_to(spawn_pos) < 25.0, "player relocated near saved spot")
	var data := SaveManager.load_data()
	_assert(str(data.get("checkpoint_id", "")) == "cp_test", "checkpoint id round-trips")
	_assert(int(data.get("schema", 0)) == 1, "schema version round-trips")

	# --- hazard relocation (no-death rule) ------------------------------------
	player_body.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 10.0))
	player_body.velocity = Vector3.ZERO
	var safe_before: Vector3 = player.get_node("..").get_node("Player").last_safe_transform().origin
	# Force a hazard contact directly (signal path, physics-independent).
	player_body.relocate_to_safe_ground()
	_assert(player_body.global_position.distance_to(safe_before) < 0.5, "hazard relocation returns to last safe ground")
	_assert(player_body.velocity.length() < 0.01, "velocity zeroed on relocation")

	# --- debug overlay (Q-17) --------------------------------------------------
	var overlay: CanvasLayer = get_tree().root.get_node_or_null("DebugOverlay")
	_assert(overlay != null, "debug overlay autoload present")
	if overlay != null:
		# Same code path _ready uses; proves BuildInfo wiring renders text.
		var lbl: Label = overlay.get_node("Panel/VBox/BuildLabel")
		_assert(lbl.text.begins_with("LUMENFALL "), "overlay build label populated")
		print("OVERLAY_TEXT=%s" % lbl.text)

	# --- design-lock tunables --------------------------------------------------
	var tun := GameConfig.tunables()
	_assert(tun["interact_range"] == 2.5, "interact_range == 2.5")
	_assert(tun["kindle_time"] == 1.2, "kindle_time == 1.2")
	_assert(tun["propagation_tiers"] == 3, "propagation_tiers == 3")
	_assert(tun["carry_stack"] == 1, "carry_stack == 1")
	_assert(tun["dim_time"] == 6.0, "dim_time == 6.0")
	_assert(tun["checkpoint_radius"] == 6.0, "checkpoint_radius == 6.0")
	_assert(tun["fail_reset_max"] == 8.0, "fail_reset_max == 8.0")
	_assert(GameConfig.DIMMING_ENABLED == false, "DIMMING gated off for v1")

	if _failures.is_empty():
		print("SMOKE_RESULT=PASS (%s)" % BuildInfo.label())
		get_tree().quit(0)
	else:
		print("SMOKE_RESULT=FAIL")
		for f in _failures:
			print("  FAIL: " + f)
		get_tree().quit(1)


func _assert(cond: bool, what: String) -> void:
	if cond:
		print("  ok: " + what)
	else:
		_failures.append(what)
		print("  FAIL: " + what)
