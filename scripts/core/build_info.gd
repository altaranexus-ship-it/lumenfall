extends Node
## BuildInfo - QA gate Q-17: build id + git commit hash surfaced to the debug overlay.
## Reads res://build/build_info.json, stamped by scripts_tool/stamp_build.sh before
## play/export. Missing file degrades to "unknown" (tests fail on that).

const INFO_PATH := "res://build/build_info.json"

var _info: Dictionary = {}


func _ready() -> void:
	_info = _load()


func _load() -> Dictionary:
	if FileAccess.file_exists(INFO_PATH):
		var f := FileAccess.open(INFO_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				return parsed
	return {}


func commit() -> String:
	return str(_info.get("commit", "unknown"))


func commit_short() -> String:
	return str(_info.get("commit_short", "unknown"))


func build_id() -> String:
	return str(_info.get("build_id", "unknown"))


func dirty() -> bool:
	return bool(_info.get("dirty", false))


func label() -> String:
	var suffix := "-dirty" if dirty() else ""
	return "%s+%s%s" % [build_id(), commit_short(), suffix]


func engine_version() -> String:
	var v := Engine.get_version_info()
	return "%d.%d.%s.%s" % [int(v.major), int(v.minor), str(v.status), str(v.build)]
