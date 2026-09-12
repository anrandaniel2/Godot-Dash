class_name ColorChannelWatcher
extends Node

const WATCHER_GROUP_PREFIX := "watcher_"

static var DEFAULT_DATA := ColorChannelData.new()

var data: ColorChannelData

## Packed C++ index over this channel's HSVWatchers (see NativeColorChannelIndex).
## Null in the editor and on builds without the native extension; those keep the
## original GDScript loop below.
var _native_index: Object
## Group size and HSVWatcher.data_version at the time _native_index was
## configured. Either changing rebuilds the snapshot, so native recolouring can
## never go stale against watcher state mutated at runtime (a practice-snapshot
## restore re-applies per-object HSV data through HSVWatcher.use_data).
var _native_member_count: int = -1
var _native_watcher_version: int = -1


func _init(new_data: ColorChannelData) -> void:
	data = new_data
	data.watcher = self
	add_to_group(WATCHER_GROUP_PREFIX + data.associated_group)
	data.changed.connect(refresh_objects_color)


func _exit_tree() -> void:
	if is_queued_for_deletion():
		reset_objects_color()


func _ready() -> void:
	refresh_objects_color()


func refresh_objects_color(hsv_watchers: Array[HSVWatcher] = [], _data: ColorChannelData = data) -> void:
	if hsv_watchers.is_empty():
		if _refresh_native(_data):
			_refresh_decoration_batches(_data)
			return
		hsv_watchers.assign(get_tree().get_nodes_in_group(_data.associated_group))
	for hsv_watcher: HSVWatcher in hsv_watchers:
		if _data.copy:
			match _data.copied_channel:
				Constants.SpecialColorChannel.BACKGROUND:
					hsv_watcher.modulate = LevelManager.current_level.background_color
				Constants.SpecialColorChannel.GROUND:
					hsv_watcher.modulate = LevelManager.current_level.ground_color
				Constants.SpecialColorChannel.LINE:
					hsv_watcher.modulate = LevelManager.current_level.line_color
				Constants.SpecialColorChannel.P1:
					hsv_watcher.modulate = Config.primary_color
				Constants.SpecialColorChannel.P2:
					hsv_watcher.modulate = Config.secondary_color
				Constants.SpecialColorChannel.GLOW:
					hsv_watcher.modulate = Config.glow_color
		else:
			hsv_watcher.modulate = _data.color
		hsv_watcher.modulate.s += _data.hsv_shift[1]
		hsv_watcher.modulate.v += _data.hsv_shift[2]
		hsv_watcher.modulate.h += _data.hsv_shift[0]
		hsv_watcher.base_intensity = _data.intensity
		hsv_watcher.base_alpha = _data.alpha
		hsv_watcher.update_color()
	_refresh_decoration_batches(_data)


## Recolours every watcher of this channel through the native index. One
## Variant call replaces a per-object GDScript method call plus roughly fifteen
## property accesses, which colour-pulse-heavy levels used to pay on every
## animation frame for every member of a channel. Returns false (and does
## nothing) whenever the portable path must run: the editor, explicit watcher
## subsets, resets, or builds without the extension.
func _refresh_native(_data: ColorChannelData) -> bool:
	if Editor.in_editor or _data != data or not NativeCore.available():
		return false
	if _native_index == null:
		if not ClassDB.class_exists(&"NativeColorChannelIndex"):
			return false
		_native_index = ClassDB.instantiate(&"NativeColorChannelIndex")
	var members: Array = get_tree().get_nodes_in_group(_data.associated_group)
	if _native_member_count != members.size() or _native_watcher_version != HSVWatcher.data_version:
		_native_index.call(&"configure", members)
		_native_member_count = members.size()
		_native_watcher_version = HSVWatcher.data_version
	var shift: Array[float] = _data.hsv_shift
	_native_index.call(
		&"apply", _channel_color(_data),
		shift[0] if shift.size() > 0 else 0.0,
		shift[1] if shift.size() > 1 else 0.0,
		shift[2] if shift.size() > 2 else 0.0,
		_data.intensity,
		_data.alpha,
	)
	return true


## This channel's own colour, with copy channels resolved to their source
## colour. Channel HSV shifts are applied on top of it, exactly like the
## GDScript loop (and the native index) do.
func _channel_color(channel_data: ColorChannelData) -> Color:
	if not channel_data.copy:
		return channel_data.color
	var level: Level = LevelManager.current_level
	if level == null:
		return channel_data.color
	match channel_data.copied_channel:
		Constants.SpecialColorChannel.BACKGROUND:
			return level.background_color
		Constants.SpecialColorChannel.GROUND:
			return level.ground_color
		Constants.SpecialColorChannel.LINE:
			return level.line_color
		Constants.SpecialColorChannel.P1:
			return Config.primary_color
		Constants.SpecialColorChannel.P2:
			return Config.secondary_color
		Constants.SpecialColorChannel.GLOW:
			return Config.glow_color
	return channel_data.color


## Pushes this channel's colour into every [DecorationBatch].
##
## Batched decoration has no [HSVWatcher] of its own - that is the point of
## batching - so it cannot be reached through the group above. Each batch
## recolours its own items in a single pass instead.
func _refresh_decoration_batches(_data: ColorChannelData) -> void:
	if not is_inside_tree() or LevelManager.current_level == null:
		return
	var channel := StringName(_data.associated_group)
	var color: Color = _channel_color(_data)
	color.s += _data.hsv_shift[1]
	color.v += _data.hsv_shift[2]
	color.h += _data.hsv_shift[0]
	# Intensity scales the colour, not the alpha, so multiply the RGB only.
	color = Color(color.r, color.g, color.b) * _data.intensity
	color.a = _data.alpha

	# Batches register themselves in a group per channel, so only the ones that
	# actually use this channel are visited. Walking every layer's children for
	# each of a level's ~170 channels is otherwise a large, pointless cost at
	# load time.
	for node: Node in get_tree().get_nodes_in_group(DecorationBatch.CHANNEL_GROUP_PREFIX + channel):
		if node is DecorationBatch:
			node.apply_channel_color(channel, color)


func remove_objects_from_group(hsv_watchers: Array[HSVWatcher]) -> void:
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.remove_from_group(data.associated_group)


func reset_objects_color() -> void:
	# The native snapshot is only valid for the members it was configured with;
	# dropping it also drops the editor/reset paths onto the portable loop.
	_native_index = null
	_native_member_count = -1
	_native_watcher_version = -1
	var hsv_watchers: Array[HSVWatcher]
	hsv_watchers.assign(get_tree().get_nodes_in_group(data.associated_group))
	refresh_objects_color(hsv_watchers, DEFAULT_DATA)
	remove_objects_from_group(hsv_watchers)
