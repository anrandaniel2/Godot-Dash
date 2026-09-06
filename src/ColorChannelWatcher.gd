class_name ColorChannelWatcher
extends Node

const WATCHER_GROUP_PREFIX := "watcher_"

static var DEFAULT_DATA := ColorChannelData.new()

var data: ColorChannelData


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


## Pushes this channel's colour into every [DecorationBatch].
##
## Batched decoration has no [HSVWatcher] of its own - that is the point of
## batching - so it cannot be reached through the group above. Each batch
## recolours its own items in a single pass instead.
func _refresh_decoration_batches(_data: ColorChannelData) -> void:
	if not is_inside_tree() or LevelManager.current_level == null:
		return
	var channel := StringName(_data.associated_group)
	var color: Color = _data.color
	if _data.copy:
		match _data.copied_channel:
			Constants.SpecialColorChannel.BACKGROUND:
				color = LevelManager.current_level.background_color
			Constants.SpecialColorChannel.GROUND:
				color = LevelManager.current_level.ground_color
			Constants.SpecialColorChannel.LINE:
				color = LevelManager.current_level.line_color
			Constants.SpecialColorChannel.P1:
				color = Config.primary_color
			Constants.SpecialColorChannel.P2:
				color = Config.secondary_color
			Constants.SpecialColorChannel.GLOW:
				color = Config.glow_color
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
	var hsv_watchers: Array[HSVWatcher]
	hsv_watchers.assign(get_tree().get_nodes_in_group(data.associated_group))
	refresh_objects_color(hsv_watchers, DEFAULT_DATA)
	remove_objects_from_group(hsv_watchers)
