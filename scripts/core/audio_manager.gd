extends Node
## AudioManager (AGE-23) - LUMENFALL v1 audio implementation.
##
## Design bible: audio/AUDIO_BIBLE.md (sonic identity: warm analog synth + strings).
## Event system: every game sound fires through the named-event table below -
## no hardcoded asset paths in gameplay code (role rule). Voice budgets are
## enforced here (per-event + global cap, priority steal-oldest).
##
## Adaptive music (2 layers, phase-locked 4-bar loop @ 72 BPM):
##   LayerDark - Am(add9) Fmaj7 Am G6, filtered analog pad + sub pulse.
##   LayerLit  - A E F#m D, string ensemble + Karplus arpeggio.
##   district_lit_ratio = kindled / total rekindle nodes (matches the F9
##   overlay "nodes k/n" readout exactly). Ratio drives the LayerLit bus
##   volume and the LayerDark filter cutoff; 3 s smoothed, bar-quantised NOT
##   required because both layers run continuously from the same start frame.
##
## Hooks (all attached via tree observation - zero edits to AGE-21 scripts):
##   rekindle.kindled            -> Rekindle_Sting (hero) + music duck -6 dB
##   rekindle.state_changed      -> CARRYING: hold cue; leaving: stop cue
##   rekindle.kindle_progress    -> release at 0: stop + Kindle_Fail
##   light_carrier.lumen_changed -> grant: Lumen_Gain
##   checkpoint.checkpoint_saved -> Checkpoint_Bell
##   player.state_changed        -> movement/locomotion cues
##   player.gliding_changed      -> glide loop start/stop
##   footstep scheduler          -> GROUNDED + speed -> stride-scaled steps

const DEBUG_AUDIO := false  # set true for verbose event logging

# ------------------------------------------------------------------ events --
# Named event table. Values: res:// paths. Arrays = random-variant pools.
const EV_MUSIC_DARK := "res://audio/wav/music/district_loop_layerdark.wav"
const EV_MUSIC_LIT := "res://audio/wav/music/district_loop_layerlit.wav"
const EV_AMB_DARK := "res://audio/wav/ambience/district_dark_loop.wav"
const EV_AMB_LIT := "res://audio/wav/ambience/district_lit_loop.wav"

const EV_STING := "res://audio/wav/beacon/rekindle_sting.wav"
const EV_KINDLE_HOLD := "res://audio/wav/beacon/kindle_hold.wav"
const EV_KINDLE_FAIL := "res://audio/wav/beacon/kindle_fail.wav"
const EV_WICK := "res://audio/wav/beacon/beacon_wick_loop.wav"

const EV_FOOT_CONCRETE := [
	"res://audio/wav/player/footstep_concrete_01.wav",
	"res://audio/wav/player/footstep_concrete_02.wav",
	"res://audio/wav/player/footstep_concrete_03.wav",
	"res://audio/wav/player/footstep_concrete_04.wav",
	"res://audio/wav/player/footstep_concrete_05.wav",
	"res://audio/wav/player/footstep_concrete_06.wav",
	"res://audio/wav/player/footstep_concrete_07.wav",
	"res://audio/wav/player/footstep_concrete_08.wav",
]
const EV_FOOT_STONE := [
	"res://audio/wav/player/footstep_stone_01.wav",
	"res://audio/wav/player/footstep_stone_02.wav",
	"res://audio/wav/player/footstep_stone_03.wav",
	"res://audio/wav/player/footstep_stone_04.wav",
	"res://audio/wav/player/footstep_stone_05.wav",
	"res://audio/wav/player/footstep_stone_06.wav",
]
const EV_JUMP := [
	"res://audio/wav/player/jump_01.wav",
	"res://audio/wav/player/jump_02.wav",
]
const EV_LAND_HARD := [
	"res://audio/wav/player/land_hard_01.wav",
	"res://audio/wav/player/land_hard_02.wav",
]
const EV_LAND_SOFT := [
	"res://audio/wav/player/land_soft_01.wav",
	"res://audio/wav/player/land_soft_02.wav",
]
const EV_GLIDE_LOOP := "res://audio/wav/player/glide_loop.wav"
const EV_CLIMB_GRAB := [
	"res://audio/wav/player/climb_grab_01.wav",
	"res://audio/wav/player/climb_grab_02.wav",
]
const EV_CLIMB_STEP := [
	"res://audio/wav/player/climb_step_01.wav",
	"res://audio/wav/player/climb_step_02.wav",
	"res://audio/wav/player/climb_step_03.wav",
]
const EV_LUMEN_GAIN := "res://audio/wav/player/lumen_gain.wav"

const EV_HAZARD_HIT := "res://audio/wav/world/hazard_hit.wav"
const EV_FAIL_RESET := "res://audio/wav/world/fail_reset.wav"

const EV_UI_HOVER := "res://audio/wav/ui/hover.wav"
const EV_UI_SELECT := "res://audio/wav/ui/select.wav"
const EV_UI_BACK := "res://audio/wav/ui/back.wav"
const EV_UI_SAVE := "res://audio/wav/ui/save_chime.wav"
const EV_UI_BELL := "res://audio/wav/ui/checkpoint_bell.wav"

# ------------------------------------------------------------------ budget --
# Per-event voice limits (bible: no event ships with defaults).
const VOICE_LIMITS := {
	EV_STING: 2,
	EV_KINDLE_HOLD: 1,
	EV_KINDLE_FAIL: 2,
	EV_WICK: 12,
	EV_GLIDE_LOOP: 1,
	EV_LUMEN_GAIN: 2,
	EV_HAZARD_HIT: 4,
	EV_FAIL_RESET: 2,
	EV_UI_BELL: 2,
	EV_UI_HOVER: 4,
	EV_UI_SELECT: 4,
	EV_UI_BACK: 4,
	EV_UI_SAVE: 2,
}
const DEFAULT_VOICE_LIMIT := 6
const GLOBAL_VOICE_CAP := 20
const MUSIC_DUCK_DB := -6.0
const MUSIC_DUCK_ATTACK := 0.08
const MUSIC_DUCK_HOLD := 0.6
const MUSIC_DUCK_RELEASE := 2.2
const LIT_SMOOTH := 3.0  # seconds to converge on a new lit_ratio target

var _streams := {}          # path -> AudioStream
var _voices: Array[Node] = []  # active one-shot players, oldest first
var _music_dark: AudioStreamPlayer
var _music_lit: AudioStreamPlayer
var _amb_dark: AudioStreamPlayer
var _amb_lit: AudioStreamPlayer
var _hold_cue: AudioStreamPlayer3D = null
var _hold_cue_owner: Node = null
var _glide_player: AudioStreamPlayer = null
var _lit_target := 0.0
var _lit_smooth := 0.0
var _auto_poll := true
var _music_running := false
var _ambience_running := false
var _duck_tween: Tween
var _player_prev_state := ""
var _player_prev_vel_y := 0.0
var _stride_accum := 0.0
var _climb_accum := 0.0
var _surface := "concrete"  # v1 greybox: single surface; stone reserved v1.1

@onready var _bus_music := AudioServer.get_bus_index("Music")
@onready var _bus_dark := AudioServer.get_bus_index("LayerDark")
@onready var _bus_lit := AudioServer.get_bus_index("LayerLit")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_on_node_added)


# ------------------------------------------------------- tree observation --
func _on_node_added(node: Node) -> void:
	# Groups are assigned inside the node's own _ready(), which runs after
	# node_added fires; wait for ready unless the node is already settled.
	if node.is_node_ready():
		_on_node_ready(node)
	else:
		node.ready.connect(_on_node_ready.bind(node), CONNECT_ONE_SHOT)


func _on_node_ready(node: Node) -> void:
	if node.is_in_group("rekindle"):
		if node.has_signal("kindled"):
			node.kindled.connect(_on_kindled)
		if node.has_signal("state_changed"):
			node.state_changed.connect(_on_rekindle_state)
		if node.has_signal("kindle_progress_changed"):
			node.kindle_progress_changed.connect(_on_kindle_progress.bind(node))
		_start_world_audio_once()
	elif node.is_in_group("player"):
		if node.has_signal("state_changed"):
			node.state_changed.connect(_on_player_state)
		if node.has_signal("gliding_changed"):
			node.gliding_changed.connect(_on_player_glide)
	elif node.has_signal("lumen_changed"):
		node.lumen_changed.connect(_on_lumen_changed)
	elif node.has_signal("checkpoint_saved"):
		node.checkpoint_saved.connect(_on_checkpoint_saved)


# ----------------------------------------------------------- public API ----
## Gameplay/audio director sets district lit ratio (0..1). If never called,
## the manager polls the rekindle group (default, matches F9 overlay).
func set_lit_ratio(ratio: float) -> void:
	_auto_poll = false
	_lit_target = clampf(ratio, 0.0, 1.0)


func lit_ratio() -> float:
	return _lit_smooth


func music_active() -> bool:
	return _music_running


func ambience_active() -> bool:
	return _ambience_running


func active_voices() -> int:
	return _voices.size()


func duck_active() -> bool:
	return _duck_tween != null and _duck_tween.is_running()


## Introspection for tests/overlay: every event name in the table.
func event_count() -> int:
	var seen := {}
	for v in VOICE_LIMITS:
		seen[v] = true
	for v in [EV_MUSIC_DARK, EV_MUSIC_LIT, EV_AMB_DARK, EV_AMB_LIT, EV_STING,
			EV_KINDLE_HOLD, EV_KINDLE_FAIL, EV_WICK, EV_GLIDE_LOOP,
			EV_LUMEN_GAIN, EV_HAZARD_HIT, EV_FAIL_RESET, EV_UI_HOVER,
			EV_UI_SELECT, EV_UI_BACK, EV_UI_SAVE, EV_UI_BELL]:
		seen[v] = true
	for arr in [EV_FOOT_CONCRETE, EV_FOOT_STONE, EV_JUMP, EV_LAND_HARD,
			EV_LAND_SOFT, EV_CLIMB_GRAB, EV_CLIMB_STEP]:
		for v in arr:
			seen[v] = true
	return seen.size()


# ------------------------------------------------------------- playback ----
func _stream(path: String) -> AudioStream:
	if not _streams.has(path):
		var s := load(path)
		if s == null:
			push_warning("AudioManager: missing stream %s" % path)
			return null
		_streams[path] = s
	return _streams[path]


func play_ui(event_path: String, volume_db := 0.0) -> void:
	_play_2d(event_path, "UI", volume_db, 0)


func play_world(event_path: String, pos: Vector3, volume_db := 0.0) -> void:
	_play_3d(event_path, "SFX_World", pos, volume_db, 0)


func play_player(event_path: String, pos: Vector3, volume_db := 0.0) -> void:
	_play_3d(event_path, "SFX_Player", pos, volume_db, 0)


func play_random(event_paths: Array, pos: Vector3, bus := "SFX_Player",
		volume_db := 0.0) -> void:
	if event_paths.is_empty():
		return
	var path: String = event_paths[randi() % event_paths.size()]
	_play_3d(path, bus, pos, volume_db, 0)


func _play_2d(event_path: String, bus: String, volume_db: float,
		priority: int) -> AudioStreamPlayer:
	var stream := _stream(event_path)
	if stream == null:
		return null
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = bus
	p.volume_db = volume_db
	p.finished.connect(_on_voice_done.bind(p))
	return _register_voice(p, volume_db, priority, Vector3.ZERO)


func _play_3d(event_path: String, bus: String, pos: Vector3, volume_db: float,
		priority: int) -> AudioStreamPlayer3D:
	var stream := _stream(event_path)
	if stream == null:
		return null
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = bus
	p.volume_db = volume_db
	p.unit_size = 8.0
	p.max_distance = 48.0
	p.finished.connect(_on_voice_done.bind(p))
	return _register_voice(p, volume_db, priority, pos)


func _register_voice(p: Node, volume_db: float, priority: int,
		pos: Vector3) -> Node:
	# Prune voices freed with their scene (external frees skip _kill_voice).
	for i in range(_voices.size() - 1, -1, -1):
		if not is_instance_valid(_voices[i]):
			_voices.remove_at(i)
	var limit := int(VOICE_LIMITS.get(_event_of(p), DEFAULT_VOICE_LIMIT))
	var family := _event_of(p)
	var count := 0
	for v in _voices:
		if _event_of(v) == family:
			count += 1
	if count >= limit:
		# steal-oldest within the same event family
		for v in _voices:
			if _event_of(v) == family:
				_kill_voice(v)
				break
	if _voices.size() >= GLOBAL_VOICE_CAP:
		_kill_voice(_voices[0])  # global: steal oldest
	add_child(p)
	if p is AudioStreamPlayer3D:
		(p as AudioStreamPlayer3D).global_position = pos
	p.volume_db = volume_db
	p.set_meta("priority", priority)
	p.play()
	_voices.append(p)
	if DEBUG_AUDIO:
		print("[audio] play ", _event_of(p))
	return p


func _event_of(p: Node) -> String:
	if not is_instance_valid(p):
		return ""
	var stream: AudioStream = p.get("stream")
	if stream == null:
		return ""
	for path in _streams:
		if _streams[path] == stream:
			return path
	return ""


func _kill_voice(p: Node) -> void:
	_voices.erase(p)
	p.queue_free()


func _on_voice_done(p: Node) -> void:
	_voices.erase(p)
	p.queue_free()


# ------------------------------------------------------------ music/ambience
func _start_world_audio_once() -> void:
	if not _music_running:
		_start_music()
	if not _ambience_running:
		_start_ambience()


func _start_music() -> void:
	var dark := _stream(EV_MUSIC_DARK)
	var lit := _stream(EV_MUSIC_LIT)
	if dark == null or lit == null:
		return
	_music_dark = AudioStreamPlayer.new()
	_music_dark.stream = dark
	_music_dark.bus = "LayerDark"
	add_child(_music_dark)
	_music_lit = AudioStreamPlayer.new()
	_music_lit.stream = lit
	_music_lit.bus = "LayerLit"
	add_child(_music_lit)
	# Both layers start the same frame -> sample-locked phase relationship.
	_music_dark.play()
	_music_lit.play()
	_music_lit.volume_db = -60.0
	_music_running = true


func _start_ambience() -> void:
	var dark := _stream(EV_AMB_DARK)
	var lit := _stream(EV_AMB_LIT)
	if dark == null or lit == null:
		return
	_amb_dark = AudioStreamPlayer.new()
	_amb_dark.stream = dark
	_amb_dark.bus = "Ambience"
	add_child(_amb_dark)
	_amb_lit = AudioStreamPlayer.new()
	_amb_lit.stream = lit
	_amb_lit.bus = "Ambience"
	add_child(_amb_lit)
	_amb_dark.play()
	_amb_lit.play()
	_amb_lit.volume_db = -60.0
	_ambience_running = true


func _process(delta: float) -> void:
	if _auto_poll:
		var kindled := 0
		var total := 0
		for rn in get_tree().get_nodes_in_group("rekindle"):
			total += 1
			if "is_kindled" in rn and rn.is_kindled():
				kindled += 1
		_lit_target = (float(kindled) / float(total)) if total > 0 else 0.0
	var k := clampf(delta / max(LIT_SMOOTH, 0.001), 0.0, 1.0)
	_lit_smooth += (_lit_target - _lit_smooth) * k

	# LayerLit volume follows the smoothed ratio; LayerDark opens its filter.
	if _music_running:
		_music_lit.volume_db = maxf(linear_to_db(_lit_smooth), -60.0)
		_music_dark.volume_db = 0.0
		if _bus_dark >= 0 and AudioServer.get_bus_effect_count(_bus_dark) > 0:
			var eff := AudioServer.get_bus_effect(_bus_dark, 0)
			if eff is AudioEffectLowPassFilter:
				(eff as AudioEffectLowPassFilter).cutoff_hz = lerpf(800.0, 9000.0, _lit_smooth)
	# Ambience crossfades between district states.
	if _ambience_running:
		_amb_lit.volume_db = maxf(linear_to_db(_lit_smooth), -60.0)
		_amb_dark.volume_db = maxf(linear_to_db(1.0 - _lit_smooth), -60.0)

	_footstep_scheduler(delta)


# --------------------------------------------------------------- hooks -----
func _on_kindled(node_id: String) -> void:
	var tree := get_tree()
	var player := tree.get_first_node_in_group("player")
	var pos: Vector3 = (player as Node3D).global_position \
		if player is Node3D else Vector3.ZERO
	# locate the actual node for a positional sting when possible
	for rn in tree.get_nodes_in_group("rekindle"):
		if "node_id" in rn and rn.node_id == node_id and rn is Node3D:
			pos = (rn as Node3D).global_position
			break
	_play_3d(EV_STING, "SFX_World", pos, 0.0, 10)
	_duck_music()


func _duck_music() -> void:
	if _duck_tween != null and _duck_tween.is_running():
		_duck_tween.kill()
	if not _music_running:
		return
	_duck_tween = create_tween()
	_duck_tween.tween_property(_music_dark, "volume_db",
		MUSIC_DUCK_DB, MUSIC_DUCK_ATTACK)
	_duck_tween.tween_interval(MUSIC_DUCK_HOLD)
	_duck_tween.tween_property(_music_dark, "volume_db", 0.0,
		MUSIC_DUCK_RELEASE)


func _on_rekindle_state(node_id: String, new_state: String) -> void:
	var rn := _rekindle_by_id(node_id)
	match new_state:
		"CARRYING":
			_start_hold_cue(rn)
		"KINDLED":
			_stop_hold_cue(false)
		"DORMANT":
			# dim-back (v2) or restored-from-save without kindle: no fanfare
			if _hold_cue_owner == rn:
				_stop_hold_cue(false)


func _start_hold_cue(rn: Node) -> void:
	if rn == null or _hold_cue_owner == rn:
		return
	_stop_hold_cue(false)
	_hold_cue_owner = rn
	var pos: Vector3 = (rn as Node3D).global_position if rn is Node3D \
		else Vector3.ZERO
	_hold_cue = _play_3d(EV_KINDLE_HOLD, "SFX_World", pos, -2.0, 5)


func _stop_hold_cue(failed: bool) -> void:
	if _hold_cue != null and is_instance_valid(_hold_cue):
		_hold_cue.queue_free()
	_hold_cue = null
	if failed and _hold_cue_owner != null:
		var rn := _hold_cue_owner
		var pos: Vector3 = (rn as Node3D).global_position if rn is Node3D \
			else Vector3.ZERO
		_play_3d(EV_KINDLE_FAIL, "SFX_World", pos, 0.0, 3)
	_hold_cue_owner = null


func _on_kindle_progress(ratio: float, rn: Node) -> void:
	# Release before completion: progress collapses to 0 while still CARRYING.
	if ratio <= 0.0 and _hold_cue_owner == rn and rn.state == 1:  # RState.CARRYING
		_stop_hold_cue(true)


func _on_lumen_changed(carrying: bool) -> void:
	if carrying:
		var player := get_tree().get_first_node_in_group("player")
		var pos: Vector3 = (player as Node3D).global_position \
			if player is Node3D else Vector3.ZERO
		_play_3d(EV_LUMEN_GAIN, "SFX_Player", pos, 0.0, 4)


func _on_checkpoint_saved(_id: String) -> void:
	play_ui(EV_UI_BELL, -1.0)


func _on_player_glide(active: bool) -> void:
	if active:
		if _glide_player == null or not is_instance_valid(_glide_player):
			_glide_player = _play_2d(EV_GLIDE_LOOP, "SFX_Player", -4.0, 2)
	else:
		if _glide_player != null and is_instance_valid(_glide_player):
			_glide_player.queue_free()
		_glide_player = null


func _on_player_state(new_state: String) -> void:
	var player := get_tree().get_first_node_in_group("player")
	var pos: Vector3 = (player as Node3D).global_position \
		if player is Node3D else Vector3.ZERO
	match new_state:
		"AIRBORNE":
			if _player_prev_state == "GROUNDED":
				play_random(EV_JUMP, pos, "SFX_Player", -3.0)
		"GROUNDED":
			if _player_prev_state == "AIRBORNE" and _player_prev_vel_y < -9.0:
				play_random(EV_LAND_HARD, pos, "SFX_Player", 0.0)
			elif _player_prev_state == "AIRBORNE":
				play_random(EV_LAND_SOFT, pos, "SFX_Player", -3.0)
			_stride_accum = 0.0
		"CLIMBING":
			play_random(EV_CLIMB_GRAB, pos, "SFX_Player", -3.0)
			_climb_accum = 0.0
	_player_prev_state = new_state


func _footstep_scheduler(delta: float) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null or not ("move_state" in player):
		return
	var state: int = player.move_state
	var vel: Vector3 = player.velocity if "velocity" in player \
		else Vector3.ZERO
	_player_prev_vel_y = vel.y
	var speed := Vector3(vel.x, 0.0, vel.z).length()
	var pos: Vector3 = (player as Node3D).global_position \
		if player is Node3D else Vector3.ZERO
	if state == 0 and speed > 0.6:  # GROUNDED and moving
		# stride scales with speed: ~0.53 s walk, ~0.37 s run cadence
		_stride_accum += speed * delta
		var stride := 2.6 if speed > 5.0 else 2.1
		if _stride_accum >= stride:
			_stride_accum = 0.0
			play_random(
				EV_FOOT_CONCRETE if _surface == "concrete" else EV_FOOT_STONE,
				pos, "SFX_Player", -6.0)
	elif state == 2:  # CLIMBING
		_climb_accum += speed * delta
		if _climb_accum >= 1.4:
			_climb_accum = 0.0
			play_random(EV_CLIMB_STEP, pos, "SFX_Player", -5.0)


func _rekindle_by_id(node_id: String) -> Node:
	for rn in get_tree().get_nodes_in_group("rekindle"):
		if "node_id" in rn and rn.node_id == node_id:
			return rn
	return null
