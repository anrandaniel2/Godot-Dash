@icon("res://addons/at-icons/control/font.svg")
class_name ColorChannelDisplay
extends Control

# HACK: Workaround for the label text not being serialized
@export_storage var displayed_color_channel: String


func _ready() -> void:
	_on_target_color_channel_component_changed.call_deferred(Constants.COLOR_CHANNEL_GROUP_PREFIX + displayed_color_channel)


func _on_target_color_channel_component_changed(target_color_channel: String) -> void:
	displayed_color_channel = target_color_channel.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
	$Label.text = displayed_color_channel
	var update_width := func(): $Label.position.x = -$Label.size.x / 2
	update_width.call_deferred()
