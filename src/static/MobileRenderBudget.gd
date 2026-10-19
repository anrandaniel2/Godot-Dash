class_name MobileRenderBudget
extends RefCounted
## Sustained frame budget for phones and tablets.
##
## Two shipped defaults are desktop defaults that a phone pays for every
## second of play:
##
## - [code]Graphics/max_fps[/code] is 0, meaning "no software cap". VSync still
##   paces presentation, so a 90 Hz or 120 Hz panel renders - and rebuilds the
##   decoration command streams for - 90 or 120 frames per second. Physics is a
##   fixed 240 Hz and does not want that rate; every extra frame costs a full
##   canvas submission plus full-screen fill, and the extra heat is what makes
##   the GPU clock down and the frame time become irregular minutes into a level.
## - The 2D canvas is an HDR render target with the glow post-process enabled
##   ([code]project.godot[/code] [code]viewport/hdr_2d[/code],
##   [code]scenes/GameScene.tscn[/code] [code]Environment.glow_enabled[/code]).
##   That is a store/reload of the whole frame plus the glow mip chain: fine on
##   a desktop GPU with hundreds of GB/s, expensive on a tile-based mobile GPU
##   that would otherwise keep the frame in tile memory. Halving the frame count
##   halves that cost without changing a single pixel of any frame.
##
## So a fresh mobile install starts at [constant MOBILE_MAX_FPS]. The cap is
## applied **once**, and only to the value that means "unlimited": a saved
## 30/45/60/120 cap survives, and so does any cap the player chooses afterwards
## in Settings -> Graphics. Physics ticks, time scale, replay timing and the
## renderer are untouched - this only stops asking for frames no one can see.
##
## Desktop and web never enter this path. Web already paces itself to the
## display and keeps [code]max_fps = 0[/code] (see the version 3 migration in
## [Config]); desktop GPUs are not the target of this budget.

## Bump to re-apply the budget to installs that already ran this migration.
const VERSION: int = 1

## Frames per second a mobile device should sustain. 60 matches the panel
## refresh of most phones, half of what 120 Hz panels were costing, and is
## double the 30 FPS the game already treats as playable.
const MOBILE_MAX_FPS: int = 60


## Applies the budget to [param config] for this launch.
##
## Returns the frame cap the caller must adopt, or -1 when nothing changed.
## The caller owns saving: this function only edits the in-memory
## [ConfigFile], so an unrelated save failure cannot half-apply the migration.
static func apply(config: ConfigFile, is_mobile: bool) -> int:
	if not is_mobile:
		return -1
	if int(config.get_value("Performance", "mobile_budget_version", 0)) >= VERSION:
		return -1
	var cap: int = maxi(0, int(config.get_value("Graphics", "max_fps", 0)))
	# Only rewrite "unlimited". Any explicit cap - including one equal to the
	# old default - is a choice this migration must not overwrite.
	if cap == 0:
		cap = MOBILE_MAX_FPS
		config.set_value("Graphics", "max_fps", cap)
	config.set_value("Performance", "mobile_budget_version", VERSION)
	return cap
