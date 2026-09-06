class_name BaseDetailHandler
extends Node

@export var base: SearchableStringProperty
@export var detail: SearchableStringProperty
@export var color_channel_editor: ColorChannelEditor


func _ready() -> void:
	base.input.focus_entered.connect(_on_property_focus_entered)
	detail.input.focus_entered.connect(_on_property_focus_entered)


func clear_color_channels(selection: Array) -> void:
	for color_channel in LevelManager.current_level.color_channels:
		selection.map(func(object): object.remove_from_group(color_channel.associated_group))


func _load_base(objects_base: Array[HSVWatcher]) -> void:
	var base_groups: Array[StringName] = objects_base.back().get_groups()
	if base_groups.is_empty():
		base.set_value_no_signal("")
		return
	var base_channel: StringName = base_groups[0]
	if base_channel.is_empty():
		base.set_value_no_signal("")
		return
	base.set_value_no_signal(base_channel.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX))
	var base_watcher: ColorChannelWatcher = get_tree().get_first_node_in_group(ColorChannelWatcher.WATCHER_GROUP_PREFIX + base_channel)
	base_watcher.refresh_objects_color(objects_base)


func _load_detail(objects_detail: Array[HSVWatcher]) -> void:
	if objects_detail.is_empty():
		return
	var detail_groups: Array[StringName] = objects_detail.back().get_groups()
	if detail_groups.is_empty():
		detail.set_value_no_signal("")
		return
	var detail_channel: StringName = detail_groups[0]
	if detail_channel.is_empty():
		detail.set_value_no_signal("")
		return
	detail.set_value_no_signal(detail_channel.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX))
	var detail_watcher: ColorChannelWatcher = get_tree().get_first_node_in_group(ColorChannelWatcher.WATCHER_GROUP_PREFIX + detail_channel)
	detail_watcher.refresh_objects_color(objects_detail)


func _on_edit_handler_selection_changed(selection: Selection) -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return
	# Base
	var objects_base: Array[HSVWatcher]
	objects_base.assign(selection.map_generic(into_base).map(use_hsv_watcher))
	_load_base(objects_base)
	# Detail
	var objects_detail: Array[HSVWatcher]
	objects_detail.assign(selection.map_generic(get_detail_or_null).filter(ArrayUtils.flatten).map(use_hsv_watcher))
	_load_detail(objects_detail)


func _on_property_focus_entered() -> void:
	if color_channel_editor.button_group.get_pressed_button():
		color_channel_editor.button_group.get_pressed_button().set_pressed(false)


func _on_base_color_interaction_ended(base_channel: String, previous_base_channel: String) -> void:
	var existing_color_channels := LevelManager.current_level.color_channels.map(func(channel): return channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX))
	if not base_channel.is_empty() and not base_channel in existing_color_channels:
		base.set_value_no_signal("")
		return
	var objects_base: Array[HSVWatcher]
	objects_base.assign(
		$"../EditHandler".selection \
				.map_generic(into_base) \
				.map(use_hsv_watcher),
	)
	var map_object_base_to_channel := func(accum: Dictionary, hsv_watcher: HSVWatcher):
		var groups: Array[StringName] = hsv_watcher.get_groups()
		accum[hsv_watcher] = groups[0] if groups.size() > 0 else &""
		return accum
	var objects_base_to_channel: Dictionary[HSVWatcher, StringName]
	objects_base_to_channel.assign(objects_base.reduce(map_object_base_to_channel, { }))

	var do_set_base_channel := func(_objects_base: Array[HSVWatcher]):
		base.set_value_no_signal(base_channel)
		clear_color_channels(_objects_base)
		if base_channel.is_empty():
			_objects_base.map(reset_color)
			return
		_objects_base.map(func(object): object.add_to_group(Constants.COLOR_CHANNEL_GROUP_PREFIX + base_channel, true))
		var watcher: ColorChannelWatcher = get_tree().get_first_node_in_group(ColorChannelWatcher.WATCHER_GROUP_PREFIX + Constants.COLOR_CHANNEL_GROUP_PREFIX + base_channel)
		watcher.refresh_objects_color(_objects_base)

	var undo_set_base_channel := func(_objects_base_to_channel: Dictionary[HSVWatcher, StringName]):
		base.set_value_no_signal(previous_base_channel)
		var _objects_base := _objects_base_to_channel.keys().map(Deserialize.Node)
		clear_color_channels(_objects_base)
		for hsv_watcher: HSVWatcher in _objects_base_to_channel:
			var hsv_watcher_previous_channel: StringName = _objects_base_to_channel[hsv_watcher]
			if hsv_watcher_previous_channel.is_empty():
				reset_color(hsv_watcher)
				_objects_base.erase(hsv_watcher)
				continue
			hsv_watcher.add_to_group(hsv_watcher_previous_channel)
		_objects_base.map(func(object): object.add_to_group(Constants.COLOR_CHANNEL_GROUP_PREFIX + base_channel, true))
		var watcher: ColorChannelWatcher = get_tree().get_first_node_in_group(ColorChannelWatcher.WATCHER_GROUP_PREFIX + Constants.COLOR_CHANNEL_GROUP_PREFIX + base_channel)
		watcher.refresh_objects_color(_objects_base)

	var version_history: UndoRedo = Editor.version_history
	version_history.create_action("Set base channel to '%s' on %s objects" % [base_channel, objects_base.size()])
	version_history.add_do_method(do_set_base_channel.bind(objects_base.duplicate()))
	version_history.add_undo_method(undo_set_base_channel.bind(objects_base_to_channel.duplicate()))
	version_history.commit_action()


func _on_detail_color_interaction_ended(detail_channel: String, previous_detail_channel: String) -> void:
	var existing_color_channels := LevelManager.current_level.color_channels.map(func(channel): return channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX))
	if not detail_channel in existing_color_channels:
		detail.set_value_no_signal("")
		return
	var objects_detail: Array[HSVWatcher]
	objects_detail.assign(
		$"../EditHandler".selection \
				.map_generic(get_detail_or_null) \
				.filter(ArrayUtils.flatten) \
				.map(use_hsv_watcher),
	)
	var map_object_detail_to_channel := func(accum: Dictionary, hsv_watcher: HSVWatcher):
		var groups: Array[StringName] = hsv_watcher.get_groups()
		accum[hsv_watcher] = groups[0] if groups.size() > 0 else &""
		return accum
	var objects_detail_to_channel: Dictionary[HSVWatcher, StringName]
	objects_detail_to_channel.assign(objects_detail.reduce(map_object_detail_to_channel, { }))

	var do_set_detail_channel := func(_objects_detail: Array[HSVWatcher]):
		detail.set_value_no_signal(detail_channel)
		clear_color_channels(_objects_detail)
		if detail_channel.is_empty():
			_objects_detail.map(reset_color)
			return
		_objects_detail.map(func(object): object.add_to_group(Constants.COLOR_CHANNEL_GROUP_PREFIX + detail_channel, true))
		var watcher: ColorChannelWatcher = get_tree().get_first_node_in_group(ColorChannelWatcher.WATCHER_GROUP_PREFIX + Constants.COLOR_CHANNEL_GROUP_PREFIX + detail_channel)
		watcher.refresh_objects_color(_objects_detail)

	var undo_set_detail_channel := func(_objects_detail_to_channel: Dictionary[HSVWatcher, StringName]):
		detail.set_value_no_signal(previous_detail_channel)
		var _objects_detail: Array[HSVWatcher]
		_objects_detail.assign(_objects_detail_to_channel.keys())
		clear_color_channels(_objects_detail)
		for hsv_watcher: HSVWatcher in _objects_detail_to_channel:
			var hsv_watcher_previous_channel: StringName = _objects_detail_to_channel[hsv_watcher]
			if hsv_watcher_previous_channel.is_empty():
				reset_color(hsv_watcher)
				_objects_detail.erase(hsv_watcher)
				continue
			hsv_watcher.add_to_group(hsv_watcher_previous_channel)
		_objects_detail.map(func(object): object.add_to_group(Constants.COLOR_CHANNEL_GROUP_PREFIX + detail_channel, true))
		var watcher: ColorChannelWatcher = get_tree().get_first_node_in_group(ColorChannelWatcher.WATCHER_GROUP_PREFIX + Constants.COLOR_CHANNEL_GROUP_PREFIX + detail_channel)
		watcher.refresh_objects_color(_objects_detail)

	var version_history: UndoRedo = Editor.version_history
	version_history.create_action("Set detail channel to '%s' on %s objects" % [detail_channel, objects_detail.size()])
	version_history.add_do_method(do_set_detail_channel.bind(objects_detail.duplicate()))
	version_history.add_undo_method(undo_set_detail_channel.bind(objects_detail_to_channel.duplicate()))
	version_history.commit_action()


static func reset_color(hsv_watcher: HSVWatcher) -> void:
	hsv_watcher.modulate = Color.WHITE


## The [HSVWatcher] attached to [param object], or [code]null[/code] when there
## isn't one.
##
## Callers used to assume both the node and its watcher always exist. That holds
## for hand-built scenes, but imported Geometry Dash objects vary: an object may
## carry a secondary colour channel while its artwork has no matching Detail
## layer, in which case the lookup arrives here with a null node. Returning null
## instead of dereferencing it turns that into a no-op rather than a crash.
static func use_hsv_watcher(object: Node2D) -> HSVWatcher:
	if object == null:
		return null
	if not object.has_meta(Constants.HSV_WATCHER_META):
		return null
	return object.get_meta(Constants.HSV_WATCHER_META)


static func into_base(object: Node2D) -> Node2D:
	if object.has_meta(Constants.BASE_TEXTURE_META):
		return object.get_meta(Constants.BASE_TEXTURE_META)
	else:
		return object


static func get_detail_or_null(object: Node2D) -> Node2D:
	if not object.has_meta(Constants.DETAIL_TEXTURE_META):
		return null
	return object.get_meta(Constants.DETAIL_TEXTURE_META)
