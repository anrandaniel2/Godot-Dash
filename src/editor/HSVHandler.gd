class_name HSVHandler
extends Node

@export var hue: FloatProperty
@export var saturation: FloatProperty
@export var value: FloatProperty
@export var intensity: FloatProperty
@export var alpha: FloatProperty

var hsv_watchers: Array[HSVWatcher]


func _ready() -> void:
	var connections: Dictionary[FloatProperty, Callable]
	connections.assign(
		{
			hue: _on_hue_value_changed,
			saturation: _on_saturation_value_changed,
			value: _on_value_value_changed,
			intensity: _on_intensity_value_changed,
			alpha: _on_alpha_value_changed,
		},
	)
	for property: FloatProperty in connections:
		property.interaction_ended.connect(_on_property_interaction_ended.bind(property, connections[property]))


func _on_edit_handler_selection_changed(selection: Selection) -> void:
	if selection.is_empty():
		hsv_watchers.clear()
		return
	# Selected nodes need not own a watcher - a DecorationBatch has none - so
	# the nulls are dropped rather than assigned into a typed array.
	hsv_watchers.assign(
		(
				selection.map_generic(BaseDetailHandler.into_base)
				+ selection.map_generic(BaseDetailHandler.get_detail_or_null).filter(ArrayUtils.flatten)
		)
		.map(BaseDetailHandler.use_hsv_watcher)
		.filter(func(hsv_watcher): return hsv_watcher != null),
	)
	if hsv_watchers.is_empty():
		return
	var last_hsv_watcher: HSVWatcher = hsv_watchers[-1]
	hue.set_value_no_signal(last_hsv_watcher.hsv_shift[0])
	saturation.set_value_no_signal(last_hsv_watcher.hsv_shift[1])
	value.set_value_no_signal(last_hsv_watcher.hsv_shift[2])
	intensity.set_value_no_signal(last_hsv_watcher.intensity)
	alpha.set_value_no_signal(last_hsv_watcher.alpha)


func _on_hue_value_changed(new_hue: float) -> void:
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.hsv_shift[0] = new_hue
		hsv_watcher.update_color()


func _on_saturation_value_changed(new_saturation: float) -> void:
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.hsv_shift[1] = new_saturation
		hsv_watcher.update_color()


func _on_value_value_changed(new_value: float) -> void:
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.hsv_shift[2] = new_value
		hsv_watcher.update_color()


func _on_intensity_value_changed(new_intensity: float) -> void:
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.intensity = new_intensity
		hsv_watcher.update_color()


func _on_alpha_value_changed(new_alpha: float) -> void:
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.alpha = new_alpha
		hsv_watcher.update_color()


func _on_property_interaction_ended(new_value: float, previous_value: float, property: FloatProperty, action: Callable) -> void:
	var hsv_watchers_history: Array[HSVWatcher] = hsv_watchers.duplicate()
	hsv_watchers_history.make_read_only()
	var set_property := func(_value: float) -> void:
		hsv_watchers = hsv_watchers_history
		action.call(_value)
		property.set_value_no_signal(_value)
	var version_history: UndoRedo = Editor.version_history
	version_history.create_action("Changed %s on %s objects" % [property.name.capitalize().to_lower(), hsv_watchers_history.size()])
	version_history.add_do_method(set_property.bind(new_value))
	version_history.add_undo_method(set_property.bind(previous_value))
	version_history.commit_action()
