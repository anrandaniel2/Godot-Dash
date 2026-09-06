@icon("res://addons/at-icons/control/font.svg")
class_name GroupDisplay
extends Control

# HACK: Workaround for the label text not being serialized
@export_storage var displayed_group: String


func _ready() -> void:
	_on_target_group_component_changed.call_deferred(Constants.GROUP_PREFIX + displayed_group)


func _on_target_group_component_changed(target_group: String) -> void:
	displayed_group = target_group.trim_prefix(Constants.GROUP_PREFIX)
	$Label.text = displayed_group
	var update_width := func(): $Label.position.x = -$Label.size.x / 2
	update_width.call_deferred()
