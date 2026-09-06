class_name ColorChannelChangerComponent
extends Component

enum ColorSpace {
	SRGB,
	OKLAB,
}

const Type = TargetColorChannelComponent.Type

@export var color: Color = Color.WHITE
@export_enum("sRGB", "Oklab") var color_space: int = ColorSpace.OKLAB
@export var reset_color: bool = false:
	set(value):
		reset_color = value
		notify_property_list_changed()
@export_group("Modulation")
@export_range(-1.0, 1.0, 0.01, "slider") var hue: float = 0.0
@export_range(-1.0, 1.0, 0.01, "slider") var saturation: float = 0.0
@export_range(-1.0, 1.0, 0.01, "slider") var value: float = 0.0
@export_range(0.0, 5.0, 0.01, "slider") var intensity: float = 1.0
@export_range(0.0, 1.0, 0.01, "slider") var alpha: float = 1.0

@export_storage var _type: TargetColorChannelComponent.Type

# Type.NAME
@export_storage var initial_color_channel: ColorChannelData
@export_storage var color_channel: ColorChannelData
# Type.SPECIAL
@export_storage var initial_color: Color

@export_storage var gradient: Gradient = Gradient.new()


func _ready() -> void:
	await require([TargetColorChannelComponent, EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _validate_property(property: Dictionary) -> void:
	if _type != Type.CUSTOM and property.name in ["Modulation", "hue", "saturation", "value", "intensity", "alpha"]:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if _type != Type.LEVEL and property.name == "reset_color":
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if reset_color and property.name == "color":
		property.usage |= PROPERTY_USAGE_READ_ONLY


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"color": Color.WHITE,
	}
	return DEFAULT_VALUES.get(property)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_color_channel", "color_channel", "initial_color", "gradient":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return get(field_name)
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		_:
			set(field_name, field_data)


func start(_player: Player) -> void:
	match color_space:
		ColorSpace.SRGB:
			gradient.interpolation_color_space = Gradient.GRADIENT_COLOR_SPACE_SRGB
		ColorSpace.OKLAB:
			gradient.interpolation_color_space = Gradient.GRADIENT_COLOR_SPACE_OKLAB
	var target_color_channel_component: TargetColorChannelComponent = parent.query(TargetColorChannelComponent)
	_type = target_color_channel_component.channel_type
	# enum alias
	match target_color_channel_component.channel_type:
		Type.CUSTOM:
			var with_channel := func(element: ColorChannelData, channel: String): return element.associated_group == channel
			var idx: int = LevelManager.current_level.color_channels.find_custom(with_channel.bind(target_color_channel_component.target_color_channel))
			if idx == -1:
				Toasts.error("In %s: color channel is unset" % parent.name)
				return
			color_channel = LevelManager.current_level.color_channels[idx]
			initial_color_channel = color_channel.duplicate()
			gradient.colors = PackedColorArray([initial_color_channel.color, color])
		Type.LEVEL:
			var Channel = Constants.SpecialColorChannel
			var level: Level = LevelManager.current_level
			match parent.query(TargetColorChannelComponent).target_level_channel:
				Channel.BACKGROUND:
					initial_color = level.background_color
					gradient.colors = PackedColorArray([initial_color, color if not reset_color else level.default_background_color])
				Channel.GROUND:
					initial_color = level.ground_color
					gradient.colors = PackedColorArray([initial_color, color if not reset_color else level.default_ground_color])
				Channel.LINE:
					initial_color = level.line_color
					gradient.colors = PackedColorArray([initial_color, color if not reset_color else level.default_line_color])
				Channel.P1:
					pass
				Channel.P2:
					pass
				Channel.GLOW:
					pass


func _on_easing_progressed(player: Player, weight_delta: float) -> void:
	var weight: float = parent.query(EasingComponent).weights[player]
	match _type:
		Type.CUSTOM:
			if not color_channel:
				return
			color_channel.color = gradient.sample(weight)
			color_channel.hsv_shift[0] += (hue - initial_color_channel.hsv_shift[0]) * weight_delta
			color_channel.hsv_shift[1] += (saturation - initial_color_channel.hsv_shift[1]) * weight_delta
			color_channel.hsv_shift[2] += (value - initial_color_channel.hsv_shift[2]) * weight_delta
			color_channel.intensity += (intensity - initial_color_channel.intensity) * weight_delta
			color_channel.alpha += (alpha - initial_color_channel.alpha) * weight_delta
			color_channel.emit_changed()
		Type.LEVEL:
			var Channel = Constants.SpecialColorChannel
			var level: Level = LevelManager.current_level
			match parent.query(TargetColorChannelComponent).target_level_channel:
				Channel.BACKGROUND:
					level.background_color = gradient.sample(weight)
				Channel.GROUND:
					level.ground_color = gradient.sample(weight)
				Channel.LINE:
					level.line_color = gradient.sample(weight)
				Channel.P1:
					pass
				Channel.P2:
					pass
				Channel.GLOW:
					pass


func _on_target_color_channel_type_changed(type: Type) -> void:
	_type = type
	notify_property_list_changed()
