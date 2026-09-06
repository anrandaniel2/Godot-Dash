@icon("res://addons/at-icons/node2d/icons.svg")
class_name Interactable
extends Area2D

@warning_ignore("unused_signal")
signal interacted(player: Player)

var components: Array[Component]


func _ready() -> void:
	if has_node(^"Hitbox"):
		$Hitbox.debug_color = Color.hex(0x00ff0033)


func register_public(component: Component) -> void:
	components.append(component)


func has(component_type: Script) -> bool:
	return components.any(func(component): return component and component.get_script() == component_type)


func query(component_type: Script) -> Component:
	var component_idx := components.find_custom(func(component): return component and component.get_script() == component_type)
	return components[component_idx] if component_idx >= 0 else null


func components_to_data(reason: Serialize.Reason) -> Dictionary[String, Dictionary]:
	var data: Dictionary[String, Dictionary]
	var should_serialize_component := func(component: Component): return not component.get_script() in InteractableEditor.COMPONENT_BLACKLIST
	var serialized_components: Array[Component]
	serialized_components.assign(components.filter(should_serialize_component))
	for serialized_component: Component in serialized_components:
		var serialized_component_name: String = serialized_component.get_script().get_global_name()
		data[serialized_component_name] = serialized_component.to_data(reason)
	return data


func use_component_data(data: Dictionary[String, Dictionary]) -> void:
	for component_name: String in data:
		var component_instance: Component = get_node(component_name)
		var component_data: Dictionary = data[component_name]
		component_instance.use_data(component_data)


func markers_to_data() -> Array:
	var serialized_markers: Array[Marker]
	var is_marker := func(component: Component): return component is Marker
	var to_name := func(marker: Marker): return marker.get_script().get_global_name()
	serialized_markers.assign(ArrayUtils.to_set(components.filter(is_marker)))
	return serialized_markers.map(to_name)


func markers_from_data(data: PackedStringArray) -> void:
	var has_name := func(marker_script: Script, marker_name: String): return marker_script.get_global_name() == marker_name
	for marker_name: String in data:
		var marker_scripts: Array = InteractableEditor.MARKER_COMPONENTS.filter(has_name.bind(marker_name))
		if marker_scripts.is_empty():
			continue
		var marker_script: Script = marker_scripts.front()
		NodeUtils.get_node_or_add(self, str(marker_script.get_global_name()), marker_script, NodeUtils.SET_OWNER | NodeUtils.FORCE_READABLE_NAME)
