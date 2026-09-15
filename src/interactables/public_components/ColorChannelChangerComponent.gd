class_name ColorChannelChangerComponent
extends Component

enum ColorSpace {
	SRGB,
	OKLAB,
}

## Where the colour this trigger fades towards comes from.
##
## Geometry Dash only serialises the RGB keys of a hand-picked colour, so an
## imported trigger without them either copies another channel (key 50),
## follows one of the player colours (keys 15/16), or changes nothing about
## the colour at all while opacity and other properties still fade. Read at
## activation time, never import time, so sources track later recolours.
enum ColorSource {
	COLOR,
	COPY_CHANNEL,
	PLAYER_1,
	PLAYER_2,
	KEEP,
}

const Type = TargetColorChannelComponent.Type

## Geometry Dash's reserved channel IDs that alias a live level or player
## colour instead of an entry in the runtime channel table. Every other
## reserved ID (3DL, Obj, LBG, Black, White, ...) is synthesised into the
## channel table as an ordinary channel and resolves through it.
const CHANNEL_BACKGROUND := 1000
const CHANNEL_GROUND := 1001
const CHANNEL_LINE := 1002
const CHANNEL_PLAYER_1 := 1005
const CHANNEL_PLAYER_2 := 1006
const CHANNEL_GROUND_2 := 1009

@export var color: Color = Color.WHITE
@export_enum("sRGB", "Oklab") var color_space: int = ColorSpace.OKLAB
@export var source: ColorSource = ColorSource.COLOR:
	set(value):
		source = value
		notify_property_list_changed()
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
## The Blending checkbox: part of the trigger's target state, applied the
## moment it fires rather than faded. Flips the channel additive/normal, which
## is how effect levels switch their glow on and off mid-level. Tri-state:
## only triggers that actually carry the checkbox ([code]has_blending[/code])
## touch the channel's blend; a trigger without it leaves any earlier flip
## intact instead of reverting the channel to normal.
@export var blending: bool = false
@export var has_blending: bool = false
@export_group("Copied channel")
@export var copied_channel_id: int = 0
@export var copy_opacity: bool = false
@export_range(-1.0, 1.0, 0.01, "slider") var copy_hue: float = 0.0
@export_range(-1.0, 1.0, 0.01, "slider") var copy_saturation: float = 0.0
@export_range(-1.0, 1.0, 0.01, "slider") var copy_value: float = 0.0
@export var copy_saturation_additive: bool = true
@export var copy_value_additive: bool = true

@export_storage var _type: TargetColorChannelComponent.Type

# Type.NAME
@export_storage var initial_color_channel: ColorChannelData
@export_storage var color_channel: ColorChannelData
# Type.SPECIAL
@export_storage var initial_color: Color

@export_storage var gradient: Gradient = Gradient.new()

## The copy link this trigger's channel ends up with (-1 none pending): the
## link goes live when the fade completes so the fade towards the source
## stays visible, matching the native runtime and GDRweb's mix towards the
## live copy during the fade.
var _pending_copy_link: int = -1


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
	if source != ColorSource.COLOR and property.name == "color":
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if source != ColorSource.COPY_CHANNEL and (property.name == "Copied channel" or property.name.begins_with("copy")):
		property.usage = PROPERTY_USAGE_NO_EDITOR


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
				gradient.colors = PackedColorArray([initial_color_channel.color, _resolved_color(initial_color_channel.color)])
			# Blending is target state applied at fire time, not faded:
			# the checkbox itself is the channel's new blend mode - but only
			# for triggers that carry the checkbox (tri-state), so a plain
			# colour trigger cannot revert an overlapping Blending flip.
			if has_blending and color_channel.blending != blending:
					color_channel.blending = blending
					color_channel.emit_changed()
				# The copy link is target state too (key 50): re-pointing the
				# channel at its source keeps it following that source's later
				# recolours (GDRweb's CopyColor track value), while an explicit
				# colour or player target severs the link. A copy link goes
				# live when the fade completes so the fade towards the source
				# stays visible; severing happens at fire time.
				match source:
					ColorSource.COPY_CHANNEL:
						_pending_copy_link = copied_channel_id
						if parent.query(EasingComponent).duration <= 0.0:
							_apply_pending_copy_link()
					ColorSource.COLOR, ColorSource.PLAYER_1, ColorSource.PLAYER_2:
						_pending_copy_link = -1
						color_channel.copied_channel_id = 0
					ColorSource.KEEP:
						# Opacity-only: no colour change and no link change.
						_pending_copy_link = -1
		Type.LEVEL:
			var Channel = Constants.SpecialColorChannel
			var level: Level = LevelManager.current_level
			match parent.query(TargetColorChannelComponent).target_level_channel:
				Channel.BACKGROUND:
					initial_color = level.background_color
					gradient.colors = PackedColorArray([initial_color, level.default_background_color if reset_color else _resolved_color(initial_color)])
				Channel.GROUND:
					initial_color = level.ground_color
					gradient.colors = PackedColorArray([initial_color, level.default_ground_color if reset_color else _resolved_color(initial_color)])
				Channel.LINE:
					initial_color = level.line_color
					gradient.colors = PackedColorArray([initial_color, level.default_line_color if reset_color else _resolved_color(initial_color)])
				Channel.P1:
					pass
				Channel.P2:
					pass
				Channel.GLOW:
					pass


## The colour this trigger fades its channel towards.
##
## Copy and player sources are resolved on every activation, so they track
## later recolours of their source instead of a colour baked at import time.
## [param keep] is the channel's colour at activation, and the fallback for
## sources that cannot be resolved.
func _resolved_color(keep: Color) -> Color:
	match source:
		ColorSource.COPY_CHANNEL:
			var copied := _resolve_copied_channel()
			if copied.is_empty():
				return keep
			# A copied opacity (key 60) replaces the trigger's own for this
			# activation; the export is refreshed so re-fires re-resolve it.
			if copy_opacity:
				alpha = copied["alpha"]
			return _shift_copied_hsv(copied["color"])
		ColorSource.PLAYER_1:
			return Config.primary_color
		ColorSource.PLAYER_2:
			return Config.secondary_color
		ColorSource.KEEP:
			return keep
		_:
			return color


## The channel a copy-colour trigger reads from, as
## [code]{ "color": Color, "alpha": float }[/code].
##
## Reserved channel IDs resolve to their live level or player colour; custom
## channels are looked up in the level's channel table and resolve through
## ColorChannelWatcher, so a source that is itself a copy follows its own link
## (with its copy HSV) just like at render time. An ID nothing provides yields
## an empty dictionary, and the trigger then simply keeps the channel's
## current colour.
func _resolve_copied_channel() -> Dictionary:
	if copied_channel_id <= 0:
		return { }
	var level: Level = LevelManager.current_level
	if level == null:
		return { }
	# Explicit comparisons rather than match patterns: a reserved ID must be
	# compared against its constant, never captured as a binding.
	if copied_channel_id == CHANNEL_BACKGROUND:
		return { "color": level.background_color, "alpha": 1.0 }
	if copied_channel_id == CHANNEL_GROUND or copied_channel_id == CHANNEL_GROUND_2:
		return { "color": level.ground_color, "alpha": 1.0 }
	if copied_channel_id == CHANNEL_LINE:
		return { "color": level.line_color, "alpha": 1.0 }
	if copied_channel_id == CHANNEL_PLAYER_1:
		return { "color": Config.primary_color, "alpha": 1.0 }
	if copied_channel_id == CHANNEL_PLAYER_2:
		return { "color": Config.secondary_color, "alpha": 1.0 }
	var with_channel := func(element: ColorChannelData, id: int): return element.associated_group == Constants.COLOR_CHANNEL_GROUP_PREFIX + str(id)
	var idx: int = level.color_channels.find_custom(with_channel.bind(copied_channel_id))
	if idx == -1:
		return { }
	var channel: ColorChannelData = level.color_channels[idx]
	if channel.copy or channel.copied_channel_id > 0:
		return {
			"color": ColorChannelWatcher.resolve_channel_color(channel),
			"alpha": ColorChannelWatcher.resolve_channel_alpha(channel),
		}
	return { "color": channel.color, "alpha": channel.alpha }


## Applies the copy-colour HSV adjustment to a resolved source colour, in
## Geometry Dash's additive and multiplicative slider modes.
func _shift_copied_hsv(base: Color) -> Color:
	if is_zero_approx(copy_hue) and is_zero_approx(copy_saturation) and is_zero_approx(copy_value):
		return base
	return Color.from_hsv(
		fposmod(base.h + copy_hue, 1.0),
		clampf(base.s + copy_saturation if copy_saturation_additive else base.s * copy_saturation, 0.0, 1.0),
		clampf(base.v + copy_value if copy_value_additive else base.v * copy_value, 0.0, 1.0),
		base.a,
	)


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
			if _pending_copy_link != -1 and weight >= 1.0:
				_apply_pending_copy_link()
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


## Re-points the channel at its trigger's copy source (key 50), so it keeps
## following that source's later recolours once this trigger's fade is done.
func _apply_pending_copy_link() -> void:
	if _pending_copy_link <= 0 or color_channel == null:
		_pending_copy_link = -1
		return
	color_channel.copied_channel_id = _pending_copy_link
	color_channel.copy_opacity = copy_opacity
	color_channel.copy_hue = copy_hue
	color_channel.copy_saturation = copy_saturation
	color_channel.copy_value = copy_value
	color_channel.copy_saturation_additive = copy_saturation_additive
	color_channel.copy_value_additive = copy_value_additive
	_pending_copy_link = -1


func _on_target_color_channel_type_changed(type: Type) -> void:
	_type = type
	notify_property_list_changed()
