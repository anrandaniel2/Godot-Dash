extends Node

var players: Array[AudioStreamPlayer] = []
var _stream_cache: Dictionary = {}
var _downloading_ids: Dictionary = {}


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


func cancel_all_sfx() -> void:
	for player: AudioStreamPlayer in players:
		player.queue_free()
	players.clear()
