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
## GDASH_PROBE_DENSE_FROM: GD x after which samples are taken every 60 units.

const _LEVEL_PATH := "user://level_probe.gdlvl"
const _CELL_PER_GD: float = 128.0 / 30.0
const _RUN_SPEED_PX: float = 1329.41
const _SAMPLE_EVERY_GD: float = 600.0
const _DENSE_EVERY_GD: float = 60.0
const _CHANNELS_EVERY_GD: float = 3000.0

var _groups: PackedStringArray = PackedStringArray()
var _dense_from_gd: float = INF
var _next_sample_gd: float = -INF
var _next_channels_gd: float = 3000.0
var _end_gd: float = 0.0
var _running: bool = false
var _player_y: float = 0.0
var _elapsed: float = 0.0


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
	var dense := OS.get_environment("GDASH_PROBE_DENSE_FROM")
	if dense.is_valid_float():
		_dense_from_gd = dense.to_float()
	Config.fly_mode = true
	Config.noclip = true
	Config.paced_level_open = false
	LevelManager.current_level_path = _LEVEL_PATH
	# The scene change frees this node's scene; keep the probe alive on root.
	var runner := Node.new()
	runner.name = "LevelProbeRunner"
	runner.set_script(get_script())
	runner.set(&"_groups", _groups)
	runner.set(&"_dense_from_gd", _dense_from_gd)
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
	if player == null or level == null or not LevelManager.level_playing:
		return
	if _end_gd <= 0.0:
		_end_gd = level.gd_level_end_x if level.gd_level_end_x > 0.0 else 1.0e9
		_player_y = player.global_position.y
		print("PROBE start player=%s gd_end=%.0f" % [str(player.global_position), level.gd_level_end_x])
		_log_channels("start")
	_elapsed += delta
	player.global_position = Vector2(player.global_position.x + _RUN_SPEED_PX * delta, _player_y)
	var gd_x: float = _gd_x(player)
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
	print("PROBE " + " ".join(parts))


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
