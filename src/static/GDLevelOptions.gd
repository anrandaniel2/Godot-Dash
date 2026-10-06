class_name GDLevelOptions
## Options trigger (2899) state, shared by the native OPTIONS arm and the
## GameplayTriggerComponent twin through Level.apply_gd_options. Keys from
## gmdkit prop_table.csv, values gmdkit Option: -1 disable, 0 unchanged,
## 1 enable. Behaviour per UHDanke/gd_docs docs/triggers/misc/options.md.

static var hide_ground: bool = false
static var hide_middleground: bool = false
static var hide_players: Array[bool] = [false, false]
static var controls_disabled: Array[bool] = [false, false]
static var no_death_sfx: bool = false
static var audio_on_death: bool = false


static func reset() -> void:
	hide_ground = false
	hide_middleground = false
	hide_players = [false, false]
	controls_disabled = [false, false]
	no_death_sfx = false
	audio_on_death = false
	_refresh()


static func _option(options: Dictionary, key: String, current: bool) -> bool:
	match int(options.get(key, "0")):
		1:
			return true
		-1:
			return false
	return current


static func apply(options: Dictionary) -> void:
	hide_ground = _option(options, "161", hide_ground)
	hide_middleground = _option(options, "195", hide_middleground)
	hide_players[0] = _option(options, "162", hide_players[0])
	hide_players[1] = _option(options, "163", hide_players[1])
	controls_disabled[0] = _option(options, "165", controls_disabled[0])
	controls_disabled[1] = _option(options, "199", controls_disabled[1])
	no_death_sfx = _option(options, "576", no_death_sfx)
	audio_on_death = _option(options, "575", audio_on_death)
	_refresh()


## Touch triggers ignore this block (gd_docs touch.md).
static func are_controls_disabled(slot: int) -> bool:
	return slot >= 1 and slot <= 2 and controls_disabled[slot - 1]


static func _refresh() -> void:
	if is_instance_valid(LevelManager.ground_down):
		LevelManager.ground_down.visible = not hide_ground
	if is_instance_valid(LevelManager.ground_up):
		LevelManager.ground_up.visible = not hide_ground
	if is_instance_valid(LevelManager.player):
		LevelManager.player.set_gd_hidden(hide_players[0])
	for dual: Player in LevelManager.player_duals:
		if is_instance_valid(dual):
			dual.set_gd_hidden(hide_players[1])
