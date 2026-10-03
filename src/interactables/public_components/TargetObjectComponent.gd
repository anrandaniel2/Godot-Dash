class_name TargetObjectComponent
extends Component

@export var target: NodePath:
	set(value):
		target = value
		if override.is_empty():
			_override_saved_value = value

## Override the target to another one defined in code.
## Used by [CameraStaticComponent] to force the target
## to be [LevelManager.player] when its mode is set to
## [CameraStaticComponent.Mode.EXIT].
var override: NodePath:
	set(value):
		if override != value:
			override = value
			notify_property_list_changed()

var _override_saved_value: NodePath


func _validate_property(property: Dictionary) -> void:
	if property.name == "target":
		if not override.is_empty():
			target = override
			property.usage |= PROPERTY_USAGE_READ_ONLY
		else:
			# Avoid `previously freed` values
			target = _override_saved_value if not _override_saved_value.is_empty() else ^""


func target_to_node() -> Node2D:
	if not LevelManager.current_level or target.is_empty():
		return null
	return LevelManager.current_level.get_node_or_null(target)
