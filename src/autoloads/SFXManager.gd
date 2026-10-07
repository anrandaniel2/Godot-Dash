extends Node

var players: Array[AudioStreamPlayer] = []
var _stream_cache: Dictionary = {}
var _downloading_ids: Dictionary = {}

## Level SFX started by SFX triggers (3602) and edited by Edit SFX (3603).
## The native trigger runtime parses the triggers and calls
## [method trigger_sfx], [method edit_sfx] and [method reset_level_sfx].
## gd_docs (UHDanke) triggers/audio/sfx.md, edit_sfx.md, pitch_speed.md.
class SfxVoice:
	extends RefCounted
	var player: AudioStreamPlayer
	var unique_id: int = 0
	var sfx_group: int = 0
	var group_id: int = 0
	var start_s: float = 0.0
	var end_s: float = 0.0
	var loop: bool = false
	var fade_in_s: float = 0.0
	var fade_out_s: float = 0.0
	var age_s: float = 0.0
	var base_volume: float = 1.0
	var volume_mult: float = 1.0
	var volume_from: float = 1.0
	var volume_to: float = 1.0
	var volume_time: float = 0.0
	var volume_duration: float = 0.0
	var speed: float = 1.0
	var speed_from: float = 1.0
	var speed_to: float = 1.0
	var speed_time: float = 0.0
	var speed_duration: float = 0.0
	var stopping: bool = false
	var stop_time: float = 0.0

const LEVEL_SFX_BUS: StringName = &"In Level SFX"
var _voices: Array[SfxVoice] = []
## Pitch-shift buses by semitone (see _pitch_bus).
var _pitch_buses: Dictionary = {}


func get_sfx_stream(sfx_path: String) -> AudioStream:
	if _stream_cache.has(sfx_path):
		return _stream_cache[sfx_path]
	var stream: AudioStream = null
	if sfx_path.begins_with("res://"):
		if ResourceLoader.exists(sfx_path):
			stream = load(sfx_path)
	elif FileAccess.file_exists(sfx_path):
		var ext := sfx_path.get_extension().to_lower()
		if ext == "ogg":
			stream = AudioStreamOggVorbis.load_from_file(sfx_path)
		elif ext == "mp3":
			stream = AudioStreamMP3.new()
			var file := FileAccess.open(sfx_path, FileAccess.READ)
			if file != null:
				(stream as AudioStreamMP3).data = file.get_buffer(file.get_length())
	if stream != null:
		_stream_cache[sfx_path] = stream
	return stream


func play_sfx(sfx_path: String, bus: StringName = &"Game SFX", volume: float = 1.0, pitch: float = 1.0) -> void:
	var stream := get_sfx_stream(sfx_path)
	if stream == null:
		return
	var sfx_player := AudioStreamPlayer.new()
	players.append(sfx_player)
	add_child(sfx_player)
	# Previously every effect silently used Master, so both SFX sliders were
	# ineffective. Gameplay callers can select In Level SFX while menu/UI
	# effects retain the Game SFX default.
	sfx_player.bus = bus
	sfx_player.stream = stream
	sfx_player.volume_db = linear_to_db(clampf(volume, 0.0, 2.0))
	sfx_player.pitch_scale = clampf(pitch, 0.01, 5.0)
	sfx_player.play()
	await sfx_player.finished
	sfx_player.queue_free()
	players.erase(sfx_player)


func play_sfx_id(sfx_id: int, volume: float = 1.0, pitch: float = 1.0, bus: StringName = &"In Level SFX") -> void:
	if sfx_id <= 0:
		return
	var path := Constants.SFX_DIR + "sfx_%d.ogg" % sfx_id
	if _stream_cache.has(path):
		_play_stream(_stream_cache[path], bus, volume, pitch)
		return
	if FileAccess.file_exists(path):
		var stream := get_sfx_stream(path)
		if stream != null:
			_play_stream(stream, bus, volume, pitch)
		return

	_download_and_play_sfx(sfx_id, volume, pitch, bus)


func preload_sfx(sfx_ids: PackedInt32Array) -> void:
	for id in sfx_ids:
		if id <= 0:
			continue
		var path := Constants.SFX_DIR + "sfx_%d.ogg" % id
		if not _stream_cache.has(path) and not FileAccess.file_exists(path):
			_download_sfx_async(id)


func _download_sfx_async(sfx_id: int) -> void:
	if _downloading_ids.has(sfx_id):
		return
	_downloading_ids[sfx_id] = true
	var client := RobTopLevels.new()
	add_child(client)
	var res := await client.download_sfx(sfx_id)
	client.queue_free()
	_downloading_ids.erase(sfx_id)
	if res.ok:
		get_sfx_stream(res.get("path", Constants.SFX_DIR + "sfx_%d.ogg" % sfx_id))


func _download_and_play_sfx(sfx_id: int, volume: float, pitch: float, bus: StringName) -> void:
	if _downloading_ids.has(sfx_id):
		return
	_downloading_ids[sfx_id] = true
	var client := RobTopLevels.new()
	add_child(client)
	var res := await client.download_sfx(sfx_id)
	client.queue_free()
	_downloading_ids.erase(sfx_id)
	if res.ok:
		var stream := get_sfx_stream(res.get("path", Constants.SFX_DIR + "sfx_%d.ogg" % sfx_id))
		if stream != null:
			_play_stream(stream, bus, volume, pitch)


func _play_stream(stream: AudioStream, bus: StringName, volume: float, pitch: float) -> void:
	if stream == null:
		return
	var sfx_player := AudioStreamPlayer.new()
	players.append(sfx_player)
	add_child(sfx_player)
	sfx_player.bus = bus
	sfx_player.stream = stream
	sfx_player.volume_db = linear_to_db(clampf(volume, 0.0, 2.0))
	sfx_player.pitch_scale = clampf(pitch, 0.01, 5.0)
	sfx_player.play()
	await sfx_player.finished
	sfx_player.queue_free()
	players.erase(sfx_player)


## Speed and Pitch share the semitone scale: multiplier = 2^(v / 12),
## clamped to -12..12 by the audio engine (pitch_speed.md).
static func semitone_multiplier(value: float) -> float:
	return pow(2.0, clampf(value, -12.0, 12.0) / 12.0)


## Pitch changes the pitch without the speed. Godot's per-player pitch_scale
## changes both, so speed uses pitch_scale and pitch goes through a shared
## AudioEffectPitchShift bus per semitone value, created on first use and
## routed into In Level SFX. Speed alone shifts pitch too (FMOD's FFT time
## stretch does not); that residual matches Edit Song's.
func _pitch_bus(semitones: int) -> StringName:
	if semitones == 0:
		return LEVEL_SFX_BUS
	if _pitch_buses.has(semitones):
		return _pitch_buses[semitones]
	var bus_name := StringName("Level SFX Pitch %d" % semitones)
	var index := AudioServer.bus_count
	AudioServer.add_bus(index)
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, LEVEL_SFX_BUS)
	var shift := AudioEffectPitchShift.new()
	shift.pitch_scale = semitone_multiplier(float(semitones))
	AudioServer.add_bus_effect(index, shift)
	_pitch_buses[semitones] = bus_name
	return bus_name


## Starts a level SFX. [param p] keys: id, volume, speed, pitch, start_ms,
## end_ms, fade_in_ms, fade_out_ms, loop, unique_id (0 = not unique),
## override, sfx_group, group_id, ignore_volume_test.
func trigger_sfx(p: Dictionary) -> void:
	var sfx_id: int = int(p.get("id", 0))
	if sfx_id <= 0:
		return
	var volume: float = float(p.get("volume", 1.0))
	if volume <= 0.0 and not bool(p.get("ignore_volume_test", false)):
		return
	var unique_id: int = int(p.get("unique_id", 0))
	if unique_id != 0:
		for voice: SfxVoice in _voices:
			if voice.unique_id == unique_id and not voice.stopping:
				if not bool(p.get("override", false)):
					return
				_end_voice(voice)
	var path := Constants.SFX_DIR + "sfx_%d.ogg" % sfx_id
	var stream: AudioStream = _stream_cache.get(path, null)
	if stream == null and FileAccess.file_exists(path):
		stream = get_sfx_stream(path)
	if stream == null:
		_download_then_trigger(sfx_id, p)
		return
	var voice := SfxVoice.new()
	voice.unique_id = unique_id
	voice.sfx_group = int(p.get("sfx_group", 0))
	voice.group_id = int(p.get("group_id", 0))
	voice.start_s = maxf(0.0, float(p.get("start_ms", 0)) / 1000.0)
	voice.end_s = maxf(0.0, float(p.get("end_ms", 0)) / 1000.0)
	voice.loop = bool(p.get("loop", false))
	voice.fade_in_s = maxf(0.0, float(p.get("fade_in_ms", 0)) / 1000.0)
	voice.fade_out_s = maxf(0.0, float(p.get("fade_out_ms", 0)) / 1000.0)
	voice.base_volume = volume
	voice.speed = semitone_multiplier(float(p.get("speed", 0.0)))
	voice.speed_to = voice.speed
	var sfx_player := AudioStreamPlayer.new()
	sfx_player.bus = _pitch_bus(clampi(int(p.get("pitch", 0)), -12, 12))
	sfx_player.stream = stream
	voice.player = sfx_player
	add_child(sfx_player)
	_apply_voice(voice)
	sfx_player.play(voice.start_s)
	_voices.append(voice)
	set_process(true)


func _download_then_trigger(sfx_id: int, p: Dictionary) -> void:
	if _downloading_ids.has(sfx_id):
		return
	await _download_sfx_async(sfx_id)
	if _stream_cache.has(Constants.SFX_DIR + "sfx_%d.ogg" % sfx_id):
		trigger_sfx(p)


## Edit SFX: targets by unique ID, SFX group or group ID ([param p] keys
## unique_id, sfx_group, group_id), then stop / stop_loop / volume / speed
## over duration. New calls replace running volume / speed transitions.
func edit_sfx(p: Dictionary) -> void:
	var unique_id: int = int(p.get("unique_id", 0))
	var sfx_group: int = int(p.get("sfx_group", 0))
	var group_id: int = int(p.get("group_id", 0))
	var duration: float = maxf(0.0, float(p.get("duration", 0.0)))
	for voice: SfxVoice in _voices.duplicate():
		var hit := (unique_id != 0 and voice.unique_id == unique_id) \
				or (sfx_group != 0 and voice.sfx_group == sfx_group) \
				or (group_id != 0 and voice.group_id == group_id)
		if not hit:
			continue
		if bool(p.get("stop", false)):
			_remove_voice(voice)
			continue
		if bool(p.get("stop_loop", false)):
			voice.loop = false
			voice.end_s = 0.0
		if bool(p.get("change_volume", false)):
			voice.volume_from = voice.volume_mult
			voice.volume_to = float(p.get("volume", 1.0)) / maxf(voice.base_volume, 0.0001)
			voice.volume_time = 0.0
			voice.volume_duration = duration
		if bool(p.get("change_speed", false)):
			voice.speed_from = voice.speed
			voice.speed_to = semitone_multiplier(float(p.get("speed", 0.0)))
			voice.speed_time = 0.0
			voice.speed_duration = duration


## Level restart / exit: every level SFX stops.
func reset_level_sfx() -> void:
	for voice: SfxVoice in _voices.duplicate():
		_remove_voice(voice)


func _end_voice(voice: SfxVoice) -> void:
	if voice.fade_out_s <= 0.0:
		_remove_voice(voice)
		return
	voice.stopping = true
	voice.stop_time = 0.0


func _remove_voice(voice: SfxVoice) -> void:
	if is_instance_valid(voice.player):
		voice.player.queue_free()
	_voices.erase(voice)


func _apply_voice(voice: SfxVoice) -> void:
	var gain := voice.base_volume * voice.volume_mult
	if voice.fade_in_s > 0.0 and voice.age_s < voice.fade_in_s:
		gain *= voice.age_s / voice.fade_in_s
	if voice.stopping:
		gain *= 1.0 - clampf(voice.stop_time / maxf(voice.fade_out_s, 0.0001), 0.0, 1.0)
	voice.player.volume_db = linear_to_db(clampf(gain, 0.0, 2.0))
	voice.player.pitch_scale = clampf(voice.speed, 0.01, 4.0)


func _process(delta: float) -> void:
	if _voices.is_empty():
		set_process(false)
		return
	for voice: SfxVoice in _voices.duplicate():
		if not is_instance_valid(voice.player):
			_voices.erase(voice)
			continue
		voice.age_s += delta
		if voice.volume_time < voice.volume_duration:
			voice.volume_time += delta
			voice.volume_mult = lerpf(voice.volume_from, voice.volume_to, clampf(voice.volume_time / voice.volume_duration, 0.0, 1.0))
		elif voice.volume_duration <= 0.0 or voice.volume_time >= voice.volume_duration:
			voice.volume_mult = voice.volume_to
		if voice.speed_time < voice.speed_duration:
			voice.speed_time += delta
			voice.speed = lerpf(voice.speed_from, voice.speed_to, clampf(voice.speed_time / voice.speed_duration, 0.0, 1.0))
		else:
			voice.speed = voice.speed_to
		if voice.stopping:
			voice.stop_time += delta
			if voice.stop_time >= voice.fade_out_s:
				_remove_voice(voice)
				continue
		var position := voice.player.get_playback_position()
		var length := voice.player.stream.get_length()
		var end := voice.end_s if voice.end_s > voice.start_s else length
		# Fades apply when the SFX starts or ends, not when it repeats.
		if not voice.loop and not voice.stopping and voice.fade_out_s > 0.0 and position >= end - voice.fade_out_s:
			voice.stopping = true
			voice.stop_time = maxf(0.0, voice.fade_out_s - (end - position))
		if position >= end or not voice.player.playing:
			if voice.loop:
				voice.player.play(voice.start_s)
			else:
				_remove_voice(voice)
				continue
		_apply_voice(voice)


func cancel_all_sfx() -> void:
	reset_level_sfx()
	for player: AudioStreamPlayer in players:
		player.queue_free()
	players.clear()
