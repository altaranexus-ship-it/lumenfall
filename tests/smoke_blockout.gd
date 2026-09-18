extends Node
## Headless smoke test for the LUMENFALL blockout (AGE-22/48).
## Run: godot --headless --path . res://tests/smoke_blockout.tscn
## Exit 0 = all assertions passed; 1 = failure; 2 = watchdog timeout.
## Boots the REAL blockout map and walks the full designed relay:
## offer H1 -> kindle -> grace hops CM/C2/S1/B1/T0/T1 -> beacon crown -> cascade.

var _failures: PackedStringArray = []


func _ready() -> void:
	get_tree().create_timer(110.0).timeout.connect(func() -> void:
		print("SMOKE_RESULT=TIMEOUT")
		get_tree().quit(2))
	await get_tree().process_frame
	var map: PackedScene = load("res://scenes/blockout_map.tscn")
	_assert(map != null, "blockout scene loads")
	if map == null:
		print("SMOKE_RESULT=FAIL")
		get_tree().quit(1)
		return
	var map_instance := map.instantiate()
	get_tree().root.add_child(map_instance)
	get_tree().current_scene = map_instance
	await get_tree().process_frame
	await get_tree().physics_frame

	print("BUILD_LABEL=%s" % BuildInfo.label())

	# --- zone content per vertical slice plan section 3 ----------------------
	# hub 3 (H1..H3), canal 3 (C1, CM, C2), arcade 3 (S1..S3),
	# beacon 3 (B1, B2, TB crown), tower 2 (T0, T1) = 14 total.
	var zones := {"hub": 3, "canal": 3, "arcade": 3, "beacon": 3, "tower": 2}
	var counts := {}
	var nodes := get_tree().get_nodes_in_group("rekindle")
	_assert(nodes.size() == 14, "14 rekindle nodes in blockout (got %d)" % nodes.size())
	for rn in nodes:
		var parts := String(rn.node_id).split("_")
		if parts.size() >= 2:
			counts[parts[1]] = counts.get(parts[1], 0) + 1
	for z in zones:
		_assert(int(counts.get(z, 0)) == zones[z], "zone '%s' has %d nodes (got %d)" % [z, zones[z], counts.get(z, 0)])

	var player := get_tree().get_first_node_in_group("player")
	_assert(player != null, "player present in blockout")
	var rn := {}
	for nid in ["RN_H1", "RN_H2", "RN_H3", "RN_C1", "RN_CM", "RN_C2", "RN_S1", "RN_S2",
			"RN_S3", "RN_B1", "RN_B2", "RN_T0", "RN_T1", "RN_TB"]:
		rn[nid] = map_instance.get_node_or_null(nid)
		_assert(rn[nid] != null, "node %s present" % nid)
	var carrier: Node = player.get_node("LightCarrier")
	_assert(carrier.is_carrying(), "player starts carrying the lumen")

	# --- all dormant at boot --------------------------------------------------
	for r in nodes:
		_assert(r.state == RekindleNode.RState.DORMANT, "%s starts DORMANT" % r.node_id)

	# --- relay geometry: grace hops (tier 3 wave = 24m) -----------------------
	var hops := [
		["RN_C1", "RN_CM"], ["RN_CM", "RN_C2"], ["RN_C2", "RN_S1"],
		["RN_S1", "RN_B1"], ["RN_B1", "RN_T0"], ["RN_T0", "RN_T1"], ["RN_T1", "RN_TB"],
	]
	for h in hops:
		var d: float = rn[h[0]].global_position.distance_to(rn[h[1]].global_position)
		print("CHAIN_%s_%s=%.1fm" % [h[0], h[1], d])
		_assert(d <= 24.0, "grace hop %s -> %s within 24m (got %.1fm)" % [h[0], h[1], d])
	# The hub -> canal leg is walked by the player (no grace needed).
	var d_walk: float = rn["RN_H1"].global_position.distance_to(rn["RN_C1"].global_position)
	print("CHAIN_H1_C1_walk=%.1fm" % d_walk)

	# --- hub: no-lumen rule + first kindle through the REAL input path --------
	_assert(carrier.consume_lumen(), "lumen can be consumed")
	_assert(not carrier.is_carrying(), "carrier empty after consume")
	_assert(rn["RN_H1"].receive_lumen(carrier) == false, "empty-handed offer rejected")
	carrier.grant_lumen()
	_assert(rn["RN_H1"].receive_lumen(carrier), "hub source offer accepted")
	_assert(rn["RN_H1"].state == RekindleNode.RState.CARRYING, "RN_H1 CARRYING after offer")
	_assert(not carrier.is_carrying(), "lumen transferred to node")
	await _hold()
	_assert(rn["RN_H1"].is_kindled(), "RN_H1 KINDLED after hold >= kindle_time")

	# --- relay: offer C1, then bare holds ride the grace wave to the beacon --
	# (grace puts nodes in CARRYING: hold alone kindles, no lumen needed)
	# C1 may already be in grace: H1's tier-2 wave lights H2/H3, whose chained
	# tier-3 wave reaches C1 (~22.3m). Accept either a fresh offer or grace.
	carrier.grant_lumen()
	var c1_offered: bool = rn["RN_C1"].receive_lumen(carrier)
	var c1_ready: bool = c1_offered or rn["RN_C1"].state == RekindleNode.RState.CARRYING
	_assert(c1_ready, "canal C1 entry (offer accepted or chained grace)")
	await _hold()
	_assert(rn["RN_C1"].is_kindled(), "RN_C1 KINDLED")
	await _expect_grace(rn["RN_CM"])
	await _hold()
	_assert(rn["RN_CM"].is_kindled(), "RN_CM KINDLED (plinth perch)")
	await _expect_grace(rn["RN_C2"])
	await _hold()
	_assert(rn["RN_C2"].is_kindled(), "RN_C2 KINDLED")
	await _expect_grace(rn["RN_S1"])
	await _hold()
	_assert(rn["RN_S1"].is_kindled(), "RN_S1 KINDLED (arcade gate)")
	_assert(rn["RN_S2"].state != RekindleNode.RState.DORMANT, "arcade flank S2 in grace")
	_assert(rn["RN_S3"].state != RekindleNode.RState.DORMANT, "arcade flank S3 in grace")
	await _hold_node(rn["RN_S2"])
	await _hold_node(rn["RN_S3"])
	_assert(rn["RN_S2"].is_kindled(), "RN_S2 KINDLED")
	_assert(rn["RN_S3"].is_kindled(), "RN_S3 KINDLED")
	await _expect_grace(rn["RN_B1"])
	await _hold()
	_assert(rn["RN_B1"].is_kindled(), "RN_B1 KINDLED (beacon approach)")
	await _expect_grace(rn["RN_T0"])
	await _hold()
	_assert(rn["RN_T0"].is_kindled(), "RN_T0 KINDLED (tower base)")
	await _expect_grace(rn["RN_T1"])
	await _hold()
	_assert(rn["RN_T1"].is_kindled(), "RN_T1 KINDLED (plinth crown)")

	# --- climbable beacon tower (AGE-20 linter geometry contract) ------------
	var plinth := map_instance.get_node("Plinth")
	_assert(plinth.collision_layer & 8 != 0, "plinth marked climbable (layer 8)")
	var shaft := map_instance.get_node("Shaft")
	_assert(shaft.collision_layer & 8 != 0, "shaft marked climbable (layer 8)")
	var dy: float = rn["RN_T1"].global_position.y - (plinth.global_position.y + 4.0)
	_assert(absf(dy) < 1.5, "T1 near plinth top ledge (dy=%.1fm)" % dy)

	# --- finale: beacon crown + full-map cascade ------------------------------
	await _expect_grace(rn["RN_TB"])
	await _hold()
	_assert(rn["RN_TB"].is_kindled(), "RN_TB KINDLED (beacon crown)")
	for r in nodes:
		_assert(r.is_kindled(), "cascade lit %s" % r.node_id)
	# B2 sits between B1 and T0; the crown wave must have caught it.
	_assert(rn["RN_B2"].is_kindled(), "flank beacon B2 lit by cascade")

	# --- checkpoint ladder -----------------------------------------------------
	var cps := get_tree().get_nodes_in_group("checkpoint")
	_assert(cps.size() == 4, "4 checkpoints (got %d)" % cps.size())
	var ids := []
	for cp in cps:
		ids.append(cp.checkpoint_id)
	for want in ["cp_hub", "cp_canal", "cp_arcade", "cp_tower"]:
		_assert(ids.has(want), "checkpoint %s present" % want)

	# --- save / load round-trip on the blockout -------------------------------
	var states_before := SaveManager.collect_rekindle_states(map_instance)
	_assert(states_before.get("rn_hub_1", "") == "KINDLED", "journal captured KINDLED for rn_hub_1")
	_assert(states_before.get("rn_beacon_tower", "") == "KINDLED", "journal captured KINDLED for beacon")
	var player_body := player as CharacterBody3D
	var spawn_pos: Vector3 = player_body.global_position
	var ok := SaveManager.save_checkpoint("cp_blk_test", player_body.global_transform, states_before)
	_assert(ok, "save_checkpoint wrote file")
	_assert(SaveManager.has_save(), "has_save true after write")
	rn["RN_H1"]._set_state(RekindleNode.RState.DORMANT)
	_assert(not rn["RN_H1"].is_kindled(), "rn_hub_1 downgraded for restore test")
	player_body.global_transform = Transform3D(Basis.IDENTITY, Vector3(150.0, 30.0, 150.0))
	_assert(SaveManager.apply_loaded_state(map_instance), "apply_loaded_state restored")
	_assert(rn["RN_H1"].is_kindled(), "rn_hub_1 KINDLED again after load")
	_assert(player_body.global_position.distance_to(spawn_pos) < 25.0, "player relocated near saved spot")
	var data := SaveManager.load_data()
	_assert(str(data.get("checkpoint_id", "")) == "cp_blk_test", "checkpoint id round-trips")
	_assert(int(data.get("schema", 0)) == 1, "schema version round-trips")

	# --- hazard relocation (no-death rule) on the blockout --------------------
	player_body.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 9.0))
	player_body.velocity = Vector3.ZERO
	player_body.relocate_to_safe_ground()
	_assert(player_body.global_position.distance_to(spawn_pos) < 25.0, "hazard relocation returns near last safe ground")
	_assert(player_body.velocity.length() < 0.01, "velocity zeroed on relocation")

	# --- static geometry census (placeholder budget check) --------------------
	var static_count := _count_static(map_instance)
	_assert(static_count >= 18, "blockout has >=18 static bodies (got %d)" % static_count)

	# --- design-lock tunables unchanged ----------------------------------------
	var tun := GameConfig.tunables()
	_assert(tun["interact_range"] == 2.5, "interact_range == 2.5")
	_assert(tun["kindle_time"] == 1.2, "kindle_time == 1.2")
	_assert(tun["propagation_tiers"] == 3, "propagation_tiers == 3")
	_assert(tun["carry_stack"] == 1, "carry_stack == 1")
	_assert(tun["dim_time"] == 6.0, "dim_time == 6.0")
	_assert(GameConfig.DIMMING_ENABLED == false, "DIMMING gated off for v1")

	if _failures.is_empty():
		print("SMOKE_RESULT=PASS (%s)" % BuildInfo.label())
		get_tree().quit(0)
	else:
		print("SMOKE_RESULT=FAIL")
		for f in _failures:
			print("  FAIL: " + f)
		get_tree().quit(1)


## Hold E for kindle_time against whichever node the test last offered to.
func _hold() -> void:
	Input.action_press("interact")
	var t := 0.0
	while t < GameConfig.KINDLE_TIME + 0.2:
		await get_tree().physics_frame
		t += 1.0 / 60.0
	Input.action_release("interact")
	for i in 8:
		await get_tree().process_frame


## A node already in CARRYING grace needs no fresh offer: hold directly.
func _hold_node(node: RekindleNode) -> void:
	if node.state == RekindleNode.RState.CARRYING:
		await _hold()


func _expect_grace(node: RekindleNode) -> void:
	for i in 8:
		await get_tree().process_frame
	_assert(node.state != RekindleNode.RState.DORMANT, "grace wave reached %s" % node.node_id)


func _count_static(root: Node) -> int:
	var count := 0
	if root is StaticBody3D:
		count += 1
	for c in root.get_children():
		count += _count_static(c)
	return count


func _assert(cond: bool, label: String) -> void:
	if cond:
		print("  ok: " + label)
	else:
		_failures.append(label)
		print("  FAIL: " + label)
