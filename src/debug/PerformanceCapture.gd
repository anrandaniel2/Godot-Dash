class_name FrameTimeCapture
extends Node
## Opt-in diagnostics only: normal launches have no process callback or buffers.
## Records real gameplay/editor frames without changing visibility, physics,
## vsync or settings. Rendering timers add overhead; compare like-for-like runs.

const FRAME_COUNT: int = 1800
const WARMUP_FRAMES: int = 120
const STRIDE: int = 13

var _samples: PackedFloat64Array = PackedFloat64Array()
var _count: int = 0
var _warmup: int = 0
var _previous_us: int = 0
var _viewport: RID
var _output: String = ""
var _enabled: bool = false


func _ready() -> void:
	set_process(false)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--native-smoke"):
		_native_smoke()
		return
	if not args.has("--perf-capture"):
		return
	_output = "user://performance-%d.csv" % int(Time.get_unix_time_from_system())
	for arg: String in args:
		if arg.begins_with("--perf-output="):
			_output = arg.trim_prefix("--perf-output=")
	_samples.resize(FRAME_COUNT * STRIDE)
	_viewport = get_viewport().get_viewport_rid()
	RenderTimingRequests.set_requested(_viewport, self, true)
	_enabled = true
	print(
		(
			"PERF_CAPTURE armed renderer=%s native=%s output=%s"
			% [
				RenderingServer.get_current_rendering_method(),
				NativeCore.available(),
				_output,
			]
		)
	)
	print(
		"PERF_CAPTURE static memory may be zero in release; use the Windows memory sidecar for process memory."
	)
	set_process(true)


func _process(_delta: float) -> void:
	var started: int = Time.get_ticks_usec()
	var level: Level = LevelManager.current_level
	if level == null or not (LevelManager.level_playing or Editor.in_editor):
		_previous_us = 0
		return
	if _warmup < WARMUP_FRAMES or _previous_us == 0:
		_warmup += 1
		_previous_us = started
		return
	var offset: int = _count * STRIDE
	_samples[offset] = started / 1000.0
	_samples[offset + 1] = (started - _previous_us) / 1000.0
	_samples[offset + 2] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_samples[offset + 3] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_samples[offset + 4] = RenderingServer.viewport_get_measured_render_time_cpu(_viewport)
	_samples[offset + 5] = RenderingServer.viewport_get_measured_render_time_gpu(_viewport)
	_samples[offset + 6] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_samples[offset + 7] = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	_samples[offset + 8] = OS.get_static_memory_usage()
	_samples[offset + 9] = OS.get_static_memory_peak_usage()
	_samples[offset + 10] = level.get_instance_id()
	_samples[offset + 11] = 1.0 if Editor.in_editor else 0.0
	_samples[offset + 12] = Time.get_ticks_usec() - started
	_previous_us = started
	_count += 1
	if _count == FRAME_COUNT:
		_finish()


func _exit_tree() -> void:
	if _enabled:
		_finish()


func _finish() -> void:
	var write_started: int = Time.get_ticks_usec()
	set_process(false)
	_enabled = false
	RenderTimingRequests.set_requested(_viewport, self, false)
	var file: FileAccess = FileAccess.open(_output, FileAccess.WRITE)
	if file == null:
		push_error(
			"PERF_CAPTURE cannot write %s (error %d)" % [_output, FileAccess.get_open_error()]
		)
		return
	(
		file
		. store_csv_line(
			PackedStringArray(
				[
					"engine_ms",
					"frame_wall_ms",
					"process_ms",
					"physics_ms",
					"render_cpu_ms",
					"render_gpu_ms",
					"draw_calls",
					"nodes",
					"static_bytes",
					"static_peak_bytes",
					"level_instance_id",
					"editor",
					"sampler_cpu_us",
				]
			)
		)
	)
	var frames: Array[float] = []
	var overhead: float = 0.0
	for frame: int in _count:
		var row: PackedStringArray = PackedStringArray()
		for column: int in STRIDE:
			row.append(str(_samples[frame * STRIDE + column]))
		file.store_csv_line(row)
		frames.append(_samples[frame * STRIDE + 1])
		overhead += _samples[frame * STRIDE + 12]
	file.close()
	frames.sort()
	if not frames.is_empty():
		print(
			(
				"PERF_CAPTURE frames=%d median_ms=%.3f p95_ms=%.3f max_ms=%.3f sampler_mean_us=%.3f"
				% [
					_count,
					frames[(_count - 1) / 2],
					frames[ceili(_count * 0.95) - 1],
					frames.back(),
					overhead / _count,
				]
			)
		)
	print("PERF_CAPTURE saved %s; CSV writing is outside the sampled frames." % _output)
	_samples = PackedFloat64Array()
	print(
		(
			"PERF_CAPTURE finalize_ms=%.3f (diagnostic file-write pause)"
			% ((Time.get_ticks_usec() - write_started) / 1000.0)
		)
	)


## Used by Windows CI on the exported EXE, not just on the editor executable.
## Headless checks DLL loading/settings only, not Forward+ GPU rendering.
func _native_smoke() -> void:
	var method: String = ProjectSettings.get_setting_with_override(
		"rendering/renderer/rendering_method"
	)
	var native: Object = NativeCore.backend()
	var ok: bool = native != null and method == "forward_plus" and OS.has_feature("windows")
	for required: StringName in [
		&"NativeLevelBuildJob",
		&"NativeDecorationRenderer",
		&"NativePackedDecorationBuilder",
		&"NativeTriggerRuntime",
		&"NativeColorChannelIndex",
	]:
		ok = ok and ClassDB.class_exists(required)
	if native != null:
		ok = ok and native.call(&"add", 2, 3) == 5
	ok = ok and Engine.max_fps == maxi(0, Config.max_fps)
	ok = ok and not DebugMenu.is_processing()
	ok = ok and not RenderTimingRequests.is_requested(get_viewport().get_viewport_rid())
	print(
		"WINDOWS_NATIVE_SMOKE result=%s configured_renderer=%s" % ["PASS" if ok else "FAIL", method]
	)
	get_tree().quit(0 if ok else 1)
