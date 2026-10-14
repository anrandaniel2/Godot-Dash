class_name FramePacingPolicy
extends RefCounted
## A rendering cap is independent of VSync and the fixed physics tick rate.
## Older installs saved the detected refresh rate as a software cap, so merely
## disabling VSync could never exceed it. Zero now consistently means unlimited.

const VERSION: int = 1


static func load_cap(config: ConfigFile, refresh_rate: float) -> int:
	var cap: int = maxi(0, int(config.get_value("Graphics", "max_fps", 0)))
	if int(config.get_value("Graphics", "frame_pacing_version", 0)) < VERSION:
		var refresh: int = maxi(0, roundi(refresh_rate))
		# There was no marker distinguishing an automatic cap from a custom cap
		# equal to the old default. Clear those defaults once; other caps survive.
		# After migration even an explicit 60/refresh-rate cap is preserved.
		if cap == 60 or (refresh > 0 and cap == refresh):
			cap = 0
		config.set_value("Graphics", "max_fps", cap)
		config.set_value("Graphics", "frame_pacing_version", VERSION)
	return cap


## Godot 4.7.2 Windows gives normal fullscreen a 2-pixel overscan. Its
## window_set_mode only recomputes monitor bounds when entering fullscreen
## from a non-fullscreen mode, not when changing between fullscreen variants.
## Re-enter on an explicit variant change; never silently change a saved mode.
static func window_mode_steps(current: int, requested: int, is_windows: bool) -> PackedInt32Array:
	if current == requested:
		return PackedInt32Array()
	var fullscreen: PackedInt32Array = PackedInt32Array(
		[
			DisplayServer.WINDOW_MODE_FULLSCREEN,
			DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
		]
	)
	if is_windows and fullscreen.has(current) and fullscreen.has(requested):
		return PackedInt32Array([DisplayServer.WINDOW_MODE_WINDOWED, requested])
	return PackedInt32Array([requested])
