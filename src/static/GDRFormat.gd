class_name GDRFormat
extends RefCounted
## Reader and writer for GDR ("Geometry Dash Replay"), the .gdr interchange
## format used across the GD replay ecosystem (Mega Hack, GDRMobile, xdBot,
## zBot, ...).
##
## A GDR 1 file is a MessagePack-serialized (JSON also occurs) dictionary
## with author/bot/level metadata and an "inputs" array of edge events:
## { "2p": bool, "btn": 1=Jump/2=Left/3=Right, "down": bool, "frame": int },
## sorted by frame, ticking at the recording's "framerate" (240/s by
## default - the same rate this engine's physics run at).
##
## This engine records one [jump_state, direction] pair per physics tick
## instead of edges, and has an input the format predates: the platformer
## wave descend. The conversion therefore:
##  - turns Jump edges into btn 1 events and, for platformer replays,
##    Left/Right edges into btn 2/3 events;
##  - keeps wave-descend edges in a "dashExt" dictionary - the same
##    bot-extension mechanism xdBot uses for its "frameFixes" - so our own
##    replays survive a .gdr round trip losslessly while foreign tools
##    simply ignore the extra key;
##  - resamples replays recorded at another framerate to this engine's
##    physics rate on load.
##  - ignores player-2 events: this engine's dual players mirror player 1.


const BUTTON_JUMP := 1
const BUTTON_LEFT := 2
const BUTTON_RIGHT := 3

const BOT_NAME := "Godot-Dash"
const GAME_VERSION := 2.2
const FORMAT_VERSION := 1.0
const FILE_EXTENSION := ".gdr"
## Defensive ceiling for imported replays (one hour at 240 ticks/s): a
## corrupt duration field must not translate into a multi-gigabyte array.
const MAX_IMPORT_TICKS := 240 * 60 * 60


static func physics_framerate() -> float:
	return float(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 240.0))


static func to_bytes(replay: Replay) -> PackedByteArray:
	var inputs: Array = []
	var wave_down_events: Array = []
	_collect_input_edges(replay, inputs, wave_down_events)

	# Keys are written in alphabetical order, matching the layout of the
	# .gdr files the ecosystem tools produce.
	var document := {}
	document["author"] = replay.author
	document["bot"] = {
		"name": BOT_NAME,
		"version": str(ProjectSettings.get_setting("application/config/version", "1.0")),
	}
	document["coins"] = 0
	if not wave_down_events.is_empty():
		document["dashExt"] = {"waveDown": wave_down_events}
	document["description"] = replay.description
	document["duration"] = float(replay.data.size()) / physics_framerate()
	document["framerate"] = physics_framerate()
	document["gameVersion"] = GAME_VERSION
	document["inputs"] = inputs
	document["ldm"] = false
	document["level"] = {"id": replay.level_id, "name": replay.level_name}
	document["platformer"] = replay.platformer
	document["seed"] = 0
	document["version"] = FORMAT_VERSION
	return MsgPack.encode(document)


static func from_bytes(bytes: PackedByteArray) -> Dictionary:
	# GDR 1 is MessagePack in the wild, but JSON is legal too (the reference
	# converter accepts both). Sniff the first byte, and fall back to the
	# other parser if the obvious one fails.
	var document: Variant = null
	var error := ""
	if bytes.size() > 0 and bytes[0] == 0x7b: # '{'
		var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY:
			document = parsed
		else:
			error = "not a valid JSON document"
	else:
		var result := MsgPack.decode(bytes)
		if result.ok:
			document = result.value
		else:
			var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				document = parsed
			else:
				error = result.error
	if typeof(document) != TYPE_DICTIONARY:
		return {"ok": false, "error": "not a GDR document (%s)" % error}
	return _replay_from_document(document)


static func save(replay: Replay, path: String) -> Error:
	var bytes := to_bytes(replay)
	if bytes.is_empty():
		return ERR_INVALID_DATA
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(bytes)
	var error := file.get_error()
	file.close()
	return error


static func load(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "could not open replay (%s)" % error_string(FileAccess.get_open_error())}
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return from_bytes(bytes)


static func _collect_input_edges(replay: Replay, inputs: Array, wave_down_events: Array) -> void:
	# The recorded state before tick 0 is "nothing held": an input already
	# down at tick 0 becomes an event on frame 0, as the format expects.
	var jump_held := false
	var wave_down := false
	var direction := 0
	for tick: int in replay.data.size():
		var tick_jump := replay.pressing_jump(tick)
		var tick_wave_down := replay.pressing_down(tick)
		if tick_jump != jump_held:
			inputs.append(_input_event(tick, BUTTON_JUMP, tick_jump))
		if tick_wave_down != wave_down:
			wave_down_events.append([tick, tick_wave_down])
		jump_held = tick_jump
		wave_down = tick_wave_down
		# Direction is only meaningful in platformer levels: elsewhere it is
		# a constant and emitting it would wrongly mark the replay as
		# platformer for the ecosystem tools.
		if replay.platformer:
			var tick_direction := replay.get_direction(tick)
			if tick_direction != direction:
				if direction == -1:
					inputs.append(_input_event(tick, BUTTON_LEFT, false))
				elif direction == 1:
					inputs.append(_input_event(tick, BUTTON_RIGHT, false))
				if tick_direction == -1:
					inputs.append(_input_event(tick, BUTTON_LEFT, true))
				elif tick_direction == 1:
					inputs.append(_input_event(tick, BUTTON_RIGHT, true))
				direction = tick_direction


static func _input_event(frame: int, button: int, down: bool) -> Dictionary:
	return {"2p": false, "btn": button, "down": down, "frame": frame}


static func _replay_from_document(document: Dictionary) -> Dictionary:
	if not document.has("inputs"):
		return {"ok": false, "error": "GDR document has no inputs array"}
	var inputs_value: Variant = document.get("inputs")
	if typeof(inputs_value) != TYPE_ARRAY:
		return {"ok": false, "error": "GDR document has no inputs array"}

	var framerate := _as_float(document.get("framerate", 240.0))
	if framerate <= 0.0:
		framerate = 240.0
	# Foreign replays may be recorded at another rate (physics bypass);
	# resample their frames onto this engine's physics ticks.
	var scale := physics_framerate() / framerate

	# Normalize every event into one frame-sorted stream. The format allows
	# P1 and P2 events interleaved out of order and requires sorting after
	# parsing; the sequence number keeps same-frame events in file order
	# (sort_custom is not stable).
	var inputs: Array = inputs_value
	var events: Array = []
	var has_directional_input := false
	var sequence := 0
	for entry_value: Variant in inputs:
		if typeof(entry_value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_value
		if _as_bool(entry.get("2p", false)):
			continue
		var button := int(_as_number(entry.get("btn", 0)))
		if button == BUTTON_LEFT or button == BUTTON_RIGHT:
			has_directional_input = true
		events.append({
			"frame": int(_as_number(entry.get("frame", 0))),
			"btn": button,
			"down": _as_bool(entry.get("down", false)),
			"wave": false,
			"seq": sequence,
		})
		sequence += 1
	var dash_ext: Variant = document.get("dashExt", {})
	if typeof(dash_ext) == TYPE_DICTIONARY:
		var wave_down_list_value: Variant = dash_ext.get("waveDown", [])
		if typeof(wave_down_list_value) == TYPE_ARRAY:
			var wave_down_list: Array = wave_down_list_value
			for pair_value: Variant in wave_down_list:
				if typeof(pair_value) != TYPE_ARRAY:
					continue
				var pair: Array = pair_value
				if pair.size() >= 2:
					events.append({
						"frame": int(_as_number(pair[0])),
						"btn": 0,
						"down": _as_bool(pair[1]),
						"wave": true,
						"seq": sequence,
					})
					sequence += 1
	events.sort_custom(func(a, b): return a.frame < b.frame or (a.frame == b.frame and a.seq < b.seq))

	var total_frames := 0
	for event: Dictionary in events:
		total_frames = maxi(total_frames, event.frame + 1)
	total_frames = maxi(total_frames, int(round(_as_float(document.get("duration", 0.0)) * framerate)))
	var total_ticks := ceili(float(total_frames) * scale)
	if total_ticks > MAX_IMPORT_TICKS:
		return {"ok": false, "error": "replay is too long (%d frames)" % total_frames}

	var replay := Replay.new()
	var level_value: Variant = document.get("level", {})
	var level: Dictionary = level_value if typeof(level_value) == TYPE_DICTIONARY else {}
	replay.level_name = str(level.get("name", ""))
	replay.level_id = int(_as_number(level.get("id", 0)))
	replay.author = str(document.get("author", ""))
	replay.description = str(document.get("description", ""))
	replay.platformer = _as_bool(document.get("platformer", has_directional_input))

	var data: Array[PackedByteArray] = []
	var jump := false
	var wave_down := false
	var left := false
	var right := false
	var cursor := 0
	for event: Dictionary in events:
		var tick := maxi(int(round(float(event.frame) * scale)), cursor)
		while cursor < tick:
			data.append(PackedByteArray([
				_jump_state(jump, wave_down),
				_direction(left, right) + 1 if replay.platformer else 1,
			]))
			cursor += 1
		if event.wave:
			wave_down = event.down
		elif event.btn == BUTTON_JUMP:
			jump = event.down
		elif event.btn == BUTTON_LEFT:
			left = event.down
		elif event.btn == BUTTON_RIGHT:
			right = event.down
		# Unknown buttons from foreign files are ignored.
	while cursor < total_ticks:
		data.append(PackedByteArray([
			_jump_state(jump, wave_down),
			_direction(left, right) + 1 if replay.platformer else 1,
		]))
		cursor += 1
	replay.data = data
	return {"ok": true, "replay": replay}


static func _jump_state(jump: bool, wave_down: bool) -> int:
	# Stored representation: 0 none, 1 jump, 2 wave descend (the wave
	# descend wins over a held jump, matching the recorder).
	if wave_down:
		return 2
	return 1 if jump else 0


static func _direction(left: bool, right: bool) -> int:
	return (1 if right else 0) - (1 if left else 0)


static func _as_number(value: Variant) -> float:
	# JSON parsing turns every number into a float; MessagePack keeps ints.
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return float(value)
		_:
			return 0.0


static func _as_float(value: Variant) -> float:
	return _as_number(value)


static func _as_bool(value: Variant) -> bool:
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			return bool(value)
		_:
			return false
