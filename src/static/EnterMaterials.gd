class_name EnterMaterials
extends RefCounted
## Keyed copies of the shared enter-effect materials (FadeEnterEffect /
## FadeEnterEffectAdditive) for objects with their own enter settings:
## Don't Fade (key 64), Don't Enter (key 67) and Enter Channel (key 343).
## Objects without them keep the shared materials, so ordinary levels build
## exactly the batches they did before. The shader side is
## GDEnterEffect.gdshaderinc (gd_object_flags / gd_object_channel).

const FLAG_DONT_FADE: int = 1
const FLAG_DONT_ENTER: int = 2

static var _cache: Dictionary[int, ShaderMaterial] = {}
## Channel -> Vector2i(enter type, exit type) set by Enter triggers.
static var _channels: Dictionary[int, Vector2i] = {}


## The packed enter key: flags in bits 0-1, the channel above them. Must
## match NativePackedDecorationBuilder's enter key.
static func key(flags: int, channel: int) -> int:
	return (maxi(channel, 0) << 2) | (flags & 3)


static func material(additive: bool, enter_key: int) -> Material:
	var shared: ShaderMaterial = AssetManager.fade_enter_effect_additive if additive else AssetManager.fade_enter_effect
	if enter_key == 0 or shared == null:
		return DecorationBatch.fade_material(additive)
	var cache_key := (enter_key << 1) | int(additive)
	if _cache.has(cache_key):
		return _cache[cache_key]
	var keyed := shared.duplicate() as ShaderMaterial
	var channel := enter_key >> 2
	keyed.set_shader_parameter(&"gd_object_flags", enter_key & 3)
	keyed.set_shader_parameter(&"gd_object_channel", channel)
	var types: Vector2i = _channels.get(channel, Vector2i(1, 1))
	keyed.set_shader_parameter(&"gd_channel_enter", types.x)
	keyed.set_shader_parameter(&"gd_channel_exit", types.y)
	_cache[cache_key] = keyed
	return keyed


## Mirrors a shared-material parameter (enabled, transition width...) onto
## every keyed copy.
static func set_parameter(parameter: StringName, value: Variant) -> void:
	for keyed: ShaderMaterial in _cache.values():
		keyed.set_shader_parameter(parameter, value)


## Enter triggers on a non-zero channel (native set_enter_effect).
static func set_channel(channel: int, enter_type: int, exit_type: int) -> void:
	_channels[channel] = Vector2i(enter_type, exit_type)
	for cache_key: int in _cache:
		if (cache_key >> 3) == channel:
			_cache[cache_key].set_shader_parameter(&"gd_channel_enter", enter_type)
			_cache[cache_key].set_shader_parameter(&"gd_channel_exit", exit_type)
