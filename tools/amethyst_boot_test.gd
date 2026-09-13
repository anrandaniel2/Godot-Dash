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

const AMETHYST_ID := 119550490
## ~10 seconds of physics at 60 fps after the level starts playing.
const PLAYING_SURVIVAL_FRAMES := 600
## Generous budget for download + import + paced build of 147k objects.
const BOOT_TIMEOUT_MS := 330_000


func _ready() -> void:
	print("[amethyst-boot] downloading level %d" % AMETHYST_ID)
	var client := RobTopLevels.new()
	add_child(client)
	var response: Dictionary = await client.download(AMETHYST_ID, {
		"name": "Amethyst",
		"creator": "iMist",
		"id": AMETHYST_ID,
	})
	client.queue_free()
	if not bool(response.get("ok", false)):
		push_error("[amethyst-boot] download failed: %s" % str(response.get("error", "unknown")))
		get_tree().quit(1)
		return
	var report: Dictionary = response.get("report", {})
	print("[amethyst-boot] imported: %s" % report.get("summary", "?"))
	var file_name := "Amethyst [GD-%d].%s" % [AMETHYST_ID, Constants.LEVEL_FILE_EXTENSION]
	var level_path := Constants.LEVEL_DIR + file_name
	var write_error: int = LevelOperationsHandler.write_level_and_meta(level_path, response.level_data)
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
