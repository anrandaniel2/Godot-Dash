class_name ColorChannelData
extends Resource

@export var copy: bool
@export var color := Color.WHITE
@export var copied_channel: Constants.SpecialColorChannel
@export var hsv_shift: Array[float] = [0.0, 0.0, 0.0]
@export var intensity: float = 1.0
@export var alpha: float = 1.0
@export var associated_group: String

var watcher: ColorChannelWatcher


func set_copy(should_copy: bool = false) -> ColorChannelData:
	copy = should_copy
	emit_changed()
	return self


func set_color(new_color: Color) -> ColorChannelData:
	color = new_color
	emit_changed()
	return self


func set_copied_channel(new_copied_channel: Constants.SpecialColorChannel) -> ColorChannelData:
	copied_channel = new_copied_channel
	emit_changed()
	return self


func set_hsv_shift(new_hsv_shift: Array[float]) -> ColorChannelData:
	hsv_shift = new_hsv_shift
	emit_changed()
	return self


func set_intensity(new_intensity: float) -> ColorChannelData:
	intensity = new_intensity
	emit_changed()
	return self


func set_alpha(new_alpha: float) -> ColorChannelData:
	alpha = new_alpha
	emit_changed()
	return self


static func to_data(channel: ColorChannelData) -> Dictionary:
	return {
		"copy": channel.copy,
		"color": channel.color,
		"copied_channel": channel.copied_channel,
		"hsv_shift": channel.hsv_shift,
		"intensity": channel.intensity,
		"alpha": channel.alpha,
		"associated_group": channel.associated_group,
	}


static func from_data(data: Dictionary) -> ColorChannelData:
	var channel := ColorChannelData.new()
	channel.copy = data.copy
	channel.color = data.color
	channel.copied_channel = data.copied_channel
	channel.hsv_shift.assign(data.hsv_shift)
	channel.intensity = data.intensity
	channel.alpha = data.alpha
	channel.associated_group = data.associated_group
	return channel
