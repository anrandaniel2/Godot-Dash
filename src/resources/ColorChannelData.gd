class_name ColorChannelData
extends Resource

@export var copy: bool
@export var color := Color.WHITE
@export var copied_channel: Constants.SpecialColorChannel
## Ordinary channel this channel copies (kS38 key 9 / colour trigger key 50),
## following it live: when the source recolours, this channel's members
## recolour too. 0 means no link. GDRweb models this as a CopyColor value on
## the channel's track; our runtime resolves it in ColorChannelWatcher.
@export var copied_channel_id: int = 0
## Copy adjustment applied on top of the source colour (kS38 key 10 / trigger
## key 49). Hue is in turns (Color.h range), saturation/value are additive or
## multiplicative depending on the two flags - GDRweb's HSVShift.
@export var copy_hue: float = 0.0
@export var copy_saturation: float = 1.0
@export var copy_value: float = 1.0
@export var copy_saturation_additive: bool = false
@export var copy_value_additive: bool = false
## When true the channel takes the source's opacity instead of its own
## (kS38 key 17 / trigger key 60). GDRweb's CopyColor.copyOpacity.
@export var copy_opacity: bool = false
@export var hsv_shift: Array[float] = [0.0, 0.0, 0.0]
@export var intensity: float = 1.0
@export var alpha: float = 1.0
## Whether the channel renders additively. Set at import from the channel
## table (kS38 key 5) and flipped at runtime by colour triggers (key 17).
@export var blending: bool
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
		"copied_channel_id": channel.copied_channel_id,
		"copy_hue": channel.copy_hue,
		"copy_saturation": channel.copy_saturation,
		"copy_value": channel.copy_value,
		"copy_saturation_additive": channel.copy_saturation_additive,
		"copy_value_additive": channel.copy_value_additive,
		"copy_opacity": channel.copy_opacity,
		"hsv_shift": channel.hsv_shift,
		"intensity": channel.intensity,
		"alpha": channel.alpha,
		"blending": channel.blending,
		"associated_group": channel.associated_group,
	}


static func from_data(data: Dictionary) -> ColorChannelData:
	var channel := ColorChannelData.new()
	channel.copy = data.copy
	channel.color = data.color
	channel.copied_channel = data.copied_channel
	channel.copied_channel_id = int(data.get("copied_channel_id", 0))
	channel.copy_hue = float(data.get("copy_hue", 0.0))
	channel.copy_saturation = float(data.get("copy_saturation", 1.0))
	channel.copy_value = float(data.get("copy_value", 1.0))
	channel.copy_saturation_additive = bool(data.get("copy_saturation_additive", false))
	channel.copy_value_additive = bool(data.get("copy_value_additive", false))
	channel.copy_opacity = bool(data.get("copy_opacity", false))
	channel.hsv_shift.assign(data.hsv_shift)
	channel.intensity = data.intensity
	channel.alpha = data.alpha
	channel.associated_group = data.associated_group
	if data.has("blending"):
		channel.blending = data.blending
	return channel
