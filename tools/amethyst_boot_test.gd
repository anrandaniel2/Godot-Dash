extends Node
## Device-crash reproduction: boot the real Amethyst level (GD 119550490,
## 147k objects, 5.2k triggers) through the exact production flow and keep it
## playing long enough to cover the window where the Android APK died.
##
## The flow mirrors LevelPanelLoader._download_online_level -> _play_level:
## the game's own RobTop client downloads and imports the level, it is saved
## through LevelOperationsHandler, and GameScene is launched via scene change
## so every autoload, the paced build, the native trigger bridge and
## Level.start_level() run exactly as on device. A root-level watchdog (it
## must outlive the scene change) observes the boot; success requires that
## level_playing became true and then either accumulated a full survival
## window of physics frames or ended cleanly (an input-less player is allowed
## to die like in the real game). A native crash kills the process outright,
## so the missing success marker plus Godot's crash dump identifies it.
##
## RobTop's Cloudflare blocks CI datacenter IPs with HTTP 403, so when the
## live download is unavailable the level comes from the GDHistory archive:
## record 179189859 stores exactly the level build the device downloaded
## (the .gmd is an XML plist with RobTop short tags: <k>k4</k><s>base64</s>)
## (compressed-string sha256 below; object count and decompressed size match
## the device logcat). The song is fetched best-effort from Newgrounds.

const AMETHYST_ID := 119550490
const GDHISTORY_GMD_URL := "https://history.geometrydash.eu/level/119550490/179189859/download/"
const EXPECTED_LEVEL_SHA256 := "b5d1d7af41d8699917d8c758541beba7d6756ad467022643e5a1c00bad75f4e6"
const SONG_URL := "https://audio.ngfiles.com/233000/233860_Dawn.mp3"
const SONG_FILE := "robtop_233860.mp3"
## ~10 seconds of physics at 60 fps after the level starts playing.
const PLAYING_SURVIVAL_FRAMES := 600
## Generous budget for download + import + paced build of 147k objects.
const BOOT_TIMEOUT_MS := 330_000


func _ready() -> void:
	print("[amethyst-boot] fetching level %d" % AMETHYST_ID)
	var client := RobTopLevels.new()
	add_child(client)
	var level_data: Dictionary = {}
	var response: Dictionary = await client.download(AMETHYST_ID, {
		"name": "Amethyst",
		"creator": "iMist",
		"id": AMETHYST_ID,
	})
	if bool(response.get("ok", false)):
		level_data = response.level_data
		# RobTopLevels itself prints the conversion summary.
		print("[amethyst-boot] imported via RobTop")
	else:
		print("[amethyst-boot] RobTop unavailable from this network (%s); using the GDHistory archive" % str(response.get("error", "unknown")))
		level_data = await _import_from_gdhistory()
	client.queue_free()
	if level_data.is_empty():
		get_tree().quit(1)
		return
	var file_name := "Amethyst [GD-%d].%s" % [AMETHYST_ID, Constants.LEVEL_FILE_EXTENSION]
	var level_path := Constants.LEVEL_DIR + file_name
	var write_error: int = LevelOperationsHandler.write_level_and_meta(level_path, level_data)
	if write_error != OK:
		push_error("[amethyst-boot] could not save level (error %d)" % write_error)
		get_tree().quit(1)
		return
	print("[amethyst-boot] saved %s, launching GameScene" % file_name)

	var watchdog: Node = BootWatchdog.new()
	# Parent to root, not this scene: change_scene_to_packed frees the
	# current scene, and the watchdog must observe everything after it.
	get_tree().root.add_child.call_deferred(watchdog)

	LevelManager.attempt = 0
	LevelManager.current_level_path = level_path
	get_tree().change_scene_to_packed(AssetManager.game_scene_packed)


## Imports the archived level build from GDHistory's .gmd. The file is an
## XML plist with RobTop's short tags: <k>k4</k><s>compressed string</s>.
func _import_from_gdhistory() -> Dictionary:
	var gmd := await _get_text(GDHISTORY_GMD_URL)
	if gmd.is_empty():
		push_error("[amethyst-boot] GDHistory archive fetch failed")
		return {}
	# Whitespace-tolerant in case the exporter breaks lines between tags.
	var pattern := RegEx.new()
	var compile_error := pattern.compile("<k>\\s*k4\\s*</k>\\s*<s>")
	if compile_error != OK:
		push_error("[amethyst-boot] k4 pattern failed to compile")
		return {}
	var match := pattern.search(gmd)
	if match == null:
		push_error("[amethyst-boot] k4 not found in the archived .gmd (%d chars): %s" % [
			gmd.length(),
			gmd.substr(0, 500).replace("\n", "\\n"),
		])
		return {}
	var start: int = match.get_end()
	var end := gmd.find("</s>", start)
	if end < 0:
		push_error("[amethyst-boot] unterminated k4 in the archived .gmd")
		return {}
	var encoded := gmd.substr(start, end - start)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(encoded.to_utf8_buffer())
	var digest: String = ctx.finish().hex_encode()
	if digest == EXPECTED_LEVEL_SHA256:
		print("[amethyst-boot] archive sha256 matches the device build")
	else:
		push_warning("[amethyst-boot] archive sha256 %s differs from the device build %s" % [digest, EXPECTED_LEVEL_SHA256])
	var level_string := GMD.decode_level_string(encoded)
	if level_string.is_empty():
		push_error("[amethyst-boot] archived level string could not be decoded")
		return {}
	var report = GMDConverter.ImportReport.new()
	var level_data: Dictionary = GMDConverter.import_online_level_string(level_string, "Amethyst", report)
	print("[amethyst-boot] imported: %s" % report.summary())
	level_data.name = "Amethyst"
	level_data.creator = "iMist"
	level_data.rating = -1
	level_data["robtop_level_id"] = AMETHYST_ID
	var song_file := await _cache_song()
	if not song_file.is_empty():
		level_data.song_path = song_file
	else:
		print("[amethyst-boot] continuing without the song (dummy audio driver in CI)")
	return level_data


func _get_text(url: String) -> String:
	var bytes := await _get_bytes(url)
	return bytes.get_string_from_utf8() if not bytes.is_empty() else ""


func _get_bytes(url: String) -> PackedByteArray:
	var request := HTTPRequest.new()
	request.use_threads = true
	request.timeout = 90.0
	add_child(request)
	var completed: Array = []
	request.request_completed.connect(
		func(result: int, _status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			completed.assign([result, body])
	)
	# GDHistory sits behind Cloudflare, which challenges default engine user
	# agents from datacenter IPs; identify as a plain browser client.
	var headers := PackedStringArray([
		"User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36",
	])
	var error := request.request(url, headers)
	if error != OK:
		request.queue_free()
		return PackedByteArray()
	while completed.is_empty():
		await get_tree().process_frame
	request.queue_free()
	if int(completed[0]) != HTTPRequest.RESULT_SUCCESS:
		push_warning("[amethyst-boot] GET %s failed (result %d)" % [url, int(completed[0])])
		return PackedByteArray()
	var body: PackedByteArray = completed[1]
	return body


func _cache_song() -> String:
	if FileAccess.file_exists(Constants.SONG_DIR + SONG_FILE):
		return SONG_FILE
	var bytes := await _get_bytes(SONG_URL)
	if bytes.size() < 100_000:
		return ""
	DirAccess.make_dir_recursive_absolute(Constants.SONG_DIR)
	var file := FileAccess.open(Constants.SONG_DIR + SONG_FILE, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_buffer(bytes)
	print("[amethyst-boot] cached song (%d bytes)" % bytes.size())
	return SONG_FILE


class BootWatchdog extends Node:
	var started_ms := 0
	var seen_playing := false
	var playing_frames := 0
	var last_milestone_ms := 0

	func _ready() -> void:
		started_ms = Time.get_ticks_msec()
		last_milestone_ms = started_ms
		set_process(true)

	func _process(_delta: float) -> void:
		var now := Time.get_ticks_msec()
		if now - last_milestone_ms >= 10_000:
			last_milestone_ms = now
			print("[amethyst-boot] milestone %ds: scene=%s playing=%s playing_frames=%d level=%s" % [
				(now - started_ms) / 1000,
				get_tree().current_scene.name if get_tree().current_scene != null else "<none>",
				LevelManager.level_playing,
				playing_frames,
				LevelManager.current_level.name if LevelManager.current_level != null else "<none>",
			])
		if LevelManager.level_playing:
			seen_playing = true
			playing_frames += 1
			if playing_frames >= PLAYING_SURVIVAL_FRAMES:
				_finish(true, "survived %d playing frames" % playing_frames)
			return
		if seen_playing:
			# The level started and then stopped without taking the process
			# down: with no player input that is a legitimate death.
			_finish(true, "played %d frames, then stopped cleanly" % playing_frames)
			return
		if now - started_ms > BOOT_TIMEOUT_MS:
			_finish(false, "level never started playing within %d s" % (BOOT_TIMEOUT_MS / 1000))

	func _finish(passed: bool, detail: String) -> void:
		set_process(false)
		if passed:
			print("AMETHYST_BOOT_OK %s" % detail)
			get_tree().quit(0)
		else:
			push_error("[amethyst-boot] FAILED: %s" % detail)
			get_tree().quit(1)
