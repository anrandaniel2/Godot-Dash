class_name TargetGroupComponent
extends Component

signal changed(target_group: String)

@export_placeholder("Group name") var target_group: String:
	set(value):
		target_group = value
		changed.emit.call_deferred(value)


func _validate_property(property: Dictionary) -> void:
	if property.name == "target_group":
		property.suggestion_provider = preload("res://resources/GroupSuggestionProvider.tres")
