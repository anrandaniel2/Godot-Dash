class_name Level
extends Node2D

@warning_ignore("unused_signal")
signal default_font_changed

enum EnterEffect {
	DISABLED,
	FADE,
	FADE_AND_MOVE_DOWN,
}

enum UseDataFlags {
	NONE = 0,
	IS_INSTANTIATION = 1,
}

## Metadata key marking a generated gd scene placement that takes part in
## gameplay (solid block, slope, spike or saw), as opposed to a decoration.
## Gameplay placements serialize in the gameplay entry format (scene path +
## gd_object_id) so the level rebuilds them through the gameplay path.
const GD_GAMEPLAY_META: StringName = &"gd_gameplay"

const START_SPEED: Array[float] = [
	0.0, # 0x
	0.807, # 0.5x
	1.0, # 1x
	1.243, # 2x
	1.502, # 3x
	1.849, # 4x
	2.431, # 5x
]

@export var creator: String = Config.username
@export var description: String = ""
@export var rating: int = -1
@export var creation_date: int = int(Time.get_unix_time_from_system())
@export var flashing_lights: bool = false

@export_file var song_path: String:
	set(value):
		register_required_song(song_path, value.get_file())
		song_path = value.get_file()
		AssetManager.load_song_threaded_request(Constants.SONG_DIR + value.get_file())
@export_range(0.0, 60.0, 0.01, "or_greater", "suffix:s") var song_start_time: float
@export var default_font: String:
	set(value):
		register_required_font(default_font, value)
		default_font = value
		default_font_changed.emit()
@export var platformer: bool:
	set(value):
		platformer = value
		LevelManager.platformer = value
		if LevelManager.player:
			LevelManager.player.displayed_gamemode = start_displayed_gamemode
@export var start_position: Vector2 = Constants.DEFAULT_PLAYER_POSITION
@export var start_internal_gamemode: Player.Gamemode:
	set(value):
		start_internal_gamemode = value
		if LevelManager.player:
			LevelManager.player.internal_gamemode = start_internal_gamemode
@export var start_displayed_gamemode: Player.Gamemode:
	set(value):
		start_displayed_gamemode = value
		if LevelManager.player:
			LevelManager.player.displayed_gamemode = start_displayed_gamemode
@export var start_freefly: bool = true
@export var start_speed_preset: int = EasedSpeedChangerComponent.SpeedPreset.x1
@export var start_speed: float = START_SPEED[2]
@export var start_reverse: bool
@export var start_gameplay_rotation_degrees: float
@export var start_gravity_multiplier: float = 1.0
@export var start_gravity_flip: int = 1
@export var default_background_color: Color = Constants.DEFAULT_BACKGROUND_COLOR:
	set(new_color):
		default_background_color = new_color
		background_color = new_color
@export var default_ground_color: Color = Constants.DEFAULT_GROUND_COLOR:
	set(new_color):
		default_ground_color = new_color
		ground_color = new_color
@export var default_line_color: Color = Constants.DEFAULT_LINE_COLOR:
	set(new_color):
		default_line_color = new_color
		line_color = new_color
@export var transition_width: float = 15.0:
	set(value):
		transition_width = value
		_update_enter_effect_shader_parameter(&"transition_width", value)
@export var fade_power: float = 1.0:
	set(value):
		fade_power = value
		_update_enter_effect_shader_parameter(&"fade_power", value)
@export var move_power: float = 0.0:
	set(value):
		move_power = value
		_update_enter_effect_shader_parameter(&"move_power", value)
@export var scale_power: float = 0.0:
	set(value):
		scale_power = value
		_update_enter_effect_shader_parameter(&"scale_power", value)

# Used to disable "Edit" button in the pause menu for official levels
@export var is_editable: bool = true

@export_storage var color_channels: Array[ColorChannelData]
@export_storage var duration: float

var song_player: AudioStreamPlayer
var stopwatch: Stopwatch
## Hides objects far outside the camera while the level plays (see FrustumCuller).
var culler: FrustumCuller
var layers: Array[Layer]
## Generic 2.2 triggers elided from the runtime SceneTree, retained for saves,
## practice rebuilds, and NativeTriggerRuntime registration.
var native_trigger_records: Array[Dictionary] = []
var active_layer_idx: int
var music_scale: float = 1.0
var required_songs: Dictionary[String, int] # HashMap<SongPath, SongUsers>
var required_fonts: Dictionary[String, int] # HashMap<FontPath, FontUsers>
var background_color: Color = Constants.DEFAULT_BACKGROUND_COLOR:
	set(new_color):
		if Editor.render_mode_manager and Editor.render_mode_manager.mode == RenderMode.Mode.OBJECT_MODE:
			return
		background_color = new_color
		for background_sprite: Sprite2D in LevelManager.background_sprites:
			background_sprite.modulate = new_color
		_refresh_level_color_copies(_background_copy_watchers)
var ground_color: Color = Constants.DEFAULT_GROUND_COLOR:
	set(new_color):
		if Editor.render_mode_manager and Editor.render_mode_manager.mode == RenderMode.Mode.OBJECT_MODE:
			return
		# The build job finalises levels outside the playing scene (and the
		# smoke harness runs without one); the value still stores, the ground
		# sprites simply do not exist to tint yet.
		if LevelManager.ground_down == null:
			return
		var ground_down: Sprite2D = LevelManager.ground_down.get_node(^"Ground")
		var ground_up: Sprite2D = LevelManager.ground_up.get_node(^"Ground")
		ground_down.self_modulate = new_color
		ground_up.self_modulate = new_color
		_refresh_level_color_copies(_ground_copy_watchers)
var line_color: Color = Constants.DEFAULT_LINE_COLOR:
	set(new_color):
		if Editor.render_mode_manager and Editor.render_mode_manager.mode == RenderMode.Mode.OBJECT_MODE:
			return
		if LevelManager.ground_down == null:
			return
		# The material resource is shared between ground sprites
		var ground: Sprite2D = LevelManager.ground_down.get_node(^"Ground")
		ground.material.set_shader_parameter(&"ground_color", new_color)
		_refresh_level_color_copies(_line_copy_watchers)
## Watchers of the channels that copy each level colour (kS38 entries with a
## copy link to channel 1000/1001/1002 or a plain chain ending there). The
## colour setters refresh them so a recoloured background reaches the channels
## built on top of it instead of leaving them frozen at the import snapshot.
var _background_copy_watchers: Array[ColorChannelWatcher] = []
var _ground_copy_watchers: Array[ColorChannelWatcher] = []
var _line_copy_watchers: Array[ColorChannelWatcher] = []


func _refresh_level_color_copies(watchers: Array[ColorChannelWatcher]) -> void:
	for watcher: ColorChannelWatcher in watchers:
		if is_instance_valid(watcher) and watcher.is_inside_tree():
			watcher.refresh_objects_color()

var _elapsed_time: float = 0.0


func _ready() -> void:
	if layers.is_empty():
		var new_layer: Layer = Layer.new()
		new_layer.name = "Unnamed Layer"
		layers.append(new_layer)
		add_child(new_layer)
		if Editor.in_editor:
			new_layer.selected_in_editor = true
			active_layer_idx = 0
	for layer in layers:
		_track_layer_physics(layer)
	stopwatch = Stopwatch.new()
	stopwatch.name = "Stopwatch"
	stopwatch.paused = true
	add_child(stopwatch, false, INTERNAL_MODE_BACK)
	AssetManager.load_song_threaded_request(Constants.SONG_DIR + song_path)
	song_player = AudioStreamPlayer.new()
	song_player.process_mode = Node.PROCESS_MODE_PAUSABLE
	song_player.bus = &"Music"
	song_player.name = "Song Player"
	LevelManager.song_player = song_player
	add_child(song_player, false, INTERNAL_MODE_BACK)
	culler = FrustumCuller.new()
	culler.name = "FrustumCuller"
	add_child(culler, false, INTERNAL_MODE_BACK)


func _process(_delta: float) -> void:
	# The audio-spectrum query is only worth a frame when something reads the
	# value; levels without any MusicScale component (no orbs or pads) skip it
	# entirely. MusicScale keeps its own count of live instances.
	if MusicScale.active_count > 0:
		music_scale = 0.85 + MusicVolume.get_volume()
	_print_beam_diagnostics_live(_delta)


## Rolling BEAMDIAG heartbeat, printed every 5 seconds of play so a device
## logcat captured at the white beams answers the two questions that split the
## bug in half: are the mid-level colour triggers recolouring channels at all
## (recolors/last), and if they are, did the channel table end up non-white
## (colored)? recolors stuck near zero means the triggers never fire; recolors
## climbing while the beams stay white points past the channel table, at the
## batch recolour path. Grep "BEAMDIAG live".
var _beamdiag_seconds: float = 0.0
var _beamdiag_last_print: float = -5.0


func _print_beam_diagnostics_live(delta: float) -> void:
	if Editor.in_editor or not LevelManager.level_playing:
		_beamdiag_seconds = 0.0
		_beamdiag_last_print = -5.0
		return
	_beamdiag_seconds += delta
	if _beamdiag_seconds - _beamdiag_last_print < 5.0:
		return
	_beamdiag_last_print = _beamdiag_seconds
	var colored := 0
	for channel: ColorChannelData in color_channels:
		var resolved: Color = ColorChannelWatcher.resolve_channel_color(channel)
		var alpha: float = ColorChannelWatcher.resolve_channel_alpha(channel)
		if alpha < 0.99 or resolved.r < 0.95 or resolved.g < 0.95 or resolved.b < 0.95:
			colored += 1
	var camera_x := 0.0
	if LevelManager.player_camera != null:
		camera_x = LevelManager.player_camera.global_position.x
	# Read-side companion to the native colorcap dump: what the recently
	# refreshed channels actually display right now, plus the live level
	# colours (pulse triggers can target those instead of channels).
	var recent_parts: PackedStringArray = []
	var recent_count: int = mini(
		ColorChannelWatcher.live_recent_channels.size(),
		ColorChannelWatcher.live_recent_colors.size()
	)
	for i: int in recent_count:
		var shown: Color = ColorChannelWatcher.live_recent_colors[i]
		recent_parts.append("%s:(%.2f,%.2f,%.2f)" % [
			ColorChannelWatcher.live_recent_channels[i],
			shown.r, shown.g, shown.b,
		])
	print(
		"BEAMDIAG live t=%.0f x=%.0f colored=%d/%d recolors=%d last=%s recent=[%s] bg=(%.2f,%.2f,%.2f) ground=(%.2f,%.2f,%.2f) line=(%.2f,%.2f,%.2f)"
		% [
			_beamdiag_seconds,
			camera_x,
			colored,
			color_channels.size(),
			ColorChannelWatcher.live_recolor_count,
			ColorChannelWatcher.live_last_channel,
			", ".join(recent_parts),
			background_color.r, background_color.g, background_color.b,
			ground_color.r, ground_color.g, ground_color.b,
			line_color.r, line_color.g, line_color.b,
		]
	)


## The shared physics world mirrors the object tree; any object added to or
## removed from a layer invalidates it until the next level start rebuilds it.
func _track_layer_physics(layer: Layer) -> void:
	if layer.child_entered_tree.is_connected(_on_layer_physics_child_changed):
		return
	layer.child_entered_tree.connect(_on_layer_physics_child_changed)
	layer.child_exiting_tree.connect(_on_layer_physics_child_changed)


func _on_layer_physics_child_changed(_child: Node) -> void:
	LevelPhysics.mark_dirty(self)


func prepare_external_data() -> void:
	song_player.stream = AssetManager.load_song_threaded_get(Constants.SONG_DIR + song_path)
	LevelManager.platformer = platformer
	LevelManager.player.internal_gamemode = start_internal_gamemode
	LevelManager.player.displayed_gamemode = start_displayed_gamemode
	LevelManager.player.global_position = start_position
	LevelManager.player.last_automatic_checkpoint_position = start_position
	if platformer:
		LevelManager.touchscreen_controls.enable_platformer(start_internal_gamemode == Player.Gamemode.WAVE)
	else:
		LevelManager.touchscreen_controls.disable_platformer()

	LevelManager.ground_up.show()
	if LevelManager.player_camera and get_viewport().get_camera_2d() == LevelManager.player_camera:
		LevelManager.player_camera.freefly = start_freefly
	if not start_freefly:
		GroundData.center = Constants.DEFAULT_PLAYER_POSITION
		GroundData.distance = GroundMoverComponent.LOCKEDFLY_GAMEMODE_GRID_HEIGHTS[start_internal_gamemode] * Constants.CELL_SIZE * 0.5
		if Constants.DEFAULT_PLAYER_POSITION.y + GroundData.distance > LevelManager.ground_down.default_y:
			GroundData.offset = (Constants.DEFAULT_PLAYER_POSITION.y + GroundData.distance) - LevelManager.ground_down.default_y
		else:
			GroundData.offset = 0

	LevelManager.player.speed_multiplier = start_speed
	LevelManager.player.horizontal_direction = -1 if start_reverse else 1
	LevelManager.player.gameplay_rotation_degrees = start_gameplay_rotation_degrees
	LevelManager.player.gravity_multiplier = start_gravity_multiplier
	LevelManager.player.gravity_flip = start_gravity_flip
	LevelManager.player_camera.position = LevelManager.player.position
	LevelManager.player.on_level_start()


func create_layer(layer_name: String) -> Layer:
	var new_layer: Layer = Layer.new()
	new_layer.name = layer_name

	var add_layer_to_tree := func():
		add_child(new_layer, true)
		layers.append(new_layer)
		new_layer.owner = self
		if Editor.in_editor:
			Editor.root.inspector_tree.refresh()
	var remove_layer_from_tree := func():
		layers.erase(new_layer)
		remove_child(new_layer)
		if Editor.in_editor:
			Editor.root.inspector_tree.refresh()

	_track_layer_physics(new_layer)

	Editor.version_history.create_action("Created layer " + layer_name)
	Editor.version_history.add_do_method(add_layer_to_tree)
	Editor.version_history.add_undo_method(remove_layer_from_tree)
	Editor.version_history.commit_action()

	return new_layer


func remove_layer(layer_name: String) -> bool:
	var layer: Layer = get_node_or_null(layer_name)
	if not layer:
		return false
	if layers.size() == 1:
		Toasts.error("The level must contain at least one layer")
		return false
	elif layer.locked:
		Toasts.warning("Cannot delete a locked layer")
		return false
	var current_active_layer_idx: int = active_layer_idx
	var remove_layer_from_tree := func():
		layers.erase(layer)
		remove_child(layer)
		if Editor.in_editor:
			Editor.root.inspector_tree.set_active_layer(current_active_layer_idx, mini(active_layer_idx, layers.size() - 1))
			Editor.root.inspector_tree.refresh()
	var add_layer_to_tree := func():
		add_child(layer)
		move_child(layer, current_active_layer_idx)
		layers.insert(current_active_layer_idx, layer)
		layer.owner = self
		if Editor.in_editor:
			Editor.root.inspector_tree.set_active_layer(self.active_layer_idx, current_active_layer_idx)
			Editor.root.inspector_tree.refresh()

	Editor.version_history.create_action("Deleted layer " + layer_name)
	Editor.version_history.add_do_method(remove_layer_from_tree)
	Editor.version_history.add_undo_method(add_layer_to_tree)
	Editor.version_history.commit_action()
	return true


func move_layer(layer_name: String, new_layer_index: int) -> void:
	var layer: Layer = get_node_or_null(layer_name)
	if not layer:
		return
	var previous_index: int = layer.get_index()
	var is_layer_active: bool = previous_index == active_layer_idx
	if is_layer_active:
		active_layer_idx = new_layer_index
	layers.remove_at(previous_index)
	layers.insert(new_layer_index, layer)
	move_child(layer, new_layer_index)
	Editor.root.inspector_tree.refresh()


func start_level() -> void:
	if get_tree().paused:
		await LevelManager.pause_menu.unpaused
	song_player.play(song_start_time)
	stopwatch.reset()
	stopwatch.set_elapsed_time_in_seconds(_elapsed_time)
	stopwatch.paused = false
	# Static objects share one physics world per level (see LevelPhysics);
	# (re)build or refresh it before the player moves this attempt. Trigger
	# component data is always settled by now: level loads and restart_level
	# pass at least one frame between deserializing objects (component data
	# applies via call_deferred) and reaching this point.
	LevelPhysics.prepare(self)
	# FrustumCuller listens to level_started/level_stopped on LevelManager and
	# culls this level's placements from the moment it starts playing.
	LevelManager.level_playing = true


func stop_level() -> void:
	song_player.stop()
	LevelManager.player_duals.clear()
	LevelManager.level_playing = false


func record_duration() -> void:
	duration = stopwatch.get_elapsed_time_in_seconds()


func setup_color_channel_watchers() -> void:
	# Fresh BEAMDIAG live counters per level: the heartbeat reads them during
	# play, and a level change must not carry the previous level's recolors.
	ColorChannelWatcher.live_recolor_count = 0
	ColorChannelWatcher.live_last_channel = ""
	ColorChannelWatcher.live_recent_channels = PackedStringArray()
	ColorChannelWatcher.live_recent_colors = []
	# Every watcher is constructed before any of them enters the tree: a
	# copying channel wires itself to its source's watcher on its first
	# refresh (_ready), so the source's watcher must already exist whatever
	# order the channels come in.
	var watchers: Array[ColorChannelWatcher] = []
	for color_channel: ColorChannelData in color_channels:
		var watcher := ColorChannelWatcher.new(color_channel)
		watcher.name = "Watcher@%s" % color_channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
		watchers.append(watcher)
	for watcher: ColorChannelWatcher in watchers:
		add_child(watcher)
	# Channels that copy a level colour follow it live, so the level colour
	# setters need a direct line to their watchers: nothing else fires when
	# the background itself recolours. (Ordinary copy links wire themselves
	# on the watchers' first refresh.)
	for color_channel: ColorChannelData in color_channels:
		if not color_channel.copy or color_channel.watcher == null:
			continue
		match color_channel.copied_channel:
			Constants.SpecialColorChannel.BACKGROUND:
				_background_copy_watchers.append(color_channel.watcher)
			Constants.SpecialColorChannel.GROUND:
				_ground_copy_watchers.append(color_channel.watcher)
			Constants.SpecialColorChannel.LINE:
				_line_copy_watchers.append(color_channel.watcher)
	_print_glow_diagnostics()
	_print_beam_diagnostics()


## Object ids whose artwork is beam-shaped: an atlas frame at least 5:1 and
## 80px long (the long-block outlines and their glow, the 2.2 animation
## strips, planks, rods and the rotating lines). Used only by the BEAMDIAG
## load-time summary below.
const BEAM_SHAPED_IDS: PackedInt32Array = [
	15, 372, 896, 1256, 1257, 1258, 1259, 1338, 1339, 1342, 1345,
	1521, 1522, 1601, 1743, 1744, 1745, 1746, 1747, 1748, 1749, 1750,
	1853, 1858, 1907, 2022, 2030, 2054, 2883, 2886, 2894,
]


## One-shot load-time answer to "why do those beams render white": per colour
## channel, how many batched items follow it, how many of them end up opaque
## white, and what the channel itself resolves to; the same counts narrowed
## to the beam-shaped object ids; and the X distribution of the white items.
##
## This runs after the watchers' first refresh (the ready-connected setup),
## so an item counts as white only if its channel really left it that way.
## A channel whose resolved colour is not white while its items are says the
## binding or the refresh failed; a channel that itself resolves to white
## points at the channel data or its copy chain. BEAMDIAG greps clean.
func _print_beam_diagnostics() -> void:
	if Editor.in_editor:
		return
	var total_items := 0
	var white_items := 0
	# Reference-typed counters [total, white]; packed arrays copy on assign,
	# so mutating them through the dictionary would silently do nothing.
	var by_channel: Dictionary = {}
	var white_by_x: Dictionary = {}
	var beams: Dictionary = {}
	var beam_channel: Dictionary = {}
	for layer: Layer in layers:
		for child: Node in layer.get_children():
			if child is not DecorationBatch:
				continue
			for item: DecorationBatch.Item in child.items:
				total_items += 1
				var white := (
					item.modulate.r > 0.95
					and item.modulate.g > 0.95
					and item.modulate.b > 0.95
					and item.modulate.a > 0.95
				)
				if white:
					white_items += 1
					var bucket := int(item.origin_x / 1000.0)
					var x_counts: Array = white_by_x.get_or_add(bucket, [0])
					x_counts[0] += 1
				var channel_name: StringName = item.channel
				if channel_name.is_empty():
					channel_name = &"(untinted)"
				var counts: Array = by_channel.get_or_add(channel_name, [0, 0])
				counts[0] += 1
				if white:
					counts[1] += 1
				if item.gd_id in BEAM_SHAPED_IDS:
					var beam_counts: Array = beams.get_or_add(item.gd_id, [0, 0])
					beam_counts[0] += 1
					if white:
						beam_counts[1] += 1
					if not beam_channel.has(item.gd_id) and not item.channel.is_empty():
						beam_channel[item.gd_id] = item.channel
	print("BEAMDIAG items=%d white=%d" % [total_items, white_items])
	for channel: ColorChannelData in color_channels:
		var counts: Array = by_channel.get(channel.associated_group, [0, 0])
		if counts[0] == 0:
			continue
		var resolved: Color = ColorChannelWatcher.resolve_channel_color(channel)
		var alpha: float = ColorChannelWatcher.resolve_channel_alpha(channel)
		var copies: bool = channel.copy or channel.copied_channel_id > 0
		print(
			"BEAMDIAG ch=%s items=%d white=%d rgb=(%.2f,%.2f,%.2f) a=%.2f copy=%s"
			% [
				channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX),
				counts[0],
				counts[1],
				resolved.r,
				resolved.g,
				resolved.b,
				alpha,
				"y" if copies else "n",
			]
		)
	# Items on a channel no watcher exists for never refresh at all.
	for channel_name: Variant in by_channel:
		if str(channel_name) == "(untinted)":
			continue
		var has_watcher := false
		for channel: ColorChannelData in color_channels:
			if channel.associated_group == channel_name:
				has_watcher = true
				break
		if not has_watcher:
			var counts: Array = by_channel[channel_name]
			print(
				"BEAMDIAG NO WATCHER ch=%s items=%d white=%d"
				% [str(channel_name).trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX), counts[0], counts[1]]
			)
	var untinted: Array = by_channel.get(&"(untinted)", [0, 0])
	if untinted[0] > 0:
		print("BEAMDIAG untinted items=%d white=%d" % [untinted[0], untinted[1]])
	var beam_ids: Array = beams.keys()
	beam_ids.sort()
	for gd_id: Variant in beam_ids:
		var beam_counts: Array = beams[gd_id]
		var channel_text := str(beam_channel.get(gd_id, "(none)")).trim_prefix(
			Constants.COLOR_CHANNEL_GROUP_PREFIX
		)
		print(
			"BEAMDIAG beam id=%d items=%d white=%d ch=%s"
			% [int(gd_id), beam_counts[0], beam_counts[1], channel_text]
		)
	var buckets: Array = white_by_x.keys()
	buckets.sort()
	var white_line := ""
	for bucket: Variant in buckets:
		white_line += "%d:%d " % [int(bucket), white_by_x[bucket][0]]
	if not white_line.is_empty():
		print("BEAMDIAG white per 1000x: " + white_line.strip_edges())


## One-shot load-time summary of everything that drives the level's glow:
## which channels blend (directly or through a copy), how the glow sprites
## distribute along the level, and which glow-capable placements lack artwork.
## Printed once per level load so a device logcat answers "where did the glow
## go" without a debugger attached. GLOWDIAG greps clean.
func _print_glow_diagnostics() -> void:
	if Editor.in_editor:
		return
	var blending_channels: Array[String] = []
	var copy_channels: Array[String] = []
	for channel: ColorChannelData in color_channels:
		var id := channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
		if channel.blending:
			blending_channels.append(id)
		if channel.copy:
			copy_channels.append("%s<-%d" % [id, channel.copied_channel])
		elif channel.copied_channel_id > 0:
			# Ordinary copy links (kS38 key 9 / trigger key 50): these follow
			# their source live at runtime, so a stale one shows up here as
			# the whole story of a channel that stopped recolouring.
			copy_channels.append("%s<-c%d" % [id, channel.copied_channel_id])
	print(
		"GLOWDIAG channels=%d blending=[%s] copies=[%s]"
		% [color_channels.size(), ", ".join(blending_channels), ", ".join(copy_channels)]
	)
	var total_items := 0
	var glow_items := 0
	var blending_batches := 0
	var batch_count := 0
	var glow_by_bucket: Dictionary[int, int] = { }
	for layer: Layer in layers:
		for child: Node in layer.get_children():
			if child is not DecorationBatch:
				continue
			batch_count += 1
			if child.gd_blending:
				blending_batches += 1
			for item: DecorationBatch.Item in child.items:
				total_items += 1
				if item.layer == "glow":
					glow_items += 1
					var bucket := int(item.origin_x / 1000.0)
					glow_by_bucket[bucket] = glow_by_bucket.get(bucket, 0) + 1
	var bucket_line := ""
	var sorted_buckets := glow_by_bucket.keys()
	sorted_buckets.sort()
	for bucket: int in sorted_buckets:
		bucket_line += "%d:%d " % [bucket, glow_by_bucket[bucket]]
	print(
		"GLOWDIAG batches=%d additive=%d items=%d glow=%d"
		% [batch_count, blending_batches, total_items, glow_items]
	)
	print("GLOWDIAG glow per 1000x: " + bucket_line.strip_edges())
	if not GDDecorationLoader._glow_without_art.is_empty():
		var top := GDDecorationLoader._glow_without_art.keys()
		top.sort_custom(
			func(a, b): return GDDecorationLoader._glow_without_art[a] > GDDecorationLoader._glow_without_art[b]
		)
		var art_line := ""
		for index: int in mini(top.size(), 10):
			var gd_id: int = top[index]
			art_line += "%d:%d " % [gd_id, GDDecorationLoader._glow_without_art[gd_id]]
		print("GLOWDIAG glow wanted, no artwork: " + art_line.strip_edges())


func setup_level_sprites_colors() -> void:
	for background_sprite: Sprite2D in LevelManager.background_sprites:
		background_sprite.modulate = default_background_color
	# Without a playing scene (build job finishing a detached level, or the
	# smoke harness) there are no ground sprites to recolour.
	if LevelManager.ground_down == null:
		return
	var ground_down: Sprite2D = LevelManager.ground_down.get_node(^"Ground")
	var ground_up: Sprite2D = LevelManager.ground_up.get_node(^"Ground")
	ground_down.self_modulate = default_ground_color
	ground_up.self_modulate = default_ground_color
	# The material resource is shared between ground sprites
	var ground: Sprite2D = LevelManager.ground_down.get_node(^"Ground")
	ground.material.set_shader_parameter(&"ground_color", default_line_color)


func register_required_song(old_path: String, new_path: String) -> void:
	if required_songs.has(old_path):
		required_songs[old_path] -= 1
		if required_songs[old_path] <= 0:
			required_songs.erase(old_path)
	if not new_path.is_empty():
		if not required_songs.has(new_path):
			required_songs[new_path] = 0
		required_songs[new_path] += 1


func register_required_font(old_path: String, new_path: String) -> void:
	if required_fonts.has(old_path):
		required_fonts[old_path] -= 1
		if required_fonts[old_path] <= 0:
			required_fonts.erase(old_path)
	if not new_path.is_empty():
		if not required_fonts.has(new_path):
			required_fonts[new_path] = 0
		required_fonts[new_path] += 1


func to_data(reason: Serialize.Reason = Serialize.Reason.SAVE) -> Dictionary:
	var isnt_practice: bool = reason != Serialize.Reason.PRACTICE
	var player: Player = LevelManager.player
	var data: Dictionary = {
		"game_version": ProjectSettings.get_setting("application/config/version"),
		"name": name,
		"creator": creator,
		"description": description,
		"creation_date": creation_date,
		"rating": rating,
		"flashing_lights": flashing_lights,
		"is_editable": is_editable,
		"song_path": song_path if isnt_practice else song_player.stream.resource_path if song_player.stream else song_path,
		"song_start_time": song_start_time if isnt_practice else song_player.get_playback_position(),
		"platformer": platformer,
		"start_position": player.global_position,
		"start_internal_gamemode": start_internal_gamemode if isnt_practice else player.internal_gamemode,
		"start_displayed_gamemode": start_displayed_gamemode if isnt_practice else player.displayed_gamemode,
		"start_freefly": start_freefly if isnt_practice else LevelManager.player_camera.freefly,
		"start_speed": start_speed if isnt_practice else player.speed_multiplier,
		"start_speed_preset": start_speed_preset,
		"start_reverse": start_reverse if isnt_practice else player.horizontal_direction < 0,
		"start_gameplay_rotation_degrees": start_gameplay_rotation_degrees if isnt_practice else player.gameplay_rotation_degrees,
		"start_gravity_multiplier": start_gravity_multiplier if isnt_practice else player.gravity_multiplier,
		"start_gravity_flip": start_gravity_flip if isnt_practice else player.gravity_flip,
		"default_background_color": default_background_color,
		"default_ground_color": default_ground_color,
		"default_line_color": default_line_color,
		"transition_width": transition_width,
		"fade_power": fade_power,
		"move_power": move_power,
		"scale_power": scale_power,
		"color_channels": color_channels.map(ColorChannelData.to_data),
		"duration": duration,
		"native_trigger_records": native_trigger_records,
		"layers": [],
		"active_layer_idx": active_layer_idx,
		"player_data": {
			"groups": player.get_groups(),
			"hsv": player.get_meta(Constants.HSV_WATCHER_META).to_data(),
		},
	}
	if reason == Serialize.Reason.PRACTICE:
		data.practice_data = _get_practice_data()
	for layer: Layer in layers:
		var layer_data: Dictionary = {
			"name": layer.name,
			"objects": [],
			"locked": layer.locked,
		}
		var objects: Array[Node] = layer.get_children()
		for object: Node in objects:
			if object is not Node2D:
				continue
			# A batch stands in for many decoration objects, so it expands back
			# into one data entry each rather than serializing as a single node.
			if object is DecorationBatch:
				layer_data.objects.append_array(
						GDDecorationLoader.serialize_batch(object, GDDecorationLoader.art_scale())
				)
				continue
			layer_data.objects.append(serialize_object(object, reason))
		data.layers.append(layer_data)
	# The native runtime omitted these nodes. Put their records back into the
	# serialized layer so switching to the editor/non-native fallback remains
	# lossless; the top-level side index avoids rediscovering them later.
	if not Editor.in_editor and NativeCore.available() and not native_trigger_records.is_empty() and not data.layers.is_empty():
		data.layers[0].objects.append_array(native_trigger_records)
	return data


func use_data(data: Dictionary, options: int = UseDataFlags.NONE) -> void:
	_use_data_fields(data)
	_use_data_objects(data, options)


## Applies the level-wide fields of a level-data dictionary (metadata, song,
## colours, player start state). Does not touch the object tree.
func _use_data_fields(data: Dictionary) -> void:
	name = data.name
	creator = data.creator
	description = data.description
	rating = data.rating
	creation_date = data.creation_date
	flashing_lights = data.flashing_lights
	is_editable = data.is_editable
	song_path = data.song_path
	song_start_time = data.song_start_time
	platformer = data.platformer
	start_position = data.start_position
	start_internal_gamemode = data.start_internal_gamemode
	start_displayed_gamemode = data.start_displayed_gamemode
	start_freefly = data.start_freefly
	start_speed = data.start_speed
	start_speed_preset = data.start_speed_preset
	start_reverse = data.start_reverse
	start_gameplay_rotation_degrees = data.start_gameplay_rotation_degrees
	start_gravity_multiplier = data.start_gravity_multiplier
	start_gravity_flip = data.start_gravity_flip
	default_background_color = data.default_background_color
	default_ground_color = data.default_ground_color
	default_line_color = data.default_line_color
	transition_width = data.transition_width
	fade_power = data.fade_power
	move_power = data.move_power
	scale_power = data.scale_power
	color_channels.assign(data.color_channels.map(ColorChannelData.from_data))
	duration = data.duration
	native_trigger_records.assign(data.get("native_trigger_records", []))
	active_layer_idx = data.active_layer_idx

	# Player updates only apply once the manager holds the live player from
	# the playing scene; detached builds (and the smoke harness) have none.
	if LevelManager.player != null:
		LevelManager.player.global_position = start_position
		for group in data.player_data.groups:
			LevelManager.player.add_to_group(group)
		LevelManager.player.get_meta(Constants.HSV_WATCHER_META).use_data(data.player_data.hsv)
	# start_internal_gamemode and start_displayed_gamemode are set on the player
	# in their respective setters.

	if "practice_data" in data:
		_apply_practice_data(data.practice_data)
	else:
		_elapsed_time = 0.0


## Applies one object pass of a level-data dictionary onto the existing object
## tree, matching children to data entries by name per layer. Only valid when
## every object in the data has a live node - which is always: the level is
## built fully from its data (see from_data), so every placement has a node.
func _use_data_objects(data: Dictionary, options: int) -> void:
	for layer_idx: int in layers.size():
		var layer: Layer = layers[layer_idx]
		var layer_data: Dictionary = data.layers[layer_idx]
		# Child index cannot be assumed to match data index: low detail mode
		# drops objects, and decoration is collapsed into a couple of batch
		# nodes rather than one node each. Walk the children in step and match
		# by name, skipping data entries that produced no node of their own.
		var child_idx: int = 0
		for object_idx: int in layer_data.objects.size():
			var object_data: Dictionary = layer_data.objects[object_idx]
			if child_idx >= layer.get_child_count():
				break
			var object: Node2D = layer.get_child(child_idx)
			if object is DecorationBatch:
				# Batches are appended after the real objects; skip past them.
				child_idx += 1
				continue
			if object_data.get("decoration", false):
				# A decoration entry is a GDObject node when its type has a
				# generated scene; otherwise it lives inside a DecorationBatch
				# and has no node of its own to deserialize onto.
				if gd_object_entry_has_node(object_data) and object is GDObject and object.name == object_data.name:
					child_idx += 1
					deserialize_data_to_object(object_data, object, self, options & UseDataFlags.IS_INSTANTIATION)
				continue
			if object.name != object_data.name:
				continue
			child_idx += 1
			deserialize_data_to_object(object_data, object, self, options & UseDataFlags.IS_INSTANTIATION)

	setup_level_sprites_colors()


func _get_practice_data() -> Dictionary:
	var practice_data: Dictionary = { }
	practice_data.player_velocity = LevelManager.player.velocity
	practice_data.replay = LevelManager.player.replay
	practice_data.physics_tick = LevelManager.player.replay_physics_tick
	practice_data.elapsed_time = stopwatch.elapsed_time
	return practice_data


## Restores player practice state (velocity, replay position, elapsed time)
## recorded at a checkpoint.
func _apply_practice_data(practice_data: Dictionary) -> void:
	practice_data.replay.data = practice_data.replay.data.slice(0, practice_data.physics_tick)
	var player: Player = LevelManager.player
	# HACK: Force `is_on_floor` to return false so the velocity can be applied.
	player.set_collisions_enabled(false)
	player.velocity = Vector2.ZERO
	player.move_and_slide()
	player.set_collisions_enabled(true)
	player.velocity = practice_data.player_velocity
	player.replay = practice_data.replay
	player.replay_physics_tick = practice_data.physics_tick
	_elapsed_time = practice_data.elapsed_time


func _update_enter_effect_shader_parameter(parameter: StringName, value: float) -> void:
	if not AssetManager.ready:
		await AssetManager.ready
	if not AssetManager.fade_enter_effect:
		await AssetManager.fade_enter_loaded
	AssetManager.fade_enter_effect.set_shader_parameter(parameter, value)
	if not AssetManager.fade_enter_effect_canvas_group:
		await AssetManager.fade_enter_canvas_group_loaded
	AssetManager.fade_enter_effect_canvas_group.set_shader_parameter(parameter, value)


static func from_data(data: Dictionary) -> Level:
	# One unlimited build step: the editor and every synchronous caller get the
	# level fully built exactly as before. GameScene drives the same job with a
	# per-frame budget instead so a device never blocks while a level opens.
	var job := LevelBuildJob.new(data)
	while not job.finished:
		job.step(0x7fffffff)
	return job.level


static func instantiate_object_from_data(
		object_data: Dictionary,
		level: Level = LevelManager.current_level,
) -> Node2D:
	# A decoration entry is instanced from its object type's generated scene.
	# When that scene is missing it has no node of its own (from_data draws it
	# in a DecorationBatch instead), so it must not reach the loader below.
	if object_data.get("decoration", false):
		return instantiate_gd_object(object_data, level)

	var prefab: PackedScene = load("res://%s" % object_data.scene_file_path)
	if not prefab:
		push_error("Resource not found at path: res://%s" % object_data.scene_file_path)
		return
	if Config.ldm and not Editor.in_editor and "attributes" in object_data:
		if "LDMAttribute.gd" in object_data.attributes:
			return null
	var object: Node2D = prefab.instantiate()
	object.name = object_data.name
	# Static gameplay objects (blocks, slopes, spikes, saws) are built from
	# their generated gd scene - the scene carries the GD artwork, the authored
	# collision and the editor selection box. Configure it exactly like a
	# decoration, and mark it gameplay so it serializes back in the gameplay
	# format (kept out of decoration batching / low-detail culling).
	if object is GDObject:
		var gd_object := object as GDObject
		if object_data.has("gd_object_id"):
			gd_object.set_meta(&"gd_object_id", int(object_data.gd_object_id))
		gd_object.set_meta(GD_GAMEPLAY_META, true)
		_configure_gd_object(gd_object, object_data, level)
		return object
	# Hand-made scenes (interactables, and older gameplay data) keep their
	# scene - it carries collision, components and editor behaviour - but wear
	# Geometry Dash's artwork, so a level is not half authentic decoration and
	# half Godot Dash placeholder art.
	if object_data.has("gd_object_id"):
		object.set_meta(&"gd_object_id", int(object_data.gd_object_id))
		GDArtSwap.apply(object, int(object_data.gd_object_id))
		# These scenes carry Godot Dash authored prefabs, so they never run
		# GDObject's draw-order mapping: before this they rendered at z 0,
		# in front of every background-layer decoration batch. Imported
		# gameplay objects (orbs, pads, portals, solids without a generated
		# scene) wear the same z layer/order mapping the generated scenes
		# and decoration batches compute.
		object.z_index = GDObject.z_index_for(
			int(object_data.get("z_layer", GDObject.Z_LAYER_GAMEPLAY)),
			int(object_data.get("z_order", 0))
		)
	# Runtime-only Geometry Dash trigger metadata is intentionally kept on the
	# root Interactable instead of being expanded into one scheduler node per
	# property. NativeTriggerBridge packs these records after level construction.
	for key: StringName in [&"gd_trigger_flags", &"gd_source_order", &"gd_properties"]:
		if object_data.has(key):
			object.set_meta(key, object_data[key])
	if object.has_meta(&"gd_trigger_flags"):
		# Lets NativeTriggerBridge enumerate only trigger roots instead of walking
		# every gameplay/decorative descendant after a large level is built.
		object.add_to_group(&"_gd_native_trigger")
	return object


## Scene of each Geometry Dash object type, loaded on first use.
static var _gd_object_scenes: Dictionary[int, PackedScene] = { }
## Types whose scene is missing, so the disk is asked once per type.
static var _gd_object_scene_missing: Dictionary[int, bool] = { }


## The generated scene for Geometry Dash object [param gd_id], or
## [code]null[/code] when there is none (run tools/build_gd_object_scenes.py).
static func get_gd_object_scene(gd_id: int) -> PackedScene:
	if _gd_object_scenes.has(gd_id):
		return _gd_object_scenes[gd_id]
	if _gd_object_scene_missing.has(gd_id):
		return null
	var path: String = Constants.GD_OBJECT_SCENE_DIR + "gd_%d.tscn" % gd_id
	if not ResourceLoader.exists(path):
		_gd_object_scene_missing[gd_id] = true
		return null
	var scene: PackedScene = load(path)
	if scene == null:
		_gd_object_scene_missing[gd_id] = true
		return null
	_gd_object_scenes[gd_id] = scene
	return scene


## Whether a decoration level-data entry becomes a [GDObject] node when the
## level is built (as opposed to being drawn by a fallback [DecorationBatch]
## or dropped by low detail mode).
static func gd_object_entry_has_node(object_data: Dictionary) -> bool:
	if Config.ldm and not Editor.in_editor and bool(object_data.get("high_detail", false)):
		return false
	return get_gd_object_scene(int(object_data.get("gd_object_id", 0))) != null


## Builds one placed Geometry Dash object from a decoration level-data entry
## (see [method GDDecorationLoader.to_data]). Returns [code]null[/code] when the
## object type has no generated scene, or when low detail mode drops it.
static func instantiate_gd_object(object_data: Dictionary, level: Level) -> GDObject:
	var gd_id: int = int(object_data.get("gd_object_id", 0))
	if Config.ldm and not Editor.in_editor and bool(object_data.get("high_detail", false)):
		return null
	var scene: PackedScene = get_gd_object_scene(gd_id)
	if scene == null:
		return null
	var object: GDObject = scene.instantiate() as GDObject
	if object == null:
		return null
	object.name = str(object_data.get("name", "GD%d" % gd_id))
	object.set_meta(&"gd_object_id", gd_id)
	_configure_gd_object(object, object_data, level)
	return object


## Applies the shared placement data to a generated gd scene instance: draw
## order, tints, colour-channel watchers, HSV, enter-effect material and any
## attributes. Used by both the decoration path and the gameplay path (static
## gameplay objects are the same generated scenes).
static func _configure_gd_object(object: GDObject, object_data: Dictionary, level: Level) -> void:
	object.setup(object_data)

	# Colour channels. The Base and Detail nodes get the watchers a channel
	# repaints, exactly like the Base/Detail sprites of a hand-made scene, so
	# the colour editor and triggers treat both kinds of object alike.
	var base: Node2D = object.get_node_or_null(^"Base")
	var detail: Node2D = object.get_node_or_null(^"Detail")
	var channels: Variant = object_data.get("color_channels", { })
	var base_channel: StringName = &""
	var detail_channel: StringName = &""
	if channels is Dictionary:
		base_channel = StringName(str(channels.get("base", "")))
		detail_channel = StringName(str(channels.get("detail", "")))
	elif channels is String or channels is StringName:
		base_channel = StringName(str(channels))
	# A channel repaints the layer from its own colour, so the layer's opacity
	# must be carried by the watcher rather than baked into the tint, or it
	# would be applied twice.
	_prepare_gd_layer(base, not base_channel.is_empty(), object.base_alpha)
	_prepare_gd_layer(detail, not detail_channel.is_empty(), object.base_alpha)
	PlaceHandler.add_hsv_watchers(object, level)
	if base != null:
		object.set_meta(Constants.BASE_TEXTURE_META, base)
		_bind_gd_layer(base, base_channel, object.hsv_shift, object.base_alpha)
	if detail != null:
		object.set_meta(Constants.DETAIL_TEXTURE_META, detail)
		_bind_gd_layer(detail, detail_channel, object.detail_hsv_shift, object.base_alpha)
	var own_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(object)
	if own_watcher != null and object_data.has("hsv"):
		own_watcher.use_data(object_data.hsv)
	# The level's enter effect. Every sprite in the scene draws with its
	# parent's material, so setting it once on the root covers them all;
	# additive objects keep their blend material instead.
	if object.material == null:
		object.material = AssetManager.fade_enter_effect
	# Attributes behave exactly as they do on hand-made gameplay scenes.
	if "attributes" in object_data:
		var attributes: Array[String]
		attributes.assign(object_data.attributes)
		for attribute: String in attributes:
			var attribute_script: Script = load("%s/%s.gd" % [Constants.ATTRIBUTE_PATH_ROOT, attribute.get_basename()])
			NodeUtils.get_node_or_add(object, str(attribute_script.get_global_name()), attribute_script, NodeUtils.SET_OWNER | NodeUtils.FORCE_READABLE_NAME)


## Splits a layer's baked tint so that, once a channel watcher owns the layer,
## the object's own opacity lives on the watcher and not in the colour.
static func _prepare_gd_layer(layer: Node2D, on_channel: bool, own_alpha: float) -> void:
	if layer == null or not on_channel or own_alpha <= 0.0:
		return
	layer.modulate.a = clampf(layer.modulate.a / own_alpha, 0.0, 1.0)


## Puts a layer's watcher on its colour channel and gives it the object's own
## HSV shift and opacity, which the channel colour is refined by.
static func _bind_gd_layer(
		layer: Node2D,
		channel: StringName,
		shift: PackedFloat32Array,
		own_alpha: float,
) -> void:
	var watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(layer)
	if watcher == null or channel.is_empty():
		return
	watcher.add_to_group(channel)
	watcher.alpha = own_alpha
	if shift.size() >= 3:
		watcher.hsv_shift.assign([shift[0], shift[1], shift[2]])
		# Geometry Dash's saturation and value shifts are added or multiplied
		# depending on two flags; the watcher supports both.
		watcher.saturation_multiplies = shift.size() > 3 and shift[3] < 0.5
		watcher.value_multiplies = shift.size() > 4 and shift[4] < 0.5


static func deserialize_data_to_object(object_data: Dictionary, object: Node2D, level: Level, is_instantiation: bool) -> void:
	# [method instantiate_object_from_data] returns null whenever an object was
	# deliberately not created - filtered out by low detail mode, or imported
	# decoration whose artwork isn't available on this machine. Callers pass
	# that result straight through, so absorb it here rather than making every
	# call site remember.
	if object == null:
		return

	object.transform = object_data.transform

	# A placed Geometry Dash object is fully configured by
	# instantiate_gd_object; only the reset of a re-used node applies here.
	if object is GDObject:
		if not is_instantiation:
			object.show()
			object.process_mode = Node.PROCESS_MODE_INHERIT
			var gd_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(object)
			if gd_watcher != null and object_data.has("hsv"):
				gd_watcher.use_data(object_data.hsv)
		return

	if is_instantiation:
		# Groups
		for group: String in object_data.groups:
			object.add_to_group(group)
		# Color channels
		var base: Node2D = object.get_node_or_null(^"Base")
		var detail: Node2D = object.get_node_or_null(^"Detail")
		PlaceHandler.add_hsv_watchers(object, level)
		# An imported object can name a colour channel for a layer its artwork
		# doesn't actually have (a secondary channel with no Detail sprite, say),
		# so every lookup here is allowed to come back empty.
		if object_data.color_channels is String or object_data.color_channels is StringName:
			var watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(object)
			if watcher:
				watcher.add_to_group(object_data.color_channels)
		elif object_data.color_channels is Dictionary and not object_data.color_channels.is_empty():
			if "base" in object_data.color_channels:
				var base_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(base)
				if base_watcher:
					object.set_meta(Constants.BASE_TEXTURE_META, base)
					base_watcher.add_to_group(object_data.color_channels.base)
			if "detail" in object_data.color_channels:
				var detail_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(detail)
				if detail_watcher:
					object.set_meta(Constants.DETAIL_TEXTURE_META, detail)
					detail_watcher.add_to_group(object_data.color_channels.detail)
		# Texture Override
		if "texture_override" in object_data:
			var override_data: Dictionary = object_data.texture_override
			if "base" in override_data:
				base.texture = load("res://%s" % override_data.base)
			if "detail" in override_data:
				detail.texture = load("res://%s" % override_data.detail)
			object.get_node(^"EditorSelectionCollider").id = override_data.id
			object.set_meta(Constants.TEXTURE_OVERRIDE_META, override_data)
		# Attributes
		if "attributes" in object_data:
			var attributes: Array[String]
			attributes.assign(object_data.attributes)
			for attribute: String in attributes:
				var attribute_script: Script = load("%s/%s.gd" % [Constants.ATTRIBUTE_PATH_ROOT, attribute.get_basename()])
				NodeUtils.get_node_or_add(object, str(attribute_script.get_global_name()), attribute_script, NodeUtils.SET_OWNER | NodeUtils.FORCE_READABLE_NAME)
		# Enter Effect
		for child: Node in object.get_children():
			apply_enter_effect(child)
	else:
		# Ensure objects are toggled on
		object.show()
		object.process_mode = Node.PROCESS_MODE_INHERIT

	# Physics
	if "physics" in object_data:
		object.use_data(object_data.physics)
	# HSV. A node only has a watcher once add_hsv_watchers() has run for it,
	# which is skipped for objects that aren't being instantiated.
	var hsv_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(object)
	if hsv_watcher:
		hsv_watcher.use_data(object_data.hsv)
	# Interactables
	if object is Interactable:
		if object.has(EasingComponent):
			object.query(EasingComponent).reset()
		if object.has(EndLevelComponent):
			object.query(EndLevelComponent).reset()
		if object.has(SingleUsageComponent):
			object.query(SingleUsageComponent).reset()
		if "components" in object_data:
			var components: Dictionary[String, Dictionary]
			components.assign(object_data.components)
			object.use_component_data.call_deferred(components)
		if "markers" in object_data:
			object.markers_from_data(object_data.markers)


## Serializes one placed object from a generated gd scene.
##
## Decorations keep the scene-less decoration format ([method GDObject.to_data])
## so they route back through [method instantiate_gd_object] and may collapse
## into batches. Gameplay placements (blocks, slopes, spikes, saws) keep the
## gameplay entry format instead: they must never be treated as decorations
## (low detail mode culls those, and batching would strip their collision).
static func serialize_gd_object(object: GDObject) -> Dictionary:
	if not object.has_meta(GD_GAMEPLAY_META):
		return object.to_data()
	var object_data := object.to_gameplay_data()
	if object.has_meta(Constants.ATTRIBUTE_META):
		object_data.attributes = object.get_meta(Constants.ATTRIBUTE_META)
	return object_data


static func serialize_object(object: Node2D, reason: Serialize.Reason) -> Dictionary:
	if object is GDObject:
		return serialize_gd_object(object as GDObject)

	var object_data: Dictionary = {
		"name": object.name,
		"scene_file_path": object.scene_file_path.trim_prefix("res://"),
		"transform": object.transform,
		"groups": object.get_groups(),
		"color_channels": { },
		"hsv": _hsv_data(object),
	}
	_set_object_color_channel_data(object, object_data)
	if object.has_meta(Constants.TEXTURE_OVERRIDE_META):
		object_data.texture_override = object.get_meta(Constants.TEXTURE_OVERRIDE_META)
	if object.has_meta(Constants.ATTRIBUTE_META):
		object_data.attributes = object.get_meta(Constants.ATTRIBUTE_META)
	# Preserve the Geometry Dash identity so a re-loaded level still gets the
	# right artwork swapped in.
	if object.has_meta(&"gd_object_id"):
		object_data.gd_object_id = object.get_meta(&"gd_object_id")
	if object.has_meta(&"physics"):
		object_data.physics = object.get_data()
	if object is Interactable:
		object_data.components = object.components_to_data(reason)
		object_data.markers = object.markers_to_data()
	return object_data


## HSV data for [param object], falling back to neutral values when it has no
## watcher yet.
static func _hsv_data(object: Node2D) -> Dictionary:
	var watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(object)
	if watcher:
		return watcher.to_data()
	return { "hsv_shift": [0.0, 0.0, 0.0], "intensity": 1.0, "alpha": 1.0 }


static func _set_object_color_channel_data(object: Node2D, object_data: Dictionary) -> void:
	# Each watcher lookup can legitimately come back empty - an object may
	# record a Base/Detail meta whose node has no watcher yet - so none of these
	# results are chained on directly.
	if object.has_meta(Constants.BASE_TEXTURE_META):
		var base_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(
				object.get_meta(Constants.BASE_TEXTURE_META)
		)
		if base_watcher:
			var base_color_channel: Array[StringName] = base_watcher.get_groups()
			if not base_color_channel.is_empty():
				object_data.color_channels.base = base_color_channel[0]

		if object.has_meta(Constants.DETAIL_TEXTURE_META):
			var detail_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(
					object.get_meta(Constants.DETAIL_TEXTURE_META)
			)
			if detail_watcher:
				var detail_color_channel: Array[StringName] = detail_watcher.get_groups()
				if not detail_color_channel.is_empty():
					object_data.color_channels.detail = detail_color_channel[0]
	else:
		# Color channel groups might be attached to the object directly
		# if it doesn't have a Base.
		var object_watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(object)
		if object_watcher:
			var object_color_channels: Array = object_watcher \
					.get_groups() \
					.filter(func(group: String): return group.begins_with(Constants.COLOR_CHANNEL_GROUP_PREFIX))
			if not object_color_channels.is_empty():
				object_data.color_channels = object_color_channels[0]


static func apply_enter_effect(object_child: Node) -> void:
	# Geometry Dash artwork swapped onto a nine-patch block lives in a child
	# sprite of the original node (see GDArtSwap), one level deeper than the
	# scene's own art, so it is reached explicitly.
	var swapped_art: Node = object_child.get_node_or_null(^"GDArt")
	if swapped_art != null:
		apply_enter_effect(swapped_art)
	if object_child is CanvasGroup:
		object_child.material = AssetManager.fade_enter_effect_canvas_group
		return
	if not (
			object_child is Sprite2D
			or object_child is NinePatchSprite2D
			or object_child is ReboundOrbSprite
			or object_child is ReboundPadSprite
			or object_child is HitboxDisplay
			or object_child is Line2D
	):
		return
	if object_child.material:
		return
	object_child.material = AssetManager.fade_enter_effect


static func generate_version_warning(
		level_version: Version,
) -> String:
	var game_version: Version = Version.new(ProjectSettings.get_setting("application/config/version"))
	var has_breaking_changes: bool = game_version.major > level_version.major
	var game_out_of_date: bool = game_version.is_lesser_than(level_version)

	if has_breaking_changes:
		return "Current version might contain breaking changes."
	elif game_out_of_date:
		return "Your game is out of date."
	else:
		return ""
