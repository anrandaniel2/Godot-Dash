class_name DisplayPacingWatcher
extends Node
## A window can move between monitors without resizing or reopening Settings.
## Follow its current display, including refresh/topology changes. Windows
## still owns Duplicate-mode timing; never substitute another panel's Hz or
## change the user's Windows display mode, VSync choice or explicit FPS cap.

signal presentation_changed

const POLL_SECONDS: float = 0.5
var _state: DisplayPacingState = DisplayPacingState.new()


func _ready() -> void:
	if not OS.has_feature("windows") or DisplayServer.get_name() == "headless":
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_poll()
	var timer: Timer = Timer.new()
	timer.wait_time = POLL_SECONDS
	timer.ignore_time_scale = true
	timer.timeout.connect(_poll)
	add_child(timer)
	timer.start()


func _poll() -> void:
	if _state.observe(_snapshot()):
		# One refresh after the new display state settles, not every frame.
		presentation_changed.emit()


static func _snapshot() -> PackedInt64Array:
	var count: int = DisplayServer.get_screen_count()
	var screen: int = DisplayServer.window_get_current_screen()
	if screen < 0 or screen >= count:
		return PackedInt64Array()
	var position: Vector2i = DisplayServer.screen_get_position(screen)
	var size: Vector2i = DisplayServer.screen_get_size(screen)
	var refresh: float = DisplayServer.screen_get_refresh_rate(screen)
	# Integer milli-Hz suppress insignificant floating-point reporting noise.
	return PackedInt64Array(
		[
			screen,
			count,
			roundi(refresh * 1000.0),
			position.x,
			position.y,
			size.x,
			size.y,
		]
	)
