extends Node
## Plays a real Geometry Dash level in the real GameScene and logs what the
## runtime does, so trigger and colour behaviour can be compared with the level
## data (tools/gd_level_scan.py). Run by .github/workflows/level-probe.yml.
##
## The level comes from GDASH_PROBE_LEVEL (.gmd, .gmd2 or raw level string).
## The player runs in fly mode with noclip at a constant speed along its start
## height, so positional triggers fire as they would on a run, but deaths and
## player physics do not interfere. Grep "PROBE".
##
## GDASH_PROBE_GROUPS: comma list of GD group ids to sample (default none).
## GDASH_PROBE_CHANNELS: colour channels logged per sample, GDScript resolver
## next to the native runtime colour.
## GDASH_PROBE_DENSE_FROM: GD x after which samples are taken every 60 units.
## GDASH_PROBE_START_X/START_Y/MODE/END_X: real-physics run (portals, bands,
## the real camera) from that GD point in that Player.Gamemode, no input,
## deaths off, sampling the camera every 30 units until END_X ("CAM" lines).

const _LEVEL_PATH := "user://level_probe.gdlvl"
const _CELL_PER_GD: float = 128.0 / 30.0
const _RUN_SPEED_PX: float = 1329.41
const _SAMPLE_EVERY_GD: float = 600.0

var _last_state: String = ""
const _DENSE_EVERY_GD: float = 60.0
const _CHANNELS_EVERY_GD: float = 3000.0

var _groups: PackedStringArray = PackedStringArray()
var _channels: PackedStringArray = PackedStringArray()
var _dense_from_gd: float = INF
var _next_sample_gd: float = -INF
var _next_channels_gd: float = 3000.0
var _end_gd: float = 0.0
var _running: bool = false
var _player_y: float = 0.0
var _elapsed: float = 0.0
var _start: Vector2 = Vector2.INF
var _start_mode: int = 0
var _stop_gd: float = INF
var _placed: bool = false
var _macro: Replay = null


func _ready() -> void:
	if _running:
		return
	var path := OS.get_environment("GDASH_PROBE_LEVEL")
	var document: GMD.Document = GMD.read_any_file(path)
	if document == null or document.level_string.is_empty():
		print("PROBE error: could not read %s" % path)
		get_tree().quit(1)
		return
	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(document.level_string, "Probe", report)
	print("PROBE import %s" % report.summary())
	for line: String in report.summary().split("\n"):
		if not line.strip_edges().is_empty():
			print("PROBE report %s" % line)
	if LevelOperationsHandler.write_level_and_meta(_LEVEL_PATH, level_data) != OK:
		print("PROBE error: could not save the imported level")
		get_tree().quit(1)
		return
	for group: String in OS.get_environment("GDASH_PROBE_GROUPS").split(",", false):
		_groups.append(group.strip_edges())
	for channel: String in OS.get_environment("GDASH_PROBE_CHANNELS").split(",", false):
		_channels.append(channel.strip_edges())
	var dense := OS.get_environment("GDASH_PROBE_DENSE_FROM")
	if dense.is_valid_float():
		_dense_from_gd = dense.to_float()
	var start_x := OS.get_environment("GDASH_PROBE_START_X")
	if start_x.is_valid_float():
		_start = Vector2(start_x.to_float(), OS.get_environment("GDASH_PROBE_START_Y").to_float())
		_start_mode = OS.get_environment("GDASH_PROBE_MODE").to_int()
		_stop_gd = OS.get_environment("GDASH_PROBE_END_X").to_float()
	var macro_path := OS.get_environment("GDASH_PROBE_MACRO")
	if not macro_path.is_empty():
		var loaded: Dictionary = GDRFormat.load(macro_path)
		print("PROBE macro %s ok=%s %s" % [macro_path, str(loaded.ok), str(loaded.get("error", ""))])
		if loaded.ok:
			_macro = loaded.replay
			print("PROBE macro ticks=%d level=%s" % [_macro.data.size(), _macro.level_name])
			_start = Vector2(0.0, 0.0)
	Config.fly_mode = not _start.is_finite()
	Config.noclip = true
	Config.paced_level_open = false
	LevelManager.current_level_path = _LEVEL_PATH
	# The scene change frees this node's scene; keep the probe alive on root.
	var runner := Node.new()
	runner.name = "LevelProbeRunner"
	runner.set_script(get_script())
	runner.set(&"_groups", _groups)
	runner.set(&"_channels", _channels)
	runner.set(&"_dense_from_gd", _dense_from_gd)
	runner.set(&"_macro", _macro)
	runner.set(&"_start", _start)
	runner.set(&"_start_mode", _start_mode)
	runner.set(&"_stop_gd", _stop_gd)
	runner.set(&"_running", true)
	get_tree().root.add_child.call_deferred(runner)
	get_tree().change_scene_to_file.call_deferred("res://scenes/GameScene.tscn")


func _enter_tree() -> void:
	if _running:
		process_physics_priority = 1000


func _physics_process(delta: float) -> void:
	if not _running:
		return
	var player: Player = LevelManager.player
	var level: Level = LevelManager.current_level
	if _macro != null and player != null and not player.in_replay:
		player.replay = _macro
		player.in_replay = true
		player.replay_physics_tick = 0
		_placed = true
	if player == null or level == null or not LevelManager.level_playing:
		return
	if _end_gd <= 0.0:
		_end_gd = level.gd_level_end_x if level.gd_level_end_x > 0.0 else 1.0e9
		_player_y = player.global_position.y
		print("PROBE start player=%s gd_end=%.0f" % [str(player.global_position), level.gd_level_end_x])
		_log_channels("start")
	_elapsed += delta
	if _start.is_finite():
		_real_run(player, level)
		return
	player.global_position = Vector2(player.global_position.x + _RUN_SPEED_PX * delta, _player_y)
	var gd_x: float = _gd_x(player)
	var state: String = "speed=%.2f mode=%d vis=%s" % [player.speed_multiplier, player.internal_gamemode, str(player.visible)]
	if state != _last_state:
		_last_state = state
		print("PROBE EV tick=%d x=%.1f y=%.1f %s" % [player.replay_physics_tick, gd_x,
				-level.to_local(player.global_position).y / _CELL_PER_GD, state])
	if gd_x >= _next_sample_gd:
		_sample(gd_x)
		_next_sample_gd = gd_x + (_DENSE_EVERY_GD if gd_x >= _dense_from_gd else _SAMPLE_EVERY_GD)
	if gd_x >= _next_channels_gd:
		_log_channels("x%.0f" % gd_x)
		_next_channels_gd = gd_x + _CHANNELS_EVERY_GD
	if _elapsed > 900.0 or gd_x > _end_gd + 300.0 or LevelManager.player.in_end_level_animation:
		print("PROBE finished x=%.0f t=%.1f" % [gd_x, _elapsed])
		_log_channels("end")
		get_tree().quit(0)


func _real_run(player: Player, level: Level) -> void:
	if not _placed:
		_placed = true
		player.global_position = level.to_global(Vector2(_start.x * _CELL_PER_GD, -_start.y * _CELL_PER_GD))
		player.internal_gamemode = _start_mode as Player.Gamemode
		player.displayed_gamemode = _start_mode as Player.Gamemode
		LevelManager.player_camera.snap_view()
		print("PROBE CAM start at %s mode %d" % [str(_start), _start_mode])
		return
	var gd_x: float = _gd_x(player)
	if gd_x >= _next_sample_gd:
		var dense: bool = _macro == null or (gd_x > 9000.0 and gd_x < 12000.0)
		_next_sample_gd = gd_x + (30.0 if dense else 600.0)
		var camera: PlayerCamera = LevelManager.player_camera
		var centre: Vector2 = level.to_local(camera.get_screen_center_position()) / _CELL_PER_GD
		var band: Vector2 = level.to_local(GroundData.center) / _CELL_PER_GD
		var player_gd: Vector2 = level.to_local(player.global_position) / _CELL_PER_GD
		print("PROBE CAM tick=%d x=%.0f py=%.0f mode=%d vis=%s free=%s portal_free=%s cam=(%.0f,%.0f) band_c=%.0f half=%.0f zoom=%.2f static=%s dead=%s" % [
			player.replay_physics_tick, gd_x, -player_gd.y, player.internal_gamemode, str(player.visible), str(camera.freefly),
			str(camera.portal_freefly), centre.x, -centre.y, -band.y, GroundData.distance / _CELL_PER_GD,
			camera.zoom.x, str(camera.static_factor), str(player.dead)])
	if gd_x >= _stop_gd or _elapsed > 600.0 or player.in_end_level_animation:
		print("PROBE CAM finished x=%.0f t=%.1f" % [gd_x, _elapsed])
		get_tree().quit(0)


func _gd_x(player: Player) -> float:
	var level: Level = LevelManager.current_level
	return level.to_local(player.global_position).x / _CELL_PER_GD


func _sample(gd_x: float) -> void:
	var player: Player = LevelManager.player
	var camera: Camera2D = LevelManager.player_camera
	var parts: PackedStringArray = PackedStringArray()
	parts.append("x=%.0f t=%.2f" % [gd_x, _elapsed])
	parts.append("player_vis=%s" % str(player.visible))
	if camera != null:
		parts.append("cam=(%.0f,%.0f) zoom=%.2f" % [camera.get_screen_center_position().x, camera.get_screen_center_position().y, camera.zoom.x])
	var level: Level = LevelManager.current_level
	parts.append("bg=%s" % _hex(level.background_color))
	for group: String in _groups:
		parts.append("g%s{%s}" % [group, _group_state(group)])
	for channel: String in _channels:
		parts.append("c%s{%s}" % [channel, _channel_state(channel)])
	print("PROBE " + " ".join(parts))


func _channel_state(channel: String) -> String:
	var gd := "none"
	var group := Constants.COLOR_CHANNEL_GROUP_PREFIX + channel
	for data: ColorChannelData in LevelManager.current_level.color_channels:
		if data.associated_group == group:
			gd = "%s/%.2f%s" % [_hex(ColorChannelWatcher.resolve_channel_color(data)), ColorChannelWatcher.resolve_channel_alpha(data), "c%d" % data.copied_channel_id if data.copied_channel_id > 0 else ""]
			break
	var bridge: NativeTriggerBridge = NativeTriggerBridge.current
	var native := _hex(bridge.live_channel_color(int(channel))) if bridge != null else "nobridge"
	return "gd=%s nat=%s" % [gd, native]


func _group_state(group: String) -> String:
	var nodes: Array[Node] = get_tree().get_nodes_in_group(Constants.GROUP_PREFIX + group)
	var visible := 0
	var first := ""
	for node: Node in nodes:
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			visible += 1
		if first.is_empty() and node is Node2D:
			var item := node as Node2D
			first = "%s@(%.0f,%.0f) a=%.2f" % [item.get_class() if item.get_script() == null else str(item.get_script().get_global_name()), item.global_position.x, item.global_position.y, item.modulate.a]
	return "n=%d vis=%d %s" % [nodes.size(), visible, first]


func _log_channels(tag: String) -> void:
	var level: Level = LevelManager.current_level
	var white: PackedStringArray = PackedStringArray()
	var listed: PackedStringArray = PackedStringArray()
	for channel: ColorChannelData in level.color_channels:
		var id := channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
		var color: Color = ColorChannelWatcher.resolve_channel_color(channel)
		var alpha: float = ColorChannelWatcher.resolve_channel_alpha(channel)
		listed.append("%s=%s/%.2f%s" % [id, _hex(color), alpha, "c" if channel.copy or channel.copied_channel_id > 0 else ""])
		if color.r > 0.95 and color.g > 0.95 and color.b > 0.95 and alpha > 0.05:
			white.append(id)
	print("PROBE channels %s white=[%s]" % [tag, ",".join(white)])
	print("PROBE channels %s all %s" % [tag, " ".join(listed)])


func _hex(color: Color) -> String:
	return color.to_html(false)
