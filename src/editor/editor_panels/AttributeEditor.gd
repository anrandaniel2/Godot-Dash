class_name AttributeEditor
extends VBoxContainer

static var BOOL_ATTRIBUTES: Array[Script] = [
	NoTouchAttribute,
	DisabledInLowDetailModeAttribute,
]

static var FLAG_ATTRIBUTES: Dictionary[String, Array] = {
	"Hide": [HideSpriteAttribute, HideBaseAttribute, HideDetailAttribute, HideParticlesAttribute],
	"Music Scale": [MusicScaleSpriteAttribute, MusicScaleBaseAttribute, MusicScaleDetailAttribute, MusicScaleParticlesAttribute, MusicScaleHitboxAttribute],
}

var bool_properties: Dictionary[Script, BoolProperty]
var flag_properties: Dictionary[String, FlagsProperty]


func _init() -> void:
	BOOL_ATTRIBUTES.make_read_only()
	FLAG_ATTRIBUTES.make_read_only()


func _ready() -> void:
	for attribute in BOOL_ATTRIBUTES:
		var property := BoolProperty.new()
		property.name = attribute.get_global_name().trim_suffix("Attribute").capitalize()
		bool_properties[attribute] = property
		add_child(property)

	for category_name in FLAG_ATTRIBUTES:
		var property := FlagsProperty.new()
		property.name = category_name
		for attribute in FLAG_ATTRIBUTES[category_name]:
			property.flags.append(attribute.get_global_name().trim_prefix(category_name.to_pascal_case()).trim_suffix("Attribute").capitalize())
		flag_properties[category_name] = property
		add_child(property)


func _on_edit_handler_selection_changed(selection: Selection) -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return
	var ignore_player := func(object: Node2D): return object is not Player
	var filtered_selection: Selection = selection.filter(ignore_player)
	connect_ui(filtered_selection)
	load_bool_properties(filtered_selection.first())


func connect_ui(selection: Selection) -> void:
	for attribute in bool_properties:
		var property: BoolProperty = bool_properties[attribute]
		var remove_connections := func(connection):
			if not "watcher" in connection.callable.get_method():
				property.value_changed.disconnect(connection.callable)
		property.value_changed.get_connections().map(remove_connections)
		property.value_changed.connect(save_bool_attribute.bind(property, attribute, selection))
	for category_name in flag_properties:
		var property: FlagsProperty = flag_properties[category_name]
		var remove_connections := func(connection):
			if not "watcher" in connection.callable.get_method():
				property.interaction_ended.disconnect(connection.callable)
		property.interaction_ended.get_connections().map(remove_connections)
		property.interaction_ended.connect(save_flag_attribute.bind(property, FLAG_ATTRIBUTES[category_name], selection))


func save_bool_attribute(enabled: bool, property: BoolProperty, attribute_script: Script, selection: Selection) -> void:
	var add_attribute := func(_selection: Selection):
		for _object in _selection.to_array():
			NodeUtils.get_node_or_add(
				_object,
				str(attribute_script.get_global_name()),
				attribute_script,
				NodeUtils.SET_OWNER | NodeUtils.FORCE_READABLE_NAME,
			)
		property.set_value_no_signal(true)
	var remove_attribute := func(_selection: Selection):
		for _object in _selection.to_array():
			NodeUtils.get_children_of_type(_object, attribute_script).map(NodeUtils.free_node)
		property.set_value_no_signal(false)

	var selection_snapshot: Selection = selection.clone()
	var version_history: UndoRedo = Editor.version_history
	version_history.create_action("Set '%s' to %s on %s objects" % [attribute_script.get_global_name(), enabled, selection_snapshot.size()])
	version_history.add_do_method(add_attribute.bind(selection_snapshot) if enabled else remove_attribute.bind(selection_snapshot))
	version_history.add_undo_method(remove_attribute.bind(selection_snapshot) if enabled else add_attribute.bind(selection_snapshot))
	version_history.commit_action()


func save_flag_attribute(flags: int, previous_flags: int, property: FlagsProperty, attribute_scripts: Array, selection: Selection) -> void:
	var set_flags := func(_selection: Selection, _flags: int):
		for _object in _selection.to_array():
			for i in attribute_scripts.size():
				var attribute_script: Script = attribute_scripts[i]
				if _flags & 1 << i:
					NodeUtils.get_node_or_add(
						_object,
						str(attribute_script.get_global_name()),
						attribute_script,
						NodeUtils.SET_OWNER | NodeUtils.FORCE_READABLE_NAME,
					)
				else:
					NodeUtils.get_children_of_type(_object, attribute_script).map(NodeUtils.free_node)
		property.set_value_no_signal(_flags)

	var selection_snapshot: Selection = selection.clone()
	var version_history: UndoRedo = Editor.version_history
	version_history.create_action("Changed '%s' flags on %s objects" % [property.name, selection_snapshot.size()])
	version_history.add_do_method(set_flags.bind(selection_snapshot, flags))
	version_history.add_undo_method(set_flags.bind(selection_snapshot, previous_flags))
	version_history.commit_action()


func load_bool_properties(object: Node2D) -> void:
	for attribute in bool_properties:
		var property := bool_properties[attribute]
		property.set_value_no_signal(object.has_node(str(attribute.get_global_name())))
