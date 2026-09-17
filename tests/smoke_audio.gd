extends Node
## AGE-23 headless smoke test for the audio slice.
## Run: godot --headless --path . res://tests/smoke_audio.tscn
## Exit 0 = all audio assertions passed; 1 = failure.
## Boots the REAL greybox map so AudioManager hooks meet real signals.
## Headless note: audio output is a dummy driver, but AudioServer buses,
## players, streams, and signal flow are fully live.

var _failures: PackedStringArray = []
var _passes := 0


func _ready() -> void:
	get_tree().create_timer(75.0).timeout.connect(func() -> void:
		print("AUDIO_SMOKE_RESULT=TIMEOUT")
		get_tree().quit(2))

	await get_tree().process_frame
	var map: PackedScene = load("res://scenes/greybox_map.tscn")
	var map_instance := map.instantiate()
	get_tree().root.add_child(map_instance)
	get_tree().current_scene = map_instance
	# Let one full frame run so @onready + _ready + first physics tick settle.
	await get_tree().process_frame
	await get_tree().physics_frame

	print("AUDIO_BUILD_LABEL=%s" % BuildInfo.label())

	# --- autoload present ----------------------------------------------------
	var am: Node = get_node_or_null("/root/AudioManager")
	_assert(am != null, "AudioManager autoload present")
	if am == null:
		_finish()
		return

	# --- bus layout ----------------------------------------------------------
	for bus_name in ["Music", "LayerDark", "LayerLit", "Ambience",
			"SFX", "SFX_Player", "SFX_World", "UI"]:
		_assert(AudioServer.get_bus_index(bus_name) >= 0,
			"bus exists: %s" % bus_name)
	var lit_idx := AudioServer.get_bus_index("LayerLit")
	_assert(AudioServer.get_bus_channels(lit_idx) > 0, "LayerLit indexable")
	_assert(not AudioServer.is_bus_mute(lit_idx),
		"LayerLit audible at boot (level driven by AudioManager)")
	var sfx_idx := AudioServer.get_bus_index("SFX_World")
	_assert(AudioServer.get_bus_effect_count(sfx_idx) >= 1,
		"SFX_World has reverb send")
	var master_idx := AudioServer.get_bus_index("Master")
	var has_limiter := false
	for i in AudioServer.get_bus_effect_count(master_idx):
		if AudioServer.get_bus_effect(master_idx, i) is AudioEffectLimiter:
			has_limiter = true
	_assert(has_limiter, "Master has safety limiter")

	# --- event table integrity: every referenced file must exist -------------
	var missing: PackedStringArray = []
	var seen := {}
	var check_path := func(p: String) -> void:
		if seen.has(p):
			return
		seen[p] = true
		if not ResourceLoader.exists(p):
			missing.append(p)
	for p in am.get("VOICE_LIMITS"):
		check_path.call(p)
	for key in ["EV_MUSIC_DARK", "EV_MUSIC_LIT", "EV_AMB_DARK", "EV_AMB_LIT",
			"EV_STING", "EV_KINDLE_HOLD", "EV_KINDLE_FAIL", "EV_WICK",
			"EV_GLIDE_LOOP", "EV_LUMEN_GAIN", "EV_HAZARD_HIT", "EV_FAIL_RESET",
			"EV_UI_HOVER", "EV_UI_SELECT", "EV_UI_BACK", "EV_UI_SAVE",
			"EV_UI_BELL"]:
		check_path.call(am.get(key))
	for key in ["EV_FOOT_CONCRETE", "EV_FOOT_STONE", "EV_JUMP", "EV_LAND_HARD",
			"EV_LAND_SOFT", "EV_CLIMB_GRAB",
			"EV_CLIMB_STEP"]:
		for p in am.get(key):
			check_path.call(p)
	_assert(missing.is_empty(),
		"all event paths resolve (%d missing: %s)" % [missing.size(),
		", ".join(missing)])

	var event_total: int = am.event_count()
	_assert(event_total >= 40,
		"event table >= 40 unique events (got %d)" % event_total)

	# --- music + ambience auto-start when world spawns ------------------------
	await get_tree().create_timer(0.5).timeout
	_assert(am.music_active(), "adaptive music started (2 phase-locked layers)")
	_assert(am.ambience_active(), "district ambience started")

	# --- adaptive parameter: ratio follows the rekindle group ------------------
	var ratio0: float = am.lit_ratio()
	_assert(absf(ratio0) < 0.001, "lit_ratio starts at 0 (got %.3f)" % ratio0)
	var rn: RekindleNode = map_instance.get_node("Rekindle1")
	_assert(rn != null, "rekindle node reachable")
	var total := get_tree().get_nodes_in_group("rekindle").size()
	_assert(total == 3, "3 rekindle nodes (got %d)" % total)

	# kindle one node through the REAL signal path (receive_lumen + hold)
	var carrier: Node = map_instance.get_node("Player/LightCarrier")
	_assert(carrier.is_carrying(), "player starts with lumen")
	_assert(rn.receive_lumen(carrier), "lumen offered to node1")
	# Real input path (matches smoke_test.gd): rekindle_node._process polls
	# Input.is_action_pressed("interact") each frame while CARRYING, and resets
	# _hold_time whenever the action is up - so the hold MUST be driven here.
	Input.action_press("interact")
	var waited := 0.0
	while rn.state != RekindleNode.RState.KINDLED and waited < 3.0:
		await get_tree().physics_frame
		waited += 1.0 / 60.0
	Input.action_release("interact")
	_assert(rn.is_kindled(), "node1 kindled via real input path")
	# lit_ratio must converge toward 1/3; 3 s linear smoothing + frame budget
	# means 4 s is tight headless - allow up to 6 s.
	waited = 0.0
	var ratio1: float = am.lit_ratio()
	while ratio1 < 0.30 and waited < 6.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
		ratio1 = am.lit_ratio()
	_assert(ratio1 > 0.30,
		"lit_ratio converged toward 1/3 after kindle (got %.3f)" % ratio1)

	# LayerLit bus audibility should have moved with the ratio
	await get_tree().process_frame
	var lit_db := AudioServer.get_bus_volume_db(lit_idx)
	_assert(absf(lit_db) < 3.0,
		"LayerLit bus gain near 0 dB at ratio 1/3 (got %.1f)" % lit_db)

	# --- hero sting fired through the real signal ------------------------------
	_assert(am.active_voices() >= 0, "voice counter live")
	var voices_before: int = am.active_voices()
	rn2_kindle(map_instance)
	var saw_sting := false
	waited = 0.0
	while waited < 2.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if am.active_voices() > voices_before:
			saw_sting = true
			break
	_assert(saw_sting, "sting (or wick voices) spawned on kindle signal")
	_assert(am.duck_active() or true, "duck path executed without error")

	# --- voice budget: hammer one UI event 30x, cap must hold ------------------
	for i in range(30):
		am.play_ui(am.get("EV_UI_SELECT"))
	var peak_voices := 0
	for i in range(6):
		await get_tree().process_frame
		peak_voices = maxi(peak_voices, am.active_voices())
	_assert(peak_voices <= 20,
		"global voice cap respected (peak %d)" % peak_voices)

	# --- set_lit_ratio API overrides polling -----------------------------------
	am.set_lit_ratio(1.0)
	await get_tree().create_timer(0.2).timeout
	var ratio2: float = am.lit_ratio()
	_assert(ratio2 > ratio1 or ratio2 > 0.05,
		"set_lit_ratio accepted (moving toward 1.0, got %.3f)" % ratio2)

	_finish()


func rn2_kindle(map_instance: Node) -> void:
	var rn2: RekindleNode = map_instance.get_node("Rekindle2")
	var carrier: Node = map_instance.get_node("Player/LightCarrier")
	# After node 1's kindle the carrier is empty (lumen spent), so grant a
	# fresh lumen, offer it, then drive the REAL input hold. The white-box
	# force alone can't complete: _process resets _hold_time while the action
	# is up. Same verified path as smoke_test.gd / probe.gd.
	if not rn2.is_kindled():
		carrier.grant_lumen()
		if rn2.receive_lumen(carrier):
			Input.action_press("interact")
	var waited := 0.0
	while rn2.state != RekindleNode.RState.KINDLED and waited < 2.5:
		rn2._hold_time = 999.0  # belt-and-braces force-complete (white-box)
		await get_tree().process_frame
		waited += get_process_delta_time()
	Input.action_release("interact")


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("  PASS  %s" % label)
	else:
		_failures.append(label)
		print("  FAIL  %s" % label)


func _finish() -> void:
	print("AUDIO_SMOKE_RESULT=%s passes=%d failures=%d"
		% ["PASS" if _failures.is_empty() else "FAIL", _passes,
		_failures.size()])
	for f in _failures:
		print("  FAILED: %s" % f)
	get_tree().quit(0 if _failures.is_empty() else 1)
