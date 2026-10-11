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
var _revives: int = 0
var _macro: Replay = null
# GDASH_PROBE_NO_PLACE: keep the spawn exactly as the game places it (no probe
# placement), log the first ticks as PROBE TRAJ, and stop at the first death.
var _no_place: bool = false
const _TRAJ_TICKS: int = 1500


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
	_no_place = OS.get_environment("GDASH_PROBE_NO_PLACE") == "1"
	var macro_path := OS.get_environment("GDASH_PROBE_MACRO")
	if not macro_path.is_empty():
		var loaded: Dictionary = GDRFormat.load(macro_path)
		print("PROBE macro %s ok=%s %s" % [macro_path, str(loaded.ok), str(loaded.get("error", ""))])
		if loaded.ok:
			_macro = loaded.replay
			print("PROBE macro ticks=%d level=%s" % [_macro.data.size(), _macro.level_name])
			_start = Vector2(0.0, 0.0)
	Config.fly_mode = not _start.is_finite()
	# Fly mode keeps noclip (constant speed, no deaths). Real-physics runs use
	# normal rules so deaths, the max-Y kill and crushes count as they do in play.
	Config.noclip = not _start.is_finite()
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
	runner.set(&"_no_place", _no_place)
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


# One line every 6 physics ticks from the spawn: GD position, velocity, state.
# Stops at the first death so the killer is the last logged event.
var _jump_prev_tick: int = -1
var _jump_prev_x: float = 0.0
var _jump_prev_y: float = 0.0


func _trajectory(player: Player, level: Level) -> void:
	var tick: int = Engine.get_physics_frames()
	var gd_y: float = -level.to_local(player.global_position).y / _CELL_PER_GD
	if player.dead:
		print("PROBE TRAJ DEATH tick=%d x=%.2f y=%.2f" % [tick, _gd_x(player), gd_y])
		get_tree().quit(0)
		return
	# Jump detector: a one-tick X or Y change far beyond the cube's speed names
	# the body that moved it (slide colliders) and the state that was live.
	var gd_x: float = _gd_x(player)
	if _jump_prev_tick == tick - 1 and (absf(gd_x - _jump_prev_x) > 4.0 or absf(gd_y - _jump_prev_y) > 40.0):
		var colliders: Array[String] = []
		for i in range(player.get_slide_collision_count()):
			var collider := player.get_slide_collision(i).get_collider() as Node
			if collider == null:
				colliders.append("null")
			else:
				colliders.append("%s@%s" % [str(collider.name), str(collider.get_parent().name) if collider.get_parent() else "null"])
		print("PROBE JUMP tick=%d from=(%.2f,%.2f) to=(%.2f,%.2f) vel=%s speed_mult=%s s0=%s pending=%s slides=%s" % [
			tick, _jump_prev_x, _jump_prev_y, gd_x, gd_y, str(player.velocity),
			str(player.get("speed_multiplier")), str(player.speed_0_portal_control.name) if player.speed_0_portal_control else "null",
			str(player.get("gravity_portal_pending")), str(colliders),
		])
	_jump_prev_tick = tick
	_jump_prev_x = gd_x
	_jump_prev_y = gd_y
	if tick % 6 == 0 or tick < 30:
		print("PROBE TRAJ tick=%d x=%.2f y=%.2f vy=%.1f mode=%d" % [tick, _gd_x(player), gd_y, player.velocity.y, player.internal_gamemode])
	elif tick >= 80:
		print("PROBE TRAJ tick=%d x=%.2f y=%.2f vy=%.1f parent=%s" % [tick, _gd_x(player), gd_y, player.velocity.y, str(player.get_parent().name)])
	if tick >= _TRAJ_TICKS:
		print("PROBE TRAJ END tick=%d x=%.2f y=%.2f" % [tick, _gd_x(player), gd_y])
		get_tree().quit(0)

func _real_run(player: Player, level: Level) -> void:
	if Engine.get_physics_frames() < 40:
		print("PROBE FRAME %d pos=%s placed=%s dead=%s" % [Engine.get_physics_frames(), str(player.global_position), str(_placed), str(player.dead)])
	if _no_place:
		_trajectory(player, level)
		return
	# Positive control for the contact-kill re-check: on the spawn cell the cube
	# still overlaps Spike68825 (before the start teleport moves it).
	if Engine.get_physics_frames() == 13:
		var spike_root := level.find_child("Spike68825", true, false) as Node2D
		var spike := spike_root.find_child("Collision", false, false) as Node2D if spike_root != null else null
		if spike != null:
			var hitboxes: Array = [player.get_node("KillColliderRectangularHazard/KillColliderRectangularHazardHitbox"), player.get_node("KillColliderCircularHazard/KillColliderCircularHazardHitbox")]
			print("PROBE QUERY spike=%s overlaps=%s" % [str(spike.name), str(player._kill_collider_overlaps(hitboxes, spike))])
		else:
			print("PROBE QUERY spike=missing")
	if not _merge_logged:
		_merge_logged = true
		_log_packed_box(level)
		_log_solids_in_box(level)
		_log_teleports(level)
	# A death does not end the probe: revive the cube at the probe's start point and
	# keep going, so every killer along the way is logged (see [gdash-kill]).
	if player.dead and _revives < 200:
		_revives += 1
		print("PROBE REVIVE #%d after death at %s" % [_revives, str(player.global_position)])
		player.dead = false
		player.get_node("DeathAnimator").stop()
		player._icon.show()
		player.velocity = Vector2.ZERO
		player.internal_gamemode = _start_mode as Player.Gamemode
		player.displayed_gamemode = _start_mode as Player.Gamemode
		player.global_position = level.to_global(Vector2(_start.x * _CELL_PER_GD, -_start.y * _CELL_PER_GD))
		_placed = true
		return
	if not _placed:
		# The first physics frame fires every trigger left of the cube's x, so
		# the start portal (TeleportalIn1, x -29) always teleports the spawn to
		# its exit (y 1315) before the probe places the cube. Wait for that to
		# happen, as in real play, so the placement is not overridden by it.
		_settle_ticks += 1
		if _settle_ticks < 10:
			return
		_placed = true
		print("PROBE pre-place player=%s" % str(player.global_position))
		player.global_position = level.to_global(Vector2(_start.x * _CELL_PER_GD, -_start.y * _CELL_PER_GD))
		player.internal_gamemode = _start_mode as Player.Gamemode
		player.displayed_gamemode = _start_mode as Player.Gamemode
		LevelManager.player_camera.snap_view()
		print("PROBE CAM start at %s mode %d" % [str(_start), _start_mode])
		return
	var gd_x: float = _gd_x(player)
	# Where the group-25 blocks are: if the lock works they move with the cube.
	if gd_x >= 60.0 and gd_x <= 260.0:
		var tracked := get_tree().get_nodes_in_group(Constants.GROUP_PREFIX + "25")
		var bits := PackedStringArray()
		for member: Node in tracked:
			if member is Node2D:
				var where: Vector2 = level.to_local((member as Node2D).global_position) / _CELL_PER_GD
				bits.append("(%.1f,%.1f)" % [where.x, -where.y])
		print("PROBE G25 tick=%d x=%.1f members=%d %s" % [player.replay_physics_tick, gd_x, tracked.size(), " ".join(bits.slice(0, 6))])
	# Physical contacts of the cube in the sandwich window: what holds it up,
	# or whether it touches anything at all. One line per physics tick.
	if gd_x >= 60.0 and gd_x <= 260.0:
		print("PROBE HIT tick=%d x=%.1f py=%.1f %s" % [player.replay_physics_tick, gd_x,
				-level.to_local(player.global_position).y / _CELL_PER_GD, _contacts(player)])
	var state: String = "speed=%.2f mode=%d vis=%s" % [player.speed_multiplier, player.internal_gamemode, str(player.visible)]
	if state != _last_state:
		_last_state = state
		print("PROBE EV tick=%d x=%.1f y=%.1f %s" % [player.replay_physics_tick, gd_x,
				-level.to_local(player.global_position).y / _CELL_PER_GD, state])
	if gd_x >= _next_sample_gd:
		var dense: bool = _macro == null or gd_x > 34000.0
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
		print("PROBE END x=%.1f py=%.1f t=%.1f dead=%s" % [gd_x, player.global_position.y, _elapsed, str(player.dead)])
		print("PROBE CAM finished x=%.0f t=%.1f" % [gd_x, _elapsed])
		get_tree().quit(0)


var _shapes_logged: bool = false
var _contact_gd_x: float = 0.0


## Once per run: the rectangles of the first floor body the cube touches,
## whose x-range covers the cube, with their GD centre and top.
func _shapes_under(body: CollisionObject2D, gd_x: float) -> void:
	var level: Level = LevelManager.current_level
	var lines := 0
	var kinds := {}
	for owner_id: int in body.get_shape_owners():
		var sh: Shape2D = body.shape_owner_get_shape(owner_id, 0)
		var key: String = sh.get_class() if sh != null else "null"
		kinds[key] = int(kinds.get(key, 0)) + 1
	print("PROBE SHAPES owners=%d kinds=%s body_pos=%s" % [body.get_shape_owners().size(), str(kinds), str(body.global_position)])
	for owner_id: int in body.get_shape_owners():
		var shape: Shape2D = body.shape_owner_get_shape(owner_id, 0)
		if not (shape is RectangleShape2D):
			continue
		var t: Transform2D = body.global_transform * body.shape_owner_get_transform(owner_id)
		var local: Vector2 = level.to_local(t.origin)
		var cx: float = local.x / _CELL_PER_GD
		var cy: float = -local.y / _CELL_PER_GD
		var w: float = (shape as RectangleShape2D).size.x / _CELL_PER_GD
		var h: float = (shape as RectangleShape2D).size.y / _CELL_PER_GD
		if lines >= 40:
			break
		print("PROBE SHAPE owner=%d centre=(%.1f,%.1f) size=(%.1f,%.1f) top=%.1f bottom=%.1f" % [
				owner_id, cx, cy, w, h, cy + h * 0.5, cy - h * 0.5])
		lines += 1


func _contacts(player: Player) -> String:
	var parts := PackedStringArray()
	parts.append("floor=%s ceil=%s wall=%s" % [str(player.is_on_floor()), str(player.is_on_ceiling()), str(player.is_on_wall())])
	var level: Level = LevelManager.current_level
	_contact_gd_x = level.to_local(player.global_position).x / _CELL_PER_GD
	for index: int in player.get_slide_collision_count():
		var hit: KinematicCollision2D = player.get_slide_collision(index)
		var body: Object = hit.get_collider()
		var label := "?"
		var where := Vector2.ZERO
		if body is Node:
			label = str((body as Node).name)
			var parent: Node = (body as Node).get_parent()
			if parent != null:
				label = str(parent.name) + "/" + label
		if body is Node2D:
			where = level.to_local((body as Node2D).global_position) / _CELL_PER_GD
		parts.append("%s@(%.0f,%.0f)" % [label, where.x, -where.y])
		var contact_py: float = -level.to_local(player.global_position).y / _CELL_PER_GD
		if not _shapes_logged and body is CollisionObject2D and hit.get_normal().y < -0.5 and contact_py > 1100.0 and contact_py < 1200.0:
			_shapes_logged = true
			print("PROBE CONTACT point=%s normal=%s body=%s" % [str(hit.get_position()), str(hit.get_normal()), label])
			_shapes_under(body as CollisionObject2D, _contact_gd_x)
	return " ".join(parts)


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

var _merge_logged := false
var _settle_ticks := 0

## Guard for the group-25 lock: every object the lock animates must keep its own body
## (merged=false). A merged one is frozen in the shared static body.
func _log_merge_state(level: Level) -> void:
	var found := [0]
	var stack: Array = [level]
	while not stack.is_empty() and found[0] < 20:
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not node is Node2D or node is Player:
			continue
		var gd_at: Vector2 = level.to_local((node as Node2D).global_position)
		var gx := gd_at.x / _CELL_PER_GD
		var gy := -gd_at.y / _CELL_PER_GD
		if gx < 100.0 or gx > 140.0 or gy < 1050.0 or gy > 1200.0 or not node.has_meta(&"gd_object_id"):
			continue
		var groups := PackedStringArray()
		for g: StringName in node.get_groups():
			if String(g).begins_with(Constants.GROUP_PREFIX):
				groups.append(String(g))
		found[0] += 1
		print("PROBE MERGE %s name=%s at=(%.1f,%.1f) merged=%s id=%s groups=%s" % [node.get_class(), node.name, gx, gy, str(node.has_meta(LevelPhysics.MERGED_META)), str(node.get_meta(&"gd_object_id", "-")), str(groups)])


## Where every teleport portal and exit really is, and the data behind it.
## Every packed trigger record in the cutscene box, with its real GD keys. The
## runtime nodes do not carry gd_properties, so this is the only place the
## entrance's and exit's own data (key 51 target, key 54 offset) is visible.
## Every collision shape in the sandwich area (any shape type), as GD-unit
## bounds (y up). The exit is (45, 1157), so this shows what is at and just above it.
func _log_solids_in_box(level: Level) -> void:
	# Native collision blocks: nodes in gd_collision_block, a 128 px box centred on the node.
	var block_count := 0
	for block: Node in level.get_tree().get_nodes_in_group("gd_collision_block"):
		var n := block as Node2D
		if n == null or not n.is_visible_in_tree():
			continue
		var local: Vector2 = level.to_local(n.global_position) / _CELL_PER_GD
		var gx: float = local.x
		var gy: float = -local.y
		if gx < -35.0 or gx > 95.0 or gy < 1065.0 or gy > 1255.0:
			continue
		block_count += 1
		if block_count <= 40:
			print("PROBE SOLID NATIVE block id=%d centre=(%.2f,%.2f) x=[%.2f,%.2f] y=[%.2f,%.2f]" % [
				int(n.get_meta("gd_block_id", 0)), gx, gy, gx - 15.0, gx + 15.0, gy - 15.0, gy + 15.0])
	print("PROBE SOLID NATIVE count=%d" % block_count)
	var found := 0
	var stack: Array[Node] = [level]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var body := node as CollisionObject2D
		if body == null:
			continue
		for owner_id: int in body.get_shape_owners():
			var shape: Shape2D = body.shape_owner_get_shape(owner_id, 0)
			if shape == null or body.is_shape_owner_disabled(owner_id):
				continue
			var t: Transform2D = body.global_transform * body.shape_owner_get_transform(owner_id)
			var o: Vector2 = level.to_local(t.origin)
			var r: Rect2 = shape.get_rect()
			var left: float = (o.x + r.position.x) / _CELL_PER_GD
			var right: float = (o.x + r.end.x) / _CELL_PER_GD
			var gd_top: float = -(o.y + r.position.y) / _CELL_PER_GD
			var gd_bottom: float = -(o.y + r.end.y) / _CELL_PER_GD
			if right < -20.0 or left > 80.0 or gd_bottom > 1240.0 or gd_top < 1080.0:
				continue
			found += 1
			if found <= 40:
				print("PROBE SOLID %s body=%s layer=%d mask=%d x=[%.2f,%.2f] y=[%.2f,%.2f] owner=%d" % [
					shape.get_class(), str(body.name), body.collision_layer, body.collision_mask,
					left, right, gd_bottom, gd_top, owner_id])
	print("PROBE SOLID count=%d" % found)


func _log_packed_box(level: Level) -> void:
	var packed: Dictionary = level.packed_trigger_records
	if packed.is_empty():
		print("PROBE PACKED none")
		return
	var ids: PackedInt32Array = packed.get("gd_id", PackedInt32Array())
	for i in ids.size():
		var row: Dictionary = PackedTriggers.row(packed, i)
		var origin: Vector2 = row.transform.origin
		var gx := origin.x / _CELL_PER_GD
		var gy := -origin.y / _CELL_PER_GD
		if gx < -60.0 or gx > 120.0 or gy < 1050.0 or gy > 1450.0:
			continue
		var props: Dictionary = row.gd_properties
		print("PROBE PACKED id=%d at=(%.1f,%.1f) k51=%s k54=%s k10=%s k11=%s props=%s" % [
			int(row.gd_object_id), gx, gy, str(props.get("51", "-")), str(props.get("54", "-")),
			str(props.get("10", "-")), str(props.get("11", "-")), str(props).left(260)])


func _log_teleports(level: Level) -> void:
	var stack: Array = [level]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not node is Node2D or not String(node.name).begins_with("Teleportal"):
			continue
		var at: Vector2 = level.to_local((node as Node2D).global_position)
		var props: Dictionary = node.get_meta(&"gd_properties", {})
		var target := ""
		var teleport := node.get_node_or_null("TeleportComponent")
		if teleport != null:
			target = str(teleport.get("keep_player_x")) + " target=" + str(node.get_node_or_null("TargetObjectComponent"))
		print("PROBE TP %s at=(%.1f,%.1f) id=%s key54=%s key351=%s groups=%s %s" % [
			node.name, at.x / _CELL_PER_GD, -at.y / _CELL_PER_GD,
			str(node.get_meta(&"gd_object_id", "-")), str(props.get("54", "-")),
			str(props.get("351", "-")), str(node.get_groups()), target])

