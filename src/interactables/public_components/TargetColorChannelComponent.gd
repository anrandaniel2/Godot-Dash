class_name TargetColorChannelComponent
extends Component

signal type_changed(type: Type)
signal changed(target_color_channel: String)

enum Type {
	CUSTOM,
	LEVEL,
}

@export var channel_type: Type:
	set(value):
		channel_type = value
		type_changed.emit(value)
		match value:
			Type.CUSTOM:
				changed.emit.call_deferred(target_color_channel)
			Type.LEVEL:
				changed.emit.call_deferred(Constants.SpecialColorChannel.find_key(target_level_channel).capitalize())
		notify_property_list_changed()
@export_placeholder("Color channel name") var target_color_channel: String:
	set(value):
		# LevelBuildJob deserializes components while the new Level is still
		# detached and before GameScene publishes it as current_level. Imported
		# channel names were already validated by GMDConverter, so retain the
		# value during that construction window instead of dereferencing null.
		var current := LevelManager.current_level
		var color_channel_exists := current == null or value in current.color_channels.map(
				func(data: ColorChannelData): return data.associated_group
		)
		target_color_channel = value if color_channel_exists else ""
		if channel_type == Type.CUSTOM:
			changed.emit(target_color_channel)
@export var target_level_channel: Constants.SpecialColorChannel:
	set(value):
		target_level_channel = value
		if channel_type == Type.LEVEL:
			changed.emit.call_deferred(Constants.SpecialColorChannel.find_key(value).capitalize())


func _validate_property(property: Dictionary) -> void:
	if property.name == "target_color_channel":
		if channel_type != Type.CUSTOM:
			property.usage = PROPERTY_USAGE_NO_EDITOR
		property.suggestion_provider = preload("res://resources/ColorChannelSuggestionProvider.tres")
	if property.name == "target_level_channel" and channel_type != Type.LEVEL:
		property.usage = PROPERTY_USAGE_NO_EDITOR
