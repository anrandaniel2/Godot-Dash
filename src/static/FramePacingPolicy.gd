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
