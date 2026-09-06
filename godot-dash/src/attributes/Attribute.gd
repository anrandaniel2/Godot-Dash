@abstract
@icon("res://addons/at-icons/node/flag_triangular.svg")
class_name Attribute
extends Node
## Equivalent of Marker for non-Interactable nodes

func _enter_tree() -> void:
	register()
	NodeUtils.connect_once(tree_exiting, unregister)


func register() -> void:
	var parent: Node2D = get_parent()
	var current_attributes: Array = parent.get_meta(Constants.ATTRIBUTE_META, [])
	if not get_script().get_global_name() in current_attributes:
		current_attributes.append(_get_script_path())
	parent.set_meta(Constants.ATTRIBUTE_META, current_attributes)


func unregister() -> void:
	if not is_queued_for_deletion():
		return
	var parent: Node2D = get_parent()
	var current_attributes: Array = parent.get_meta(Constants.ATTRIBUTE_META, [])
	current_attributes.erase(_get_script_path())
	parent.set_meta(Constants.ATTRIBUTE_META, current_attributes)


func _get_script_path() -> String:
	return get_script().resource_path.trim_prefix(Constants.ATTRIBUTE_PATH_ROOT).get_basename()
