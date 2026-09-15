// Native hot-path kernels for Godot Dash's large-level pipeline.
//
// Godot-facing orchestration intentionally remains callable from GDScript so
// editor builds without this optional GDExtension keep working. Android uses
// these C++ kernels for compressed GMD payloads, the per-object GD property
// parser, decoration ordering/bucketing, and spatial range calculations.

#include <godot_cpp/classes/camera2d.hpp>
#include <godot_cpp/classes/canvas_item.hpp>
#include <godot_cpp/classes/canvas_item_material.hpp>
#include <godot_cpp/classes/collision_shape2d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/shape2d.hpp>
#include <godot_cpp/classes/marshalls.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <godot_cpp/templates/hash_map.hpp>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iterator>
#include <map>
#include <numeric>
#include <set>
#include <utility>
#include <vector>

namespace godot {

// ---------------------------------------------------------------------------
// Native trigger effects.
//
// Every Geometry Dash trigger family this engine understands runs entirely in
// C++ once its record is registered: properties are parsed into a compact
// effect struct at load time, eased effects live in a small fade table ticked
// with the physics clock, and changes are applied through direct engine calls
// (transforms, modulate, process mode, ColorChannelData, camera, time scale).
// No GDScript and no per-trigger scene nodes execute for packed records, which
// is what keeps 5000-trigger effect levels playable. Records whose family has
// no native behaviour still emit the Interactable signal so scene-backed
// families (camera static, edge, end level) keep their components.
// ---------------------------------------------------------------------------

// Geometry Dash's editor grid is 30 units per cell; Godot Dash renders cells
// 128 pixels wide with +Y pointing down, hence the negated Y conversion.
static constexpr double GD_CELL_SIZE = 30.0;
static constexpr double ENGINE_CELL_SIZE = 128.0;
static constexpr double CELLS_TO_PX_X = ENGINE_CELL_SIZE / GD_CELL_SIZE;
static constexpr double CELLS_TO_PX_Y = -ENGINE_CELL_SIZE / GD_CELL_SIZE;
// PlayerCamera.DEFAULT_ZOOM; GD camera zoom percentages are relative to it.
static constexpr double PLAYER_CAMERA_DEFAULT_ZOOM = 0.8;
// A touch trigger's hitbox spans one GD cell, as does the player's icon
// hitbox: their centres overlap while both axes are within one cell.
static constexpr double TOUCH_HALF_EXTENT = ENGINE_CELL_SIZE;
// NOTE: no godot-cpp String/StringName may be constructed in a static
// initializer - the extension interface is only bound after the library is
// loaded - so every constant below is spelled out at its use site.

enum class TriggerEffectKind : int32_t {
	NONE = 0,      // registered, spawnable, but no behaviour (matches the inert generic families)
	MOVE,          // 901 Move
	ROTATE,        // 1346 Rotate
	SCALE,         // 2067 Scale
	ALPHA,         // 1007 Alpha
	TOGGLE,        // 1049 Toggle
	COLOR,         // 899 Color
	PULSE,         // 1006 Pulse (colour channel targets)
	SPAWN,         // 1268 Spawn
	STOP,          // 1616 Stop (cancel pending spawns for a group)
	HIDE,          // 1612 Hide Player
	SHOW,          // 1613 Show Player
	TIMEWARP,      // 1935 Timewarp
	CAMERA_ZOOM,   // 1913 Zoom Camera
	CAMERA_OFFSET, // 1916 Offset Camera
	CAMERA_ROTATE, // 2015 Rotate Camera
	SHAKE,         // 1520 Shake
	TELEPORT,      // 3022 Teleport
};

// GD easing index to curve, mirroring GMDConverter._easing_from_property:
// 0 linear; 1-3 quad; 4-6 elastic; 7-9 bounce; 10-12 expo; 13-15 sine;
// 16-18 back - each family as in-out / in / out. Unknown indices are linear.
static double ease_bounce_out(double t) {
	const double c1 = 7.5625;
	const double c2 = 2.75;
	if (t < 1.0 / c2) return c1 * t * t;
	if (t < 2.0 / c2) {
		const double x = t - 1.5 / c2;
		return c1 * x * x + 0.75;
	}
	if (t < 2.5 / c2) {
		const double x = t - 2.25 / c2;
		return c1 * x * x + 0.9375;
	}
	const double x = t - 2.625 / c2;
	return c1 * x * x + 0.984375;
}
static double ease_weight(int gd_easing, double t) {
	if (gd_easing <= 0 || gd_easing > 18) return Math::clamp(t, 0.0, 1.0);
	t = Math::clamp(t, 0.0, 1.0);
	const int family = (gd_easing - 1) / 3; // 0 quad .. 5 back
	const int mode = (gd_easing - 1) % 3;   // 0 in-out, 1 in, 2 out
	const bool in_out = mode == 0;
	const bool ease_in = mode != 2;
	switch (family) {
		case 0: { // quad
			if (in_out) return t < 0.5 ? 2.0 * t * t : 1.0 - Math::pow(-2.0 * t + 2.0, 2.0) / 2.0;
			return ease_in ? t * t : 1.0 - Math::pow(1.0 - t, 2.0);
		}
		case 1: { // elastic
			const double c4 = (2.0 * Math::PI) / 3.0;
			if (t == 0.0 || t == 1.0) return t;
			if (in_out) {
				return t < 0.5
					? -Math::pow(2.0, 20.0 * t - 10.0) * Math::sin((20.0 * t - 11.125) * c4) / 2.0
					: Math::pow(2.0, -20.0 * t + 10.0) * Math::sin((20.0 * t - 11.125) * c4) / 2.0 + 1.0;
			}
			return ease_in
				? -Math::pow(2.0, 10.0 * t - 10.0) * Math::sin((10.0 * t - 10.75) * c4)
				: Math::pow(2.0, -10.0 * t) * Math::sin((10.0 * t - 0.75) * c4) + 1.0;
		}
		case 2: { // bounce
			if (in_out) {
				return t < 0.5
					? (1.0 - ease_bounce_out(1.0 - 2.0 * t)) / 2.0
					: (1.0 + ease_bounce_out(2.0 * t - 1.0)) / 2.0;
			}
			return ease_in ? 1.0 - ease_bounce_out(1.0 - t) : ease_bounce_out(t);
		}
		case 3: { // expo
			if (t == 0.0) return 0.0;
			if (t == 1.0) return 1.0;
			if (in_out) {
				return t < 0.5
					? Math::pow(2.0, 20.0 * t - 10.0) / 2.0
					: (2.0 - Math::pow(2.0, -20.0 * t + 10.0)) / 2.0;
			}
			return ease_in ? Math::pow(2.0, 10.0 * t - 10.0) : 1.0 - Math::pow(2.0, -10.0 * t);
		}
		case 4: { // sine
			if (in_out) return -Math::cos(t * Math::PI) * 0.5 + 0.5;
			return ease_in ? 1.0 - Math::cos(t * Math::PI / 2.0) : Math::sin(t * Math::PI / 2.0);
		}
		default: { // back
			double c1 = 1.70158;
			const double c3 = c1 + 1.0;
			if (in_out) {
				c1 *= 1.525;
				return t < 0.5
					? (Math::pow(2.0 * t, 2.0) * ((c1 + 1.0) * 2.0 * t - c1)) / 2.0
					: (Math::pow(2.0 * t - 2.0, 2.0) * ((c1 + 1.0) * (2.0 * t - 2.0) + c1) + 2.0) / 2.0;
			}
			return ease_in
				? c3 * t * t * t - c1 * t * t
				: 1.0 + c3 * Math::pow(t - 1.0, 3.0) + c1 * Math::pow(t - 1.0, 2.0);
		}
	}
}

// Property readers. GD serialises every value as a string, including empty
// ones that must round-trip untouched (see the converter's lossless pairs).
static double prop_float(const Dictionary &properties, const char *key, double fallback) {
	const Variant value = properties.get(key, Variant());
	switch (value.get_type()) {
		case Variant::NIL:
			return fallback;
		case Variant::STRING:
			return String(value).to_float();
		default:
			return static_cast<double>(value);
	}
}
static int64_t prop_int(const Dictionary &properties, const char *key, int64_t fallback) {
	const Variant value = properties.get(key, Variant());
	switch (value.get_type()) {
		case Variant::NIL:
			return fallback;
		case Variant::STRING: {
			const String text = String(value).strip_edges();
			return text.is_valid_int() ? text.to_int() : fallback;
		}
		default:
			return static_cast<int64_t>(value);
	}
}

// A trigger's effect, parsed once at registration. Field meanings follow the
// converter's component arms so native execution is behaviour-identical.
struct TriggerEffect {
	TriggerEffectKind kind = TriggerEffectKind::NONE;
	double duration = 0.0;       // key 10
	int32_t easing = 0;          // key 30
	bool pulse_envelope = false; // any of keys 45/46/47 present (pulse style)
	double fade_in = 0.0;        // key 45
	double hold = 0.0;           // key 46
	double fade_out = 0.0;       // key 47
	std::vector<String> target_groups; // key 51, "g_N" names (dot/comma lists)
	String center_group;               // key 71, "g_N" (rotate/scale/teleport centre)
	Vector2 move_px;             // 901: keys 28/29 in pixels
	double degrees = 0.0;        // 1346: keys 68 + 69*360
	bool allow_self_rotation = true; // 1346: key 70 != "1"
	Vector2 scale_factor = Vector2(1.0, 1.0); // 2067: keys 150/151 (multiplied)
	double alpha = 1.0;          // 1007: key 35
	bool toggle_on = false;      // 1049: key 56 == "1"
	int32_t target_channel = -1; // 899: key 23; 1006: key 51 when 52 != "1"
	bool channel_is_level_color = false; // target is the level's own bg/ground/line
	Color color = Color(1.0f, 1.0f, 1.0f);
	bool has_color = false;      // 899/1006: any of keys 7/8/9 present
	int32_t copy_channel = 0;    // key 50
	bool copy_opacity = false;   // key 60
	double copy_hue = 0.0, copy_saturation = 0.0, copy_value = 0.0; // key 49 HSV string
	bool copy_saturation_additive = true, copy_value_additive = true;
	int32_t player_color = 0;    // 0 none, 1 key 15, 2 key 16
	double opacity = 1.0;        // 899: key 35
	bool blending = false;       // 899: key 17, the Blending checkbox
	double shake_strength = 5.0; // 1520: key 75
	double time_scale = 1.0;     // 1935: key 120
	double camera_zoom = 1.0;    // 1913: key 371 (GD zoom percentage)
	Vector2 camera_offset_px;    // 1916: keys 28/29 in pixels
	double camera_rotation_degrees = 0.0; // 2015: key 68
};

static std::vector<String> parse_group_list(const Dictionary &properties, const char *key) {
	std::vector<String> groups;
	const String raw = String(properties.get(key, String())).strip_edges().replace(",", ".");
	if (raw.is_empty()) return groups;
	const PackedStringArray parts = raw.split(".", false);
	for (int64_t i = 0; i < parts.size(); ++i) {
		const String part = String(parts[i]).strip_edges();
		if (!part.is_valid_int() || part.to_int() <= 0) continue;
		const String name = String("g_") + part;
		bool duplicate = false;
		for (const String &existing : groups) {
			if (existing == name) {
				duplicate = true;
				break;
			}
		}
		if (!duplicate) groups.push_back(name);
	}
	return groups;
}

// Parses a "h a s a v a sat_additive a val_additive" copied-colour HSV string
// (hue normalised from degrees), matching GMDConverter._hsv_values.
static bool parse_copy_hsv(const Dictionary &properties, TriggerEffect &effect) {
	const String raw = String(properties.get("49", String()));
	if (raw.is_empty()) return false;
	const PackedStringArray parts = raw.split("a", false);
	if (parts.size() < 3) return false;
	effect.copy_hue = String(parts[0]).to_float() / 360.0;
	effect.copy_saturation = String(parts[1]).to_float();
	effect.copy_value = String(parts[2]).to_float();
	effect.copy_saturation_additive = parts.size() > 3 && String(parts[3]) == "1";
	effect.copy_value_additive = parts.size() > 4 && String(parts[4]) == "1";
	return true;
}

// The copy-chain recursion budget, matching ColorChannelWatcher.COPY_ITERATIONS
// and GDRweb's CopyColor iteration guard: a chain longer than this (or a copy
// cycle) resolves to white instead of recursing forever.
constexpr int COPY_RESOLUTION_BUDGET = 8;

// Applies a channel's copy HSV adjustment (kS38 key 10 / trigger key 49, held
// on the ColorChannelData) to a resolved source colour, in Geometry Dash's
// additive and multiplicative slider modes. Mirrors
// ColorChannelWatcher._shift_copy_hsv and GDRweb's HSVShift.shiftColor.
static Color shift_copy_hsv(const Color &base, Object *data) {
	const double hue = static_cast<double>(data->get("copy_hue"));
	const double saturation = static_cast<double>(data->get("copy_saturation"));
	const double value = static_cast<double>(data->get("copy_value"));
	if (Math::is_zero_approx(hue) && Math::is_zero_approx(saturation) && Math::is_zero_approx(value))
		return base;
	const bool saturation_additive = static_cast<bool>(data->get("copy_saturation_additive"));
	const bool value_additive = static_cast<bool>(data->get("copy_value_additive"));
	double h = static_cast<double>(base.get_h()) + hue;
	h -= Math::floor(h);
	const double s = Math::clamp(
		saturation_additive ? static_cast<double>(base.get_s()) + saturation
							: static_cast<double>(base.get_s()) * saturation,
		0.0, 1.0);
	const double v = Math::clamp(
		value_additive ? static_cast<double>(base.get_v()) + value
					   : static_cast<double>(base.get_v()) * value,
		0.0, 1.0);
	return Color::from_hsv(static_cast<real_t>(h), static_cast<real_t>(s), static_cast<real_t>(v), base.a);
}

// The channel a colour trigger targeted when it carries no key 23: the legacy
// families each had a fixed target (GDRweb's COLOR_TRIGGER_IDS), and a bare
// modern 899 falls back to channel 1. 0 means "no default" (drop the trigger).
static int32_t legacy_color_trigger_channel(int64_t gd_id) {
	switch (gd_id) {
		case 29: return 1000;
		case 30: return 1001;
		case 104: return 1002;
		case 105: return 1004;
		case 744: return 1003;
		case 221: return 1;
		case 717: return 2;
		case 718: return 3;
		case 743: return 4;
		case 899: case 900: case 915: return 1;
		default: return 0;
	}
}

// Resolves where a colour/pulse trigger's target colour comes from. Geometry
// Dash always serialises the RGB keys of a hand-picked colour - even pure
// white - so their absence means the colour comes from a copied channel
// (key 50) or one of the player colours (keys 15/16). A trigger with none of
// those only fades opacity (KEEP). Mirrors the Color trigger converter arm.
static void parse_color_source(const Dictionary &properties, TriggerEffect &effect) {
	effect.opacity = Math::clamp(prop_float(properties, "35", 1.0), 0.0, 1.0);
	// The Blending checkbox is part of the trigger's target state: firing it
	// flips the channel additive (checked) or normal (unchecked). Effect
	// levels build their glow out of these mid-level flips.
	effect.blending = String(properties.get("17", String("0"))) == "1";
	const String copied = String(properties.get("50", String())).strip_edges();
	if (copied.is_valid_int() && copied.to_int() > 0) {
		effect.copy_channel = static_cast<int32_t>(copied.to_int());
		effect.copy_opacity = String(properties.get("60", String("0"))) == "1";
		parse_copy_hsv(properties, effect);
		return;
	}
	if (String(properties.get("15", String("0"))) == "1") {
		effect.player_color = 1;
		return;
	}
	if (String(properties.get("16", String("0"))) == "1") {
		effect.player_color = 2;
		return;
	}
	if (properties.has("7") || properties.has("8") || properties.has("9")) {
		effect.color = Color(
			static_cast<real_t>(prop_float(properties, "7", 255.0) / 255.0),
			static_cast<real_t>(prop_float(properties, "8", 255.0) / 255.0),
			static_cast<real_t>(prop_float(properties, "9", 255.0) / 255.0));
		effect.has_color = true;
	}
	// else KEEP: fade opacity only.
}

// Level colours the reserved channel IDs alias to; P1/P2/GLOW have no runtime
// representation (matching TargetColorChannelComponent.Type.LEVEL no-ops).
static String level_color_property_for_channel(int32_t channel) {
	if (channel == 1000) return String("background_color");
	if (channel == 1001 || channel == 1009) return String("ground_color");
	if (channel == 1002) return String("line_color");
	return String();
}

static TriggerEffect parse_trigger_effect(int64_t gd_id, const Dictionary &properties) {
	TriggerEffect effect;
	switch (gd_id) {
		case 901: effect.kind = TriggerEffectKind::MOVE; break;
		case 1346: effect.kind = TriggerEffectKind::ROTATE; break;
		case 2067: effect.kind = TriggerEffectKind::SCALE; break;
		case 1007: effect.kind = TriggerEffectKind::ALPHA; break;
		case 1049: effect.kind = TriggerEffectKind::TOGGLE; break;
		case 899:
		// Legacy colour-trigger families: each targeted a fixed channel
		// before key 23 existed (GDRweb's COLOR_TRIGGER_IDS).
		case 29: case 30: case 104: case 105: case 221: case 717:
		case 718: case 743: case 744: case 900: case 915:
			effect.kind = TriggerEffectKind::COLOR; break;
		case 1006: effect.kind = TriggerEffectKind::PULSE; break;
		case 1268: effect.kind = TriggerEffectKind::SPAWN; break;
		case 1616: effect.kind = TriggerEffectKind::STOP; break;
		case 1612: effect.kind = TriggerEffectKind::HIDE; break;
		case 1613: effect.kind = TriggerEffectKind::SHOW; break;
		case 1935: effect.kind = TriggerEffectKind::TIMEWARP; break;
		case 1913: effect.kind = TriggerEffectKind::CAMERA_ZOOM; break;
		case 1916: effect.kind = TriggerEffectKind::CAMERA_OFFSET; break;
		case 2015: effect.kind = TriggerEffectKind::CAMERA_ROTATE; break;
		case 1520: effect.kind = TriggerEffectKind::SHAKE; break;
		case 3022: effect.kind = TriggerEffectKind::TELEPORT; break;
		default: return effect; // inert
	}
	effect.duration = Math::max(0.0, prop_float(properties, "10", 0.0));
	effect.easing = static_cast<int32_t>(prop_int(properties, "30", 0));
	effect.target_groups = parse_group_list(properties, "51");
	const String center = String(properties.get("71", String())).strip_edges();
	if (center.is_valid_int() && center.to_int() > 0) effect.center_group = String("g_") + center;
	if (properties.has("45") || properties.has("46") || properties.has("47")) {
		effect.pulse_envelope = true;
		effect.fade_in = Math::max(0.0, prop_float(properties, "45", 0.0));
		effect.hold = Math::max(0.0, prop_float(properties, "46", 0.0));
		effect.fade_out = Math::max(0.0, prop_float(properties, "47", 0.0));
	}
	switch (effect.kind) {
		case TriggerEffectKind::MOVE:
		case TriggerEffectKind::CAMERA_OFFSET:
			// GD units to pixels; +Y in GD is up, +Y in Godot is down.
			effect.move_px = Vector2(
				static_cast<real_t>(prop_float(properties, "28", 0.0) * CELLS_TO_PX_X),
				static_cast<real_t>(prop_float(properties, "29", 0.0) * CELLS_TO_PX_Y));
			effect.camera_offset_px = effect.move_px;
			break;
		case TriggerEffectKind::ROTATE:
		case TriggerEffectKind::CAMERA_ROTATE:
			effect.degrees = prop_float(properties, "68", 0.0) + prop_float(properties, "69", 0.0) * 360.0;
			effect.camera_rotation_degrees = effect.degrees;
			effect.allow_self_rotation = String(properties.get("70", String("0"))) != "1";
			break;
		case TriggerEffectKind::SCALE:
			effect.scale_factor = Vector2(
				static_cast<real_t>(prop_float(properties, "150", 1.0)),
				static_cast<real_t>(prop_float(properties, "151", 1.0)));
			break;
		case TriggerEffectKind::ALPHA:
			effect.alpha = Math::clamp(prop_float(properties, "35", 1.0), 0.0, 1.0);
			break;
		case TriggerEffectKind::TOGGLE:
			effect.toggle_on = String(properties.get("56", String("0"))) == "1";
			break;
		case TriggerEffectKind::COLOR: {
			const String target = String(properties.get("23", String())).strip_edges();
			int32_t channel = 0;
			if (target.is_valid_int() && target.to_int() > 0) {
				channel = static_cast<int32_t>(target.to_int());
			} else {
				// No key 23: the legacy families each targeted a fixed
				// channel, and a bare 899 defaults to channel 1.
				channel = legacy_color_trigger_channel(gd_id);
				if (channel == 0) {
					effect.kind = TriggerEffectKind::NONE; // no target: nothing to fade
					break;
				}
			}
			const String level_property = level_color_property_for_channel(channel);
			if (!level_property.is_empty()) {
				effect.channel_is_level_color = true;
				effect.target_channel = channel;
			} else if (channel == 1005 || channel == 1006) {
				effect.kind = TriggerEffectKind::NONE; // player channels: no-op, like the component
				break;
			} else {
				effect.target_channel = channel;
			}
			parse_color_source(properties, effect);
			break;
		}
		case TriggerEffectKind::PULSE: {
			// Key 52 selects the target type: 0 = colour channel in key 51,
			// 1 = object group. Group pulses and HSV pulses need per-object
			// colour overrides this engine models differently, so they stay
			// inert until that changes.
			const String target_type = String(properties.get("52", String("0"))).strip_edges();
			const String hsv_mode = String(properties.get("48", String("0"))).strip_edges();
			const String target = String(properties.get("51", String())).strip_edges();
			if (target_type == "1" || hsv_mode == "1" || !target.is_valid_int() || target.to_int() <= 0) {
				effect.kind = TriggerEffectKind::NONE;
				break;
			}
			const int32_t channel = static_cast<int32_t>(target.to_int());
			const String level_property = level_color_property_for_channel(channel);
			if (!level_property.is_empty()) {
				effect.channel_is_level_color = true;
				effect.target_channel = channel;
			} else if (channel == 1005 || channel == 1006) {
				effect.kind = TriggerEffectKind::NONE;
				break;
			} else {
				effect.target_channel = channel;
			}
			parse_color_source(properties, effect);
			break;
		}
		case TriggerEffectKind::SHAKE:
			effect.shake_strength = Math::max(0.01, prop_float(properties, "75", 5.0));
			break;
		case TriggerEffectKind::TIMEWARP: {
			const double time_mod = prop_float(properties, "120", 1.0);
			effect.time_scale = Math::clamp(time_mod > 0.0 ? time_mod : 1.0, 0.01, 10.0);
			break;
		}
		case TriggerEffectKind::CAMERA_ZOOM:
			effect.camera_zoom = Math::max(0.01, prop_float(properties, "371", 1.0));
			break;
		default:
			break;
	}
	return effect;
}

// Packed trigger scheduler. One instance replaces thousands of Area2D broad-
// phase checks: trigger crossings, spawn/event delays, activation state,
// checkpoint snapshots AND the executed effect stay in C++.
class NativeTriggerRuntime : public RefCounted {
	GDCLASS(NativeTriggerRuntime, RefCounted)

	enum Flags : int32_t {
		SPAWN_ONLY = 1,
		TOUCH_ONLY = 2,
		MULTI_ACTIVATE = 4,
	};
	struct Record {
		double x = 0.0;
		double y = 0.0;
		ObjectID object;
		int64_t source_order = 0;
		int32_t flags = 0;
		int64_t gd_id = 0;
		Dictionary properties;
		TriggerEffect effect;
		bool activated = false;
	};
	struct Event {
		double due = 0.0;
		uint64_t sequence = 0;
		StringName group;
		ObjectID player;
	};
	// One running eased effect. Everything it needs was captured when the
	// trigger fired, mirroring the components' export_storage initial values:
	// restarting effects see the state at their own activation.
	struct Fade {
		size_t record_index = 0;
		ObjectID player;
		double start = 0.0;
		double prev_weight = 0.0;
		std::vector<ObjectID> members;        // union of the target groups
		std::vector<Vector2> initial_scales;  // 2067 multiplies from these
		std::vector<double> initial_alphas;   // 1007 fades from these
		ObjectID pivot;                       // rotate/scale centre (key 71)
		ObjectID channel_data;                // ColorChannelData resource
		String level_color_property;          // set for bg/ground/line targets
		Color from_color = Color(1.0f, 1.0f, 1.0f);
		Color to_color = Color(1.0f, 1.0f, 1.0f);
		double alpha_target = 1.0;            // resolved opacity (copied alpha included)
		double initial_hue = 0.0, initial_saturation = 0.0, initial_value = 0.0;
		double initial_intensity = 1.0, initial_alpha = 1.0;
		Vector2 initial_camera_zoom;
		Vector2 initial_camera_offset;
		double initial_camera_rotation = 0.0;
		double initial_time_scale = 1.0;
		double linear_eased_weight = 0.0;     // shake noise position
		Ref<FastNoiseLite> noise;
	};
	std::vector<Record> records;
	std::vector<size_t> x_order;
	// Direct group -> record index lookup makes spawn/event dispatch proportional
	// to the target group, not to every trigger in a 100k-object level. Hashed:
	// spawn-heavy levels look groups up for every scheduled event, and a
	// red-black tree walk with full String compares showed up in those profiles.
	HashMap<String, std::vector<size_t>> group_index;
	// Group membership captured at level finalisation: effect targets resolve
	// against the members present when the level starts, exactly when the
	// component path first queries them, without a SceneTree walk per fire.
	HashMap<String, std::vector<ObjectID>> member_index;
	// Colour channel table: "c_N" -> ColorChannelData resource.
	HashMap<String, ObjectID> channel_index;
	// Level/camera/Config objects for colour resolution and camera effects.
	ObjectID level_id;
	ObjectID camera_id;
	ObjectID config_id;
	// Records with the touch-only flag, in x order, for hitbox overlap checks.
	std::vector<size_t> touch_order;
	// Which touch records each player currently overlaps, so multi-activate
	// variants re-fire on a fresh touch instead of every physics frame.
	std::map<uint64_t, std::set<size_t>> touch_inside_players;
	// Players advanced this physics frame; touch checks need stationary and
	// vertically-moving players too, which x-crossing skips.
	std::vector<ObjectID> frame_players;
	// Running eased effects.
	std::vector<Fade> fades;
	// Min-heap ordered by due time/source sequence. Inserting a spawn event is
	// O(log n), replacing the old full stable_sort after every insertion.
	std::vector<Event> events;
	double clock = 0.0;
	uint64_t event_sequence = 0;
	bool index_dirty = false;
	// Bumped whenever container identity changes (clear/finalize/reset/
	// restore). Trigger activation can call back into GDScript — including
	// handlers that restart the level, which clears and re-registers every
	// record and frees the old buffers mid-scan. Every loop that holds
	// iterators or references across such a call-out captures this value
	// first and bails out as soon as it changes.
	uint64_t structure_epoch = 0;

	static bool event_later(const Event &a, const Event &b) {
		return a.due == b.due ? a.sequence > b.sequence : a.due > b.due;
	}

	void ensure_index() {
		if (!index_dirty) return;
		x_order.resize(records.size());
		std::iota(x_order.begin(), x_order.end(), 0);
		std::stable_sort(x_order.begin(), x_order.end(), [&](size_t a, size_t b) {
			if (records[a].x != records[b].x) return records[a].x < records[b].x;
			return records[a].source_order < records[b].source_order;
		});
		index_dirty = false;
	}

	// 2026-09-13 device tombstones (two builds, MTE): SEGV_ACCERR while the
	// lower_bound comparators read records[order[i]].x. The runtime object
	// and its vector metadata were provably alive both times (tick ran to
	// the scan), so the fault is in the data itself: either an index in an
	// order table is out of range, or a data buffer was freed. Validate the
	// tables before every scan; when one is broken, report the exact state
	// to logcat (ERR_PRINT is visible via adb) and rebuild it instead of
	// crashing. The two canary reads below put a freed records buffer on a
	// known line of the next tombstone instead of inside the binary search.
	bool index_table_valid(const std::vector<size_t> &table, const char *name) {
		if (table.empty()) return true;
		const size_t count = records.size();
		if (count == 0) {
			ERR_PRINT(String("[gdash_native] corrupt index table '") + name
				+ "': " + String::num_uint64(static_cast<uint64_t>(table.size()))
				+ " entries but records is empty"
				+ ", epoch=" + String::num_uint64(structure_epoch)
				+ ", frame=" + String::num_uint64(static_cast<uint64_t>(
					Engine::get_singleton()->get_process_frames()))
				+ "; rebuilding");
			return false;
		}
		// volatile so -O3 cannot elide the reads.
		volatile double canary = records[0].x;
		canary = records[count - 1].x;
		(void)canary;
		for (size_t position = 0; position < table.size(); ++position) {
			const size_t index = table[position];
			if (index >= count) {
				ERR_PRINT(String("[gdash_native] corrupt index table '") + name
					+ "': position " + String::num_uint64(static_cast<uint64_t>(position))
					+ " holds index " + String::num_uint64(static_cast<uint64_t>(index))
					+ ", records=" + String::num_uint64(static_cast<uint64_t>(count))
					+ ", table=" + String::num_uint64(static_cast<uint64_t>(table.size()))
					+ ", epoch=" + String::num_uint64(structure_epoch)
					+ ", frame=" + String::num_uint64(static_cast<uint64_t>(
						Engine::get_singleton()->get_process_frames()))
					+ ", records_ptr=" + String::num_uint64(static_cast<uint64_t>(
						reinterpret_cast<uintptr_t>(records.data())))
					+ ", table_ptr=" + String::num_uint64(static_cast<uint64_t>(
						reinterpret_cast<uintptr_t>(table.data())))
					+ "; rebuilding");
				return false;
			}
		}
		return true;
	}

	void rebuild_touch_order() {
		touch_order.clear();
		for (size_t index : x_order) {
			if (records[index].flags & TOUCH_ONLY) touch_order.push_back(index);
		}
	}

	void repair_index_tables() {
		if (!index_table_valid(x_order, "x_order")) {
			index_dirty = true;
			ensure_index();
		}
		if (!index_table_valid(touch_order, "touch_order")) rebuild_touch_order();
	}

	void activate(size_t index, Object *player, bool forced = false) {
		if (index >= records.size()) return;
		const uint64_t epoch = structure_epoch;
		const int32_t flags = records[index].flags;
		if (records[index].activated && !(flags & MULTI_ACTIVATE)) return;
		if (!forced && (flags & (SPAWN_ONLY | TOUCH_ONLY))) return;
		if (!player) return;
		// Families with a C++ effect run entirely here. Records without one
		// keep emitting the Interactable signal so scene-backed families
		// (camera static/edge, end level) execute their components.
		if (records[index].effect.kind == TriggerEffectKind::NONE) {
			Object *target = ObjectDB::get_instance(records[index].object);
			if (target) target->call("emit_signal", StringName("interacted"), player);
		} else {
			// Copy by value: execute_effect must not hold a reference into
			// records across its call-outs.
			const Record snapshot = records[index];
			execute_effect(snapshot, index, player);
		}
		// The signal or effect above can synchronously restart the level,
		// which clears and re-registers every record; finalize() frees the
		// old records buffer, so a reference captured before the call would
		// dangle. Write back through a fresh lookup, and only when the
		// runtime was not rebuilt (a rebuilt runtime starts with fresh
		// activation state).
		if (!(flags & MULTI_ACTIVATE) && index < records.size()
				&& structure_epoch == epoch) {
			records[index].activated = true;
		}
	}

	// ---------------------------------------------------------------
	// Effect execution. Immediate kinds run inline; eased kinds create a
	// fade entry whose state was captured at fire time.
	// ---------------------------------------------------------------

	std::vector<ObjectID> resolve_effect_members(const TriggerEffect &effect) const {
		std::vector<ObjectID> members;
		for (const String &group : effect.target_groups) {
			const auto found = member_index.find(group);
			if (found == member_index.end()) continue;
			members.insert(members.end(), found->value.begin(), found->value.end());
		}
		if (members.size() > 1) {
			// Multi-group targets must not double-apply on shared members; sort
			// and unique keeps this linearithmic for thousand-member groups.
			std::sort(members.begin(), members.end());
			members.erase(std::unique(members.begin(), members.end()), members.end());
		}
		return members;
	}

	Node2D *resolve_first_member(const String &group) const {
		if (group.is_empty()) return nullptr;
		const auto found = member_index.find(group);
		if (found == member_index.end()) return nullptr;
		for (ObjectID id : found->value) {
			Node2D *node = Object::cast_to<Node2D>(ObjectDB::get_instance(id));
			if (node) return node;
		}
		return nullptr;
	}

	static bool is_decoration_batch(Node *node) {
		if (!node) return false;
		const Ref<Script> script = node->get_script();
		return script.is_valid() && script->get_path() == String("res://src/DecorationBatch.gd");
	}

	// The live colour of a reserved channel ID.
	Color live_special_color(int32_t channel) const {
		Object *level = ObjectDB::get_instance(level_id);
		Object *config = ObjectDB::get_instance(config_id);
		const String property = level_color_property_for_channel(channel);
		if (!property.is_empty() && level) return level->get(property);
		if (!config) return Color(1.0f, 1.0f, 1.0f);
		if (channel == 1005) return config->get("primary_color");
		if (channel == 1006) return config->get("secondary_color");
		return config->get("glow_color");
	}
	Dictionary resolve_copied_channel(int32_t copy_id) const {
		Dictionary empty;
		if (copy_id <= 0) return empty;
		const String level_property = level_color_property_for_channel(copy_id);
		if (!level_property.is_empty()) {
			Object *level = ObjectDB::get_instance(level_id);
			if (!level) return empty;
			Dictionary result;
			result["color"] = level->get(level_property);
			result["alpha"] = 1.0;
			return result;
		}
		if (copy_id == 1005 || copy_id == 1006) {
			Object *config = ObjectDB::get_instance(config_id);
			if (!config) return empty;
			Dictionary result;
			result["color"] = config->get(copy_id == 1005 ? "primary_color" : "secondary_color");
			result["alpha"] = 1.0;
			return result;
		}
		Object *data = channel_lookup(copy_id);
		if (!data) return empty;
		// The source resolves through its own state - special link, ordinary
		// copy link or literal - exactly like ColorChannelWatcher does for
		// rendering, so a copy of a copy lands on the same colour the level
		// draws (GDRweb's recursive CopyColor evaluation).
		Dictionary result;
		result["color"] = resolve_channel_data_color(data, COPY_RESOLUTION_BUDGET);
		result["alpha"] = resolve_channel_data_alpha(data, COPY_RESOLUTION_BUDGET);
		return result;
	}

	// A channel data's fully resolved colour: its literal colour, its special
	// (level/player) colour, or - for an ordinary copy link - the source's
	// resolved colour with this channel's copy HSV applied on top. The budget
	// bounds copy chains the same way ColorChannelWatcher.COPY_ITERATIONS and
	// GDRweb's CopyColor iteration guard do. The alpha is deliberately not
	// folded into this colour: it travels separately through
	// resolve_channel_data_alpha, so a copy-opacity channel never gets the
	// source's alpha twice.
	Color resolve_channel_data_color(Object *data, int budget) const {
		if (budget <= 0) return Color(1.0f, 1.0f, 1.0f, 1.0f);
		if (static_cast<bool>(data->get("copy"))) {
			const int32_t special = static_cast<int32_t>(data->get("copied_channel"));
			switch (special) {
				case 0: return shift_copy_hsv(live_special_color(1000), data);
				case 1: return shift_copy_hsv(live_special_color(1001), data);
				case 2: return shift_copy_hsv(live_special_color(1002), data);
				case 3: return shift_copy_hsv(live_special_color(1005), data);
				case 4: return shift_copy_hsv(live_special_color(1006), data);
				default: return shift_copy_hsv(live_special_color(-1), data); // glow
			}
		}
		const int32_t link = static_cast<int32_t>(data->get("copied_channel_id"));
		if (link <= 0) return static_cast<Color>(data->get("color"));
		Color color;
		const String level_property = level_color_property_for_channel(link);
		if (!level_property.is_empty()) {
			Object *level = ObjectDB::get_instance(level_id);
			if (level) color = level->get(level_property);
			else color = Color(1.0f, 1.0f, 1.0f);
		} else if (link == 1005 || link == 1006) {
			Object *config = ObjectDB::get_instance(config_id);
			if (config) color = config->get(link == 1005 ? "primary_color" : "secondary_color");
			else color = Color(1.0f, 1.0f, 1.0f);
		} else {
			Object *source = channel_lookup(link);
			if (!source) return static_cast<Color>(data->get("color"));
			color = resolve_channel_data_color(source, budget - 1);
		}
		return shift_copy_hsv(color, data);
	}

	// The opacity a channel's members render with: its own, or the source's
	// when it copies opacity (kS38 key 17 / trigger key 60).
	double resolve_channel_data_alpha(Object *data, int budget) const {
		if (static_cast<bool>(data->get("copy"))) return 1.0;
		const int32_t link = static_cast<int32_t>(data->get("copied_channel_id"));
		if (link <= 0 || !static_cast<bool>(data->get("copy_opacity")))
			return static_cast<double>(data->get("alpha"));
		if (budget <= 0) return 1.0;
		const String level_property = level_color_property_for_channel(link);
		if (!level_property.is_empty() || link == 1005 || link == 1006) return 1.0;
		Object *source = channel_lookup(link);
		if (!source) return static_cast<double>(data->get("alpha"));
		return resolve_channel_data_alpha(source, budget - 1);
	}

	Object *channel_lookup(int32_t channel) const {
		const auto found = channel_index.find(String("c_") + String::num_int64(channel));
		if (found == channel_index.end()) return nullptr;
		return ObjectDB::get_instance(found->value);
	}

	// The colour this trigger fades its channel towards; copy and player
	// sources resolve at activation so they track later recolours, and a
	// copied opacity (key 60) replaces the trigger's own for this activation.
	Color resolve_source_color(const TriggerEffect &effect, const Color &keep, double &alpha_target) const {
		if (effect.has_color) return effect.color;
		if (effect.copy_channel > 0) {
			const Dictionary copied = resolve_copied_channel(effect.copy_channel);
			if (copied.is_empty()) return keep;
			if (effect.copy_opacity) alpha_target = copied["alpha"];
			const Color base = copied["color"];
			if (Math::is_zero_approx(effect.copy_hue) && Math::is_zero_approx(effect.copy_saturation)
					&& Math::is_zero_approx(effect.copy_value)) {
				return base;
			}
			double hue = static_cast<double>(base.get_h()) + effect.copy_hue;
			hue -= Math::floor(hue);
			const double saturation = effect.copy_saturation_additive
				? Math::clamp(static_cast<double>(base.get_s()) + effect.copy_saturation, 0.0, 1.0)
				: Math::clamp(static_cast<double>(base.get_s()) * effect.copy_saturation, 0.0, 1.0);
			const double value = effect.copy_value_additive
				? Math::clamp(static_cast<double>(base.get_v()) + effect.copy_value, 0.0, 1.0)
				: Math::clamp(static_cast<double>(base.get_v()) * effect.copy_value, 0.0, 1.0);
			return Color::from_hsv(
				static_cast<real_t>(hue), static_cast<real_t>(saturation),
				static_cast<real_t>(value), base.a);
		}
		if (effect.player_color == 1 || effect.player_color == 2) {
			return live_special_color(effect.player_color == 1 ? 1005 : 1006);
		}
		return keep;
	}

	void execute_effect(const Record &record, size_t index, Object *player) {
		const TriggerEffect &effect = record.effect;
		switch (effect.kind) {
			case TriggerEffectKind::SPAWN: {
				double delay = Math::max(0.0, prop_float(record.properties, "63", 0.0));
				const double delay_pm = Math::max(0.0, prop_float(record.properties, "556", 0.0));
				if (delay_pm > 0.0) {
					delay += delay_pm * (2.0 * (static_cast<double>(std::rand() % 10000) / 9999.0) - 1.0);
					delay = Math::max(0.0, delay);
				}
				for (const String &group : effect.target_groups) {
					schedule_group(StringName(group), delay, player);
				}
				break;
			}
			case TriggerEffectKind::STOP:
				// Cancels pending spawns targeting each group, cutting spawn loops.
				for (const String &group : effect.target_groups) {
					cancel_group_events(StringName(group));
				}
				break;
			case TriggerEffectKind::HIDE:
				set_player_visible(player, false);
				break;
			case TriggerEffectKind::SHOW:
				set_player_visible(player, true);
				break;
			case TriggerEffectKind::TOGGLE:
				apply_toggle(effect);
				break;
			case TriggerEffectKind::TELEPORT:
				apply_teleport(index, record, player);
				break;
			case TriggerEffectKind::MOVE:
			case TriggerEffectKind::ROTATE:
			case TriggerEffectKind::SCALE:
			case TriggerEffectKind::ALPHA:
			case TriggerEffectKind::COLOR:
			case TriggerEffectKind::PULSE:
			case TriggerEffectKind::TIMEWARP:
			case TriggerEffectKind::CAMERA_ZOOM:
			case TriggerEffectKind::CAMERA_OFFSET:
			case TriggerEffectKind::CAMERA_ROTATE:
			case TriggerEffectKind::SHAKE:
				start_fade(index, effect, player);
				break;
			default:
				break;
		}
	}

	static void set_player_visible(Object *player, bool visible) {
		CanvasItem *item = Object::cast_to<CanvasItem>(player);
		if (item) item->set_visible(visible);
	}

	void apply_toggle(const TriggerEffect &effect) {
		for (ObjectID id : resolve_effect_members(effect)) {
			Object *node = ObjectDB::get_instance(id);
			if (!node) continue;
			CanvasItem *item = Object::cast_to<CanvasItem>(node);
			if (item) item->set_visible(effect.toggle_on);
			// process_mode changes from the physics callback are deferred,
			// exactly like ToggleComponent's set_deferred.
			node->call_deferred("set_process_mode",
				static_cast<int64_t>(effect.toggle_on ? Node::PROCESS_MODE_INHERIT : Node::PROCESS_MODE_DISABLED));
		}
	}

	void apply_teleport(size_t index, const Record &record, Object *player) {
		Node2D *target = resolve_first_member(record.effect.center_group);
		if (!target && !record.effect.target_groups.empty()) {
			target = resolve_first_member(record.effect.target_groups[0]);
		}
		Node2D *player_node = Object::cast_to<Node2D>(player);
		// Device forensics 2026-09-13: the user sees a teleport interaction with
		// an unresolved target at the exact moment the process dies at Amethyst
		// level start. Log every native teleport attempt so the next logcat
		// capture timestamps it against the gdash-mem checkpoints.
		ERR_PRINT(String("[gdash_native] teleport attempt: record ")
			+ String::num_uint64(static_cast<uint64_t>(index))
			+ ", center_group='" + record.effect.center_group + "'"
			+ ", target_groups=" + String::num_uint64(static_cast<uint64_t>(record.effect.target_groups.size()))
			+ ", resolved=" + (target ? "yes" : "no")
			+ ", epoch=" + String::num_uint64(structure_epoch)
			+ ", frame=" + String::num_uint64(static_cast<uint64_t>(
				Engine::get_singleton()->get_process_frames())));
		if (target && player_node) {
			player_node->set_global_position(target->get_global_position());
		}
	}

	void start_fade(size_t index, const TriggerEffect &effect, Object *player) {
		// prevent_restart_during_animation: re-activating a record mid-fade is
		// ignored, like EasingComponent's default guard.
		const ObjectID player_id = ObjectID(player->get_instance_id());
		for (const Fade &existing : fades) {
			if (existing.record_index == index && existing.player == player_id) return;
		}
		Fade fade;
		fade.record_index = index;
		fade.player = player_id;
		fade.start = clock;
		switch (effect.kind) {
			case TriggerEffectKind::MOVE:
			case TriggerEffectKind::ROTATE:
				fade.members = resolve_effect_members(effect);
				fade.pivot = resolve_pivot(effect);
				break;
			case TriggerEffectKind::SCALE: {
				fade.members = resolve_effect_members(effect);
				fade.pivot = resolve_pivot(effect);
				fade.initial_scales.reserve(fade.members.size());
				for (ObjectID id : fade.members) {
					Node2D *node = Object::cast_to<Node2D>(ObjectDB::get_instance(id));
					fade.initial_scales.push_back(node ? node->get_global_scale() : Vector2(1.0f, 1.0f));
				}
				break;
			}
			case TriggerEffectKind::ALPHA: {
				fade.members = resolve_effect_members(effect);
				fade.initial_alphas.reserve(fade.members.size());
				for (ObjectID id : fade.members) {
					Object *node = ObjectDB::get_instance(id);
					double initial = 1.0;
					if (node) {
						if (is_decoration_batch(Object::cast_to<Node>(node))) {
							CanvasItem *item = Object::cast_to<CanvasItem>(node);
							initial = item ? item->get_modulate().a : 1.0;
						} else if (node->has_meta(StringName("hsv_watcher"))) {
							Object *watcher = node->get_meta(StringName("hsv_watcher"));
							initial = static_cast<double>(watcher->get("alpha"));
						}
					}
					fade.initial_alphas.push_back(initial);
				}
				break;
			}
			case TriggerEffectKind::COLOR:
			case TriggerEffectKind::PULSE: {
				if (!capture_color_target(effect, fade)) return; // missing channel: no-op, like the component
				break;
			}
			case TriggerEffectKind::TIMEWARP:
				fade.initial_time_scale = Engine::get_singleton()->get_time_scale();
				break;
			case TriggerEffectKind::CAMERA_ZOOM: {
				Camera2D *camera = Object::cast_to<Camera2D>(ObjectDB::get_instance(camera_id));
				if (!camera) return;
				fade.initial_camera_zoom = camera->get_zoom();
				break;
			}
			case TriggerEffectKind::CAMERA_OFFSET: {
				Object *camera = ObjectDB::get_instance(camera_id);
				if (!camera) return;
				fade.initial_camera_offset = camera->get("additional_offset");
				break;
			}
			case TriggerEffectKind::CAMERA_ROTATE: {
				Node2D *camera = Object::cast_to<Node2D>(ObjectDB::get_instance(camera_id));
				if (!camera) return;
				fade.initial_camera_rotation = camera->get_rotation_degrees();
				break;
			}
			case TriggerEffectKind::SHAKE:
				fade.noise.instantiate();
				if (fade.noise.is_valid()) fade.noise->set_seed(static_cast<int64_t>(std::rand()));
				break;
			default:
				break;
		}
		if (!effect.pulse_envelope && effect.duration <= 0.0) {
			// Instant triggers apply the full weight in one step, matching a
			// zero-length tween completing on its first frame.
			apply_fade(fade, effect, 1.0, 1.0, 0.0);
			return;
		}
		if (effect.pulse_envelope && effect.fade_in + effect.hold + effect.fade_out <= 0.0) {
			// A zero-length pulse envelope never leaves weight 0.
			return;
		}
		fades.push_back(std::move(fade));
	}

	ObjectID resolve_pivot(const TriggerEffect &effect) {
		Node2D *pivot = resolve_first_member(effect.center_group);
		return pivot ? ObjectID(pivot->get_instance_id()) : ObjectID();
	}

	// Captures the fade's channel target and from/to colours. Returns false
	// when the target does not exist (the component path no-ops then).
	bool capture_color_target(const TriggerEffect &effect, Fade &fade) {
		if (effect.channel_is_level_color) {
			Object *level = ObjectDB::get_instance(level_id);
			if (!level) return false;
			fade.level_color_property = level_color_property_for_channel(effect.target_channel);
			const Color current = level->get(fade.level_color_property);
			fade.from_color = current;
			double alpha_target = effect.opacity;
			fade.to_color = resolve_source_color(effect, current, alpha_target);
			fade.alpha_target = alpha_target;
			return true;
		}
		Object *data = channel_lookup(effect.target_channel);
		if (!data) return false;
		fade.channel_data = ObjectID(data->get_instance_id());
		const Color current = data->get("color");
		fade.from_color = current;
		const Array hsv = data->get("hsv_shift");
		if (hsv.size() >= 3) {
			fade.initial_hue = hsv[0];
			fade.initial_saturation = hsv[1];
			fade.initial_value = hsv[2];
		}
		fade.initial_intensity = data->get("intensity");
		fade.initial_alpha = data->get("alpha");
		double alpha_target = effect.opacity;
		fade.to_color = resolve_source_color(effect, current, alpha_target);
		fade.alpha_target = alpha_target;
		return true;
	}

	void apply_fade(const Fade &fade, const TriggerEffect &effect, double weight, double weight_delta, double delta) {
		if (Math::is_zero_approx(weight_delta) && effect.kind != TriggerEffectKind::SHAKE) return;
		switch (effect.kind) {
			case TriggerEffectKind::MOVE: {
				const Vector2 offset = effect.move_px * static_cast<real_t>(weight_delta);
				if (offset == Vector2()) break;
				for (ObjectID id : fade.members) {
					Node2D *node = Object::cast_to<Node2D>(ObjectDB::get_instance(id));
					if (node) node->set_global_position(node->get_global_position() + offset);
				}
				break;
			}
			case TriggerEffectKind::ROTATE: {
				const double delta_degrees = effect.degrees * weight_delta;
				Node2D *pivot = Object::cast_to<Node2D>(ObjectDB::get_instance(fade.pivot));
				for (ObjectID id : fade.members) {
					Node2D *node = Object::cast_to<Node2D>(ObjectDB::get_instance(id));
					if (!node) continue;
					// GD's "lock object rotation" keeps a member's own angle;
					// unchecked members also spin while orbiting the centre.
					if (effect.allow_self_rotation) {
						node->set_global_rotation_degrees(node->get_global_rotation_degrees() + delta_degrees);
					}
					if (pivot) {
						const Vector2 relative = node->get_global_position() - pivot->get_global_position();
						const Vector2 rotated = relative.rotated(
							static_cast<real_t>(Math::deg_to_rad(delta_degrees))) - relative;
						node->set_global_position(node->get_global_position() + rotated);
					}
				}
				break;
			}
			case TriggerEffectKind::SCALE: {
				Node2D *pivot = Object::cast_to<Node2D>(ObjectDB::get_instance(fade.pivot));
				for (size_t i = 0; i < fade.members.size(); ++i) {
					Node2D *node = Object::cast_to<Node2D>(ObjectDB::get_instance(fade.members[i]));
					if (!node) continue;
					const Vector2 initial = fade.initial_scales[i];
					const Vector2 scale_delta = (initial * effect.scale_factor - initial)
						* static_cast<real_t>(weight_delta);
					if (pivot) {
						const Vector2 current = node->get_global_scale();
						if (Math::is_zero_approx(current.x) || Math::is_zero_approx(current.y)) continue;
						const Vector2 relative = node->get_global_position() - pivot->get_global_position();
						const Vector2 position_delta = relative * ((current + scale_delta) / current) - relative;
						node->set_global_position(node->get_global_position() + position_delta);
					}
					node->set_global_scale(node->get_global_scale() + scale_delta);
					if (node->is_class("StaticBody2D") && scale_delta != Vector2()) {
						if (Node *absolute_size = node->get_node_or_null(NodePath("NinePatchSprite2DAbsoluteSize"))) {
							absolute_size->call("update_size");
						}
					}
				}
				break;
			}
			case TriggerEffectKind::ALPHA: {
				for (size_t i = 0; i < fade.members.size(); ++i) {
					Object *node = ObjectDB::get_instance(fade.members[i]);
					if (!node) continue;
					const double step = (effect.alpha - fade.initial_alphas[i]) * weight_delta;
					if (is_decoration_batch(Object::cast_to<Node>(node))) {
						CanvasItem *item = Object::cast_to<CanvasItem>(node);
						if (!item) continue;
						Color modulate = item->get_modulate();
						modulate.a += static_cast<real_t>(step);
						item->set_modulate(modulate);
					} else if (node->has_meta(StringName("hsv_watcher"))) {
						Object *watcher = node->get_meta(StringName("hsv_watcher"));
						watcher->set("alpha", static_cast<double>(watcher->get("alpha")) + step);
						watcher->call("update_color");
					}
				}
				break;
			}
			case TriggerEffectKind::COLOR:
			case TriggerEffectKind::PULSE:
				apply_color(fade, effect, weight, weight_delta);
				break;
			case TriggerEffectKind::TIMEWARP: {
				double time_scale = Engine::get_singleton()->get_time_scale();
				time_scale = Math::max(0.01, time_scale + (effect.time_scale - fade.initial_time_scale) * weight_delta);
				Engine::get_singleton()->set_time_scale(time_scale);
				break;
			}
			case TriggerEffectKind::CAMERA_ZOOM: {
				Camera2D *camera = Object::cast_to<Camera2D>(ObjectDB::get_instance(camera_id));
				if (!camera) break;
				const Vector2 target = Vector2(
					static_cast<real_t>(effect.camera_zoom * PLAYER_CAMERA_DEFAULT_ZOOM),
					static_cast<real_t>(effect.camera_zoom * PLAYER_CAMERA_DEFAULT_ZOOM));
				camera->set_zoom(camera->get_zoom() + (target - fade.initial_camera_zoom) * static_cast<real_t>(weight_delta));
				break;
			}
			case TriggerEffectKind::CAMERA_OFFSET: {
				Object *camera = ObjectDB::get_instance(camera_id);
				if (!camera) break;
				const Vector2 current = camera->get("additional_offset");
				camera->set("additional_offset",
					current + (effect.camera_offset_px - fade.initial_camera_offset) * static_cast<real_t>(weight_delta));
				break;
			}
			case TriggerEffectKind::CAMERA_ROTATE: {
				Node2D *camera = Object::cast_to<Node2D>(ObjectDB::get_instance(camera_id));
				if (!camera) break;
				camera->set_rotation_degrees(camera->get_rotation_degrees()
					+ static_cast<real_t>(effect.camera_rotation_degrees * weight_delta));
				break;
			}
			case TriggerEffectKind::SHAKE:
				apply_shake(fade, effect, weight);
				break;
			default:
				break;
		}
	}

	// Colour fades lerp sRGB per channel (GD's own fade behaviour) between the
	// captured channel colour and the resolved source. Channel-table targets
	// also fade HSV shift, intensity and opacity toward the trigger's values;
	// the watcher fan-out runs from the resource's changed signal, whose
	// native fast path recolours every bound object in C++.
	void apply_color(const Fade &fade, const TriggerEffect &effect, double weight, double weight_delta) {
		const Color color = fade.from_color.lerp(fade.to_color, static_cast<real_t>(weight));
		if (!fade.level_color_property.is_empty()) {
			Object *level = ObjectDB::get_instance(level_id);
			if (level) level->set(fade.level_color_property, color);
			return;
		}
		Object *data = ObjectDB::get_instance(fade.channel_data);
		if (!data) return;
		data->set("color", color);
		if (effect.kind == TriggerEffectKind::COLOR) {
			Array hsv = data->get("hsv_shift");
			if (hsv.size() >= 3) {
				const double hue = hsv[0];
				const double saturation = hsv[1];
				const double value = hsv[2];
				hsv.set(0, hue + (0.0 - fade.initial_hue) * weight_delta);
				hsv.set(1, saturation + (0.0 - fade.initial_saturation) * weight_delta);
				hsv.set(2, value + (0.0 - fade.initial_value) * weight_delta);
				data->set("hsv_shift", hsv);
			}
			data->set("intensity", static_cast<double>(data->get("intensity")) + (1.0 - fade.initial_intensity) * weight_delta);
			data->set("alpha", static_cast<double>(data->get("alpha")) + (fade.alpha_target - fade.initial_alpha) * weight_delta);
			// Blending is target state, not a faded value: it applies the moment
			// the trigger fires. The channel resource's changed signal fans out to
			// the watcher, which pushes the flip onto the channel's batches.
			data->set("blending", effect.blending);
			// The copy link and the link sever have different timings, so
			// the weight gate applies to the set only:
			// - Setting the link is target state (key 50): once the
			//   trigger's fade completes, the channel is re-pointed at its
			//   source and keeps following that source's later recolours.
			//   The link only goes live at completion (or instantly for
			//   duration-0 triggers, where the fire already carries weight
			//   1) so the fade towards the source stays visible - GDRweb
			//   mixes towards the live copy during the fade, and the
			//   finished link continues that.
			// - Severing the link happens the moment the trigger fires:
			//   an explicit colour or player target replaces the channel's
			//   CopyColor start value right away (GDRweb's track model), so
			//   the fade runs from the colour the channel showed at fire -
			//   its copy source's colour at that moment - to the literal
			//   target. Repeated severs while the fade ticks are idempotent.
			if (effect.copy_channel > 0 || effect.has_color || effect.player_color != 0) {
				if (effect.copy_channel > 0) {
					if (weight >= 1.0) {
						data->set("copied_channel_id", static_cast<int64_t>(effect.copy_channel));
						data->set("copy_opacity", effect.copy_opacity);
						data->set("copy_hue", effect.copy_hue);
						data->set("copy_saturation", effect.copy_saturation);
						data->set("copy_value", effect.copy_value);
						data->set("copy_saturation_additive", effect.copy_saturation_additive);
						data->set("copy_value_additive", effect.copy_value_additive);
					}
				} else {
					// An explicit colour or player target severs the link.
					data->set("copied_channel_id", static_cast<int64_t>(0));
				}
			}
		}
		data->emit_signal(StringName("changed"));
	}

	// Screen shake decays with the eased weight while the noise position keeps
	// advancing, matching CameraShakeComponent's STRENGTH easing at speed 100.
	// The noise cursor (linear_eased_weight) is advanced by the caller before
	// the snapshot is taken; this function only reads the fade.
	void apply_shake(const Fade &fade, const TriggerEffect &effect, double weight) {
		Object *camera = ObjectDB::get_instance(camera_id);
		if (!camera || fade.noise.is_null()) return;
		const double noise_position = fade.linear_eased_weight * 100.0 * 100.0;
		const double sample_strength = (1.0 - weight) * effect.shake_strength * 10.0;
		const Vector2 offset(
			static_cast<real_t>(fade.noise->get_noise_2d(noise_position, 0.0) * sample_strength),
			static_cast<real_t>(fade.noise->get_noise_2d(1.0, noise_position) * sample_strength));
		camera->set("shake_offset", offset);
	}

	void cancel_group_events(const StringName &group) {
		if (events.empty()) return;
		std::vector<Event> kept;
		kept.reserve(events.size());
		for (Event &event : events) {
			if (event.group != group) kept.push_back(std::move(event));
		}
		if (kept.size() == events.size()) return;
		events.swap(kept);
		std::make_heap(events.begin(), events.end(), event_later);
	}

	void check_touch_overlaps() {
		if (frame_players.empty() || touch_order.empty()) return;
		ensure_index();
		repair_index_tables();
		if (records.empty() || touch_order.empty()) return;
		// activate() below can reenter GDScript (an interacted handler that
		// restarts the level rebuilds records/touch_order and frees the old
		// buffers), which would leave the scan iterators and the `inside`
		// reference dangling. Bail out as soon as that happens; the next
		// physics frame re-evaluates the overlaps from scratch.
		const uint64_t epoch = structure_epoch;
		const size_t record_count = records.size();
		for (ObjectID player_object : frame_players) {
			if (structure_epoch != epoch) return;
			Node2D *player = Object::cast_to<Node2D>(ObjectDB::get_instance(player_object));
			if (!player) continue;
			const uint64_t player_id = static_cast<uint64_t>(player_object);
			const Vector2 position = player->get_global_position();
			std::set<size_t> &inside = touch_inside_players[player_id];
			// Multi-activate touch triggers re-fire on every fresh overlap:
			// forget records that left the player's X window in earlier frames
			// so returning to them counts as a new touch.
			// 2026-09-13 tombstones (five, four builds): MTE fault reading
			// records[idx] with idx just past records.size(). The order tables
			// are validated above, so the remaining unvalidated index source
			// in this function is this per-player `inside` set: an index
			// inserted while records was larger (a re-registration without a
			// clear) reads past the post-finalize shrink_to_fit allocation.
			// Drop stale entries instead of reading them, and report them.
			for (auto entry = inside.begin(); entry != inside.end(); ) {
				const size_t remembered = *entry;
				if (remembered >= record_count) {
					ERR_PRINT(String("[gdash_native] stale touch-inside entry ")
						+ String::num_uint64(static_cast<uint64_t>(remembered))
						+ " with records=" + String::num_uint64(static_cast<uint64_t>(record_count))
						+ ", set=" + String::num_uint64(static_cast<uint64_t>(inside.size()))
						+ ", player=" + String::num_uint64(player_id)
						+ ", epoch=" + String::num_uint64(structure_epoch)
						+ ", frame=" + String::num_uint64(static_cast<uint64_t>(
							Engine::get_singleton()->get_process_frames()))
						+ "; erasing");
					entry = inside.erase(entry);
					continue;
				}
				if (records[remembered].x < position.x - TOUCH_HALF_EXTENT
						|| records[remembered].x > position.x + TOUCH_HALF_EXTENT) {
					entry = inside.erase(entry);
				} else {
					++entry;
				}
			}
			// 2026-09-13 device forensics: five tombstones faulted reading
			// records[index] inside these searches with index one to four
			// past records.size(), even though the tables were validated on
			// entry. Rather than trust the table entries between validation
			// and use, every record read below goes through a bounds-checked
			// accessor: an out-of-range index is reported once per call and
			// sorts outside every player window instead of faulting.
			bool reported_bounds = false;
			const size_t bounds_count = records.size();
			auto touch_x = [&](size_t index) -> double {
				if (index < bounds_count) return records[index].x;
				if (!reported_bounds) {
					reported_bounds = true;
					ERR_PRINT(String("[gdash_native] out-of-range index ")
						+ String::num_uint64(static_cast<uint64_t>(index))
						+ " in touch scan, records=" + String::num_uint64(static_cast<uint64_t>(bounds_count))
						+ ", touch_order=" + String::num_uint64(static_cast<uint64_t>(touch_order.size()))
						+ ", epoch=" + String::num_uint64(structure_epoch)
						+ ", frame=" + String::num_uint64(static_cast<uint64_t>(
							Engine::get_singleton()->get_process_frames())));
				}
				return INFINITY;
			};
			auto first = std::lower_bound(touch_order.begin(), touch_order.end(),
				position.x - TOUCH_HALF_EXTENT,
				[&](double value, size_t index) { return value < touch_x(index); });
			for (auto it = first; it != touch_order.end(); ++it) {
				const size_t index = *it;
				if (index >= bounds_count) continue;
				if (records[index].x > position.x + TOUCH_HALF_EXTENT) break;
				const bool inside_now = Math::abs(records[index].y - position.y) <= TOUCH_HALF_EXTENT;
				const bool was_inside = inside.count(index) != 0;
				if (inside_now && !was_inside) {
					activate(index, player, true);
					if (structure_epoch != epoch) return;
					// activate() re-entered GDScript. A rebuild bumps the
					// epoch (handled above); an append-only re-registration
					// grows records without bumping it. Nothing registers
					// during play, so ANY size change here is unexpected:
					// report it and let the next physics frame re-validate
					// the whole scan instead of trusting stale iterators.
					if (records.size() != record_count) {
						ERR_PRINT(String("[gdash_native] records resized mid-scan: ")
							+ String::num_uint64(static_cast<uint64_t>(record_count))
							+ " -> " + String::num_uint64(static_cast<uint64_t>(records.size()))
							+ " after activating record "
							+ String::num_uint64(static_cast<uint64_t>(index))
							+ ", epoch=" + String::num_uint64(structure_epoch)
							+ ", frame=" + String::num_uint64(static_cast<uint64_t>(
								Engine::get_singleton()->get_process_frames()))
							+ "; aborting scan");
						return;
					}
				}
				if (inside_now) inside.insert(index);
				else if (was_inside) inside.erase(index);
			}
		}
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("clear"), &NativeTriggerRuntime::clear);
		ClassDB::bind_method(D_METHOD("register_trigger", "trigger", "x", "y", "flags", "source_order", "groups", "gd_id", "properties"), &NativeTriggerRuntime::register_trigger, DEFVAL(0.0));
		ClassDB::bind_method(D_METHOD("register_packed_trigger", "x", "y", "flags", "source_order", "groups", "gd_id", "properties"), &NativeTriggerRuntime::register_packed_trigger, DEFVAL(0.0));
		ClassDB::bind_method(D_METHOD("bind_context", "level", "camera", "config"), &NativeTriggerRuntime::bind_context);
		ClassDB::bind_method(D_METHOD("register_channel", "name", "data"), &NativeTriggerRuntime::register_channel);
		ClassDB::bind_method(D_METHOD("set_group_members", "group", "members"), &NativeTriggerRuntime::set_group_members);
		ClassDB::bind_method(D_METHOD("finalize"), &NativeTriggerRuntime::finalize);
		ClassDB::bind_method(D_METHOD("advance", "player", "previous_x", "current_x"), &NativeTriggerRuntime::advance);
		ClassDB::bind_method(D_METHOD("activate_touch", "record_index", "player"), &NativeTriggerRuntime::activate_touch);
		ClassDB::bind_method(D_METHOD("schedule_group", "group", "delay", "player"), &NativeTriggerRuntime::schedule_group);
		ClassDB::bind_method(D_METHOD("tick", "delta"), &NativeTriggerRuntime::tick);
		ClassDB::bind_method(D_METHOD("reset"), &NativeTriggerRuntime::reset);
		ClassDB::bind_method(D_METHOD("snapshot"), &NativeTriggerRuntime::snapshot);
		ClassDB::bind_method(D_METHOD("restore", "state"), &NativeTriggerRuntime::restore);
		ClassDB::bind_method(D_METHOD("trigger_count"), &NativeTriggerRuntime::trigger_count);
		ClassDB::bind_method(D_METHOD("active_fade_count"), &NativeTriggerRuntime::active_fade_count);
		ClassDB::bind_integer_constant(get_class_static(), "Flags", "SPAWN_ONLY", SPAWN_ONLY);
		ClassDB::bind_integer_constant(get_class_static(), "Flags", "TOUCH_ONLY", TOUCH_ONLY);
		ClassDB::bind_integer_constant(get_class_static(), "Flags", "MULTI_ACTIVATE", MULTI_ACTIVATE);
	}

public:
	void clear() {
		++structure_epoch;
		records.clear(); x_order.clear(); group_index.clear(); events.clear(); clock = 0.0;
		event_sequence = 0; index_dirty = false;
		fades.clear(); member_index.clear(); channel_index.clear(); touch_order.clear();
		touch_inside_players.clear(); frame_players.clear(); previous_positions.clear();
		level_id = ObjectID(); camera_id = ObjectID(); config_id = ObjectID();
	}
	int64_t register_trigger(Object *trigger, double x, double y, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		Record record;
		record.x = x;
		record.y = y;
		if (trigger) record.object = trigger->get_instance_id();
		record.flags = static_cast<int32_t>(flags); record.source_order = source_order;
		record.gd_id = gd_id; record.properties = properties;
		record.effect = parse_trigger_effect(gd_id, properties);
		const size_t index = records.size();
		for (int64_t i = 0; i < groups.size(); ++i)
			group_index[String(groups[i])].push_back(index);
		records.push_back(std::move(record)); index_dirty = true;
		return static_cast<int64_t>(index);
	}
	int64_t register_packed_trigger(double x, double y, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		return register_trigger(nullptr, x, y, flags, source_order, groups, gd_id, properties);
	}
	// Level, camera and Config objects the effects read/write.
	void bind_context(Object *level, Object *camera, Object *config) {
		if (level) level_id = level->get_instance_id();
		if (camera) camera_id = camera->get_instance_id();
		if (config) config_id = config->get_instance_id();
	}
	void register_channel(const String &name, Object *data) {
		if (data && !name.is_empty()) channel_index[name] = data->get_instance_id();
	}
	void set_group_members(const String &group, const Array &members) {
		std::vector<ObjectID> ids;
		ids.reserve(static_cast<size_t>(members.size()));
		for (int64_t i = 0; i < members.size(); ++i) {
			Object *member = members[i];
			if (member) ids.push_back(ObjectID(member->get_instance_id()));
		}
		member_index[group] = std::move(ids);
	}
	// Every group an effect may resolve against, for the membership snapshot
	// the owner Node takes at finalize time.
	std::vector<String> referenced_effect_groups() const {
		std::vector<String> groups;
		for (const Record &record : records) {
			for (const String &group : record.effect.target_groups) {
				bool duplicate = false;
				for (const String &existing : groups) {
					if (existing == group) {
						duplicate = true;
						break;
					}
				}
				if (!duplicate) groups.push_back(group);
			}
			const String &center = record.effect.center_group;
			if (!center.is_empty()) {
				bool duplicate = false;
				for (const String &existing : groups) {
					if (existing == center) {
						duplicate = true;
						break;
					}
				}
				if (!duplicate) groups.push_back(center);
			}
		}
		return groups;
	}
	void finalize() {
		++structure_epoch;
		ensure_index();
		records.shrink_to_fit();
		x_order.shrink_to_fit();
		for (auto &entry : group_index) {
			std::stable_sort(entry.value.begin(), entry.value.end(), [&](size_t a, size_t b) {
				return records[a].source_order < records[b].source_order;
				});
			entry.value.shrink_to_fit();
		}
		touch_order.clear();
		for (size_t index : x_order) {
			if (records[index].flags & TOUCH_ONLY) touch_order.push_back(index);
		}
		touch_order.shrink_to_fit();
	}
	void advance(Object *player, double previous_x, double current_x) {
		if (!player) return;
		// Touch overlap checks run from tick() for every player advanced this
		// frame, including ones that did not move on X.
		frame_players.push_back(ObjectID(player->get_instance_id()));
		if (Math::is_equal_approx(previous_x, current_x)) return;
		ensure_index();
		repair_index_tables();
		if (x_order.empty()) return;
		// activate() below can reenter GDScript and rebuild the runtime,
		// freeing x_order/records; the scan iterators would dangle.
		const uint64_t epoch = structure_epoch;
		// Bounds-checked accessor for the same reason as the touch scan:
		// tombstones showed table entries one to four past records.size()
		// surviving entry validation. Reported once per call; an out-of-range
		// entry sorts outside the crossing range instead of faulting.
		bool reported_bounds = false;
		const size_t bounds_count = records.size();
		auto order_x = [&](size_t index) -> double {
			if (index < bounds_count) return records[index].x;
			if (!reported_bounds) {
				reported_bounds = true;
				ERR_PRINT(String("[gdash_native] out-of-range index ")
					+ String::num_uint64(static_cast<uint64_t>(index))
					+ " in crossing scan, records=" + String::num_uint64(static_cast<uint64_t>(bounds_count))
					+ ", x_order=" + String::num_uint64(static_cast<uint64_t>(x_order.size()))
					+ ", epoch=" + String::num_uint64(structure_epoch)
					+ ", frame=" + String::num_uint64(static_cast<uint64_t>(
						Engine::get_singleton()->get_process_frames())));
			}
			return INFINITY;
		};
		auto index_before_value = [&](size_t index, double value) { return order_x(index) < value; };
		if (current_x > previous_x) {
			// (previous_x, current_x] in O(log n + crossed), rather than scanning
			// every trigger from the start once per player and physics frame.
			auto first = std::upper_bound(x_order.begin(), x_order.end(), previous_x,
				[&](double value, size_t index) { return value < order_x(index); });
			auto last = std::upper_bound(x_order.begin(), x_order.end(), current_x,
				[&](double value, size_t index) { return value < order_x(index); });
			for (auto it = first; it != last; ++it) {
				if (structure_epoch != epoch) return;
				activate(*it, player);
			}
		} else {
			// [current_x, previous_x), preserving descending spatial/source order.
			auto first = std::lower_bound(x_order.begin(), x_order.end(), current_x, index_before_value);
			auto last = std::lower_bound(x_order.begin(), x_order.end(), previous_x, index_before_value);
			for (auto it = std::make_reverse_iterator(last); it != std::make_reverse_iterator(first); ++it) {
				if (structure_epoch != epoch) return;
				activate(*it, player);
			}
		}
	}
	// Per-player x tracking lives inside the RefCounted runtime, not the
	// owner Node: an interacted handler can free the owner Node synchronously,
	// and the physics step holds a local Ref to this object, so state owned
	// here stays alive for the whole step no matter what the scene does.
	std::map<uint64_t, double> previous_positions;

	void advance_player(Object *player) {
		Node2D *node = Object::cast_to<Node2D>(player);
		if (!node) return;
		const uint64_t id = static_cast<uint64_t>(player->get_instance_id());
		const double x = node->get_global_position().x;
		auto previous = previous_positions.find(id);
		const double from = previous != previous_positions.end() ? previous->second : x;
		// Update the tracking map before advance(): activate() inside it can
		// re-enter GDScript and retire this runtime for the rest of the step.
		previous_positions[id] = x;
		// 2026-09-13 device forensics: a portal at the Amethyst spawn
		// teleports the player on the first physics frame, and treating the
		// jump as a crossing activated the ENTIRE level's trigger range in
		// one shot (stop, end-level and restart handlers included), which is
		// what lit up the level-start crashes. Portals must not activate the
		// triggers they skip over: any jump larger than any legitimate speed
		// registers the player for touch checks at the new position but
		// fires no crossings. Physics runs at a fixed rate, so a real player
		// moves ~tens of pixels per step; 1024 is far above that and far
		// below any portal jump.
		constexpr double TELEPORT_JUMP_PX = 1024.0;
		if (Math::abs(x - from) > TELEPORT_JUMP_PX) {
			advance(player, x, x);
		} else {
			advance(player, from, x);
		}
	}
	void activate_touch(int64_t record_index, Object *player) { activate(static_cast<size_t>(record_index), player, true); }
	void schedule_group(const StringName &group, double delay, Object *player) {
		if (!player || group.is_empty()) return;
		Event event;
		event.due = clock + std::max(0.0, delay);
		event.sequence = event_sequence++;
		event.group = group;
		event.player = player->get_instance_id();
		events.push_back(std::move(event));
		std::push_heap(events.begin(), events.end(), event_later);
	}
	void tick(double delta) {
		clock += std::max(0.0, delta);
		int64_t dispatched = 0;
		// activate() inside the dispatch loop can reenter GDScript and
		// rebuild this runtime; stop dispatching in that case (pending
		// events of a rebuilt runtime belong to its own timeline).
		const uint64_t epoch = structure_epoch;
		while (structure_epoch == epoch && !events.empty() && events.front().due <= clock && dispatched < 10000) {
			std::pop_heap(events.begin(), events.end(), event_later);
			const Event event = std::move(events.back());
			events.pop_back();
			Object *player = ObjectDB::get_instance(event.player);
			if (player) {
				auto group = group_index.find(String(event.group));
				if (group != group_index.end()) {
					for (size_t index : group->value) activate(index, player, true);
				}
			}
			++dispatched;
		}
		check_touch_overlaps();
		frame_players.clear();
		for (size_t i = 0; i < fades.size(); ) {
			const uint64_t fade_epoch = structure_epoch;
			if (fades[i].record_index >= records.size()) {
				// Defensive: state is inconsistent (should not happen; a
				// rebuild clears fades too). Drop the corrupt entry.
				fades.erase(fades.begin() + static_cast<std::ptrdiff_t>(i));
				continue;
			}
			const TriggerEffect effect = records[fades[i].record_index].effect;
			double weight = 0.0;
			bool finished = false;
			const double t = clock - fades[i].start;
			if (effect.pulse_envelope) {
				// Pulse envelope: eased fade in, hold at full, eased fade out.
				if (t < effect.fade_in) {
					weight = ease_weight(effect.easing, t / effect.fade_in);
				} else if (t < effect.fade_in + effect.hold) {
					weight = 1.0;
				} else if (t < effect.fade_in + effect.hold + effect.fade_out) {
					weight = 1.0 - ease_weight(effect.easing,
						(t - effect.fade_in - effect.hold) / effect.fade_out);
				} else {
					weight = 0.0;
					finished = true;
				}
			} else if (t >= effect.duration) {
				weight = 1.0;
				finished = true;
			} else {
				weight = ease_weight(effect.easing, t / effect.duration);
			}
			const double weight_delta = weight - fades[i].prev_weight;
			// Persist progress before any call out into the scene: a
			// reentrant rebuild clears fades while apply_fade is still
			// running. The shake noise cursor advances here too (matching
			// the old in-apply_shake behaviour, camera present and noise
			// valid) so the snapshot below already carries it.
			fades[i].prev_weight = weight;
			if (effect.kind == TriggerEffectKind::SHAKE
					&& ObjectDB::get_instance(camera_id)
					&& !fades[i].noise.is_null()) {
				fades[i].linear_eased_weight += delta
					/ (effect.duration > 0.0 ? effect.duration : 1.0);
			}
			// Snapshot by value: apply_fade reaches back into GDScript
			// (update_size/update_color/channel changed signals) which can
			// rebuild this runtime and free fades/records mid-application.
			const Fade fade = fades[i];
			apply_fade(fade, effect, weight, weight_delta, delta);
			if (structure_epoch != fade_epoch) return;
			if (finished) {
				fades.erase(fades.begin() + static_cast<std::ptrdiff_t>(i));
				continue;
			}
			++i;
		}
	}
	void reset() {
		++structure_epoch;
		for (Record &record : records) record.activated = false;
		events.clear(); clock = 0.0; event_sequence = 0;
		// Restarts rebuild object transforms from level data; running fades
		// must not keep mutating mid-animation state. The respawn jump is a
		// teleport, not a crossing: forget the tracked positions so the
		// first frame after a restart fires no crossings.
		fades.clear();
		touch_inside_players.clear();
		frame_players.clear();
		previous_positions.clear();
	}
	Dictionary snapshot() const {
		Dictionary state; PackedByteArray active;
		active.resize(records.size());
		for (size_t i = 0; i < records.size(); ++i) active.set(i, records[i].activated ? 1 : 0);
		state["active"] = active; state["clock"] = clock;
		return state;
	}
	void restore(const Dictionary &state) {
		++structure_epoch;
		const PackedByteArray active = state.get("active", PackedByteArray());
		for (size_t i = 0; i < records.size(); ++i) records[i].activated = i < static_cast<size_t>(active.size()) && active[i] != 0;
		clock = state.get("clock", 0.0); events.clear(); fades.clear();
		frame_players.clear(); previous_positions.clear();
	}
	int64_t trigger_count() const { return static_cast<int64_t>(records.size()); }
	int64_t active_fade_count() const { return static_cast<int64_t>(fades.size()); }
};

struct DecorationCullJob {
	uint64_t renderer_id = 0;
	Transform2D from_screen;
	Vector2 screen_size;
	double radius = 0.0;
	double cell_size = 256.0;
	int64_t first = 0;
	int64_t last = -1;
	int64_t top = 0;
	int64_t bottom = -1;
};
static std::vector<DecorationCullJob> decoration_cull_jobs;

// WorkerThreadPool invokes one element per renderer and automatically spreads
// the group across the engine's worker pool (not a hard-coded two-thread cap).
// Jobs contain only copied transforms/numbers: workers never touch SceneTree,
// ObjectDB, textures, RIDs, or RenderingServer.
class NativeDecorationCullWorker : public RefCounted {
	GDCLASS(NativeDecorationCullWorker, RefCounted)
protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("compute", "index"), &NativeDecorationCullWorker::compute);
	}
public:
	void compute(int64_t index) {
		if (index < 0 || index >= static_cast<int64_t>(decoration_cull_jobs.size())) return;
		DecorationCullJob &job = decoration_cull_jobs[static_cast<size_t>(index)];
		Rect2 local_view(job.from_screen.xform(Vector2()), Vector2());
		local_view = local_view.expand(job.from_screen.xform(Vector2(job.screen_size.x, 0.0)));
		local_view = local_view.expand(job.from_screen.xform(job.screen_size));
		local_view = local_view.expand(job.from_screen.xform(Vector2(0.0, job.screen_size.y)));
		// One additional cell covers camera movement while this asynchronous
		// result is in flight, preventing one-frame streaming gaps.
		local_view = local_view.grow(job.radius + job.cell_size);
		job.first = static_cast<int64_t>(std::floor(local_view.position.x / job.cell_size));
		job.last = static_cast<int64_t>(std::floor(local_view.get_end().x / job.cell_size));
		job.top = static_cast<int64_t>(std::floor(local_view.position.y / job.cell_size));
		job.bottom = static_cast<int64_t>(std::floor(local_view.get_end().y / job.cell_size));
	}
};

// Decoration renderers register in a native global list. NativeLevelRuntime
// snapshots thread-unsafe scene transforms on the main thread, then delegates
// all spatial range math to WorkerThreadPool.
static void decoration_coordinator_enter();
static void decoration_coordinator_exit();
static void update_registered_decoration_renderers(double delta);
static Dictionary registered_decoration_stats();

// Native owner for the packed runtime. Besides being the migration point for
// rendering/collision stores, this removes the last per-physics-frame
// GDScript->GDExtension calls: player discovery, crossing queries and event
// clock advancement happen in one C++ notification.
class NativeLevelRuntime : public Node {
	GDCLASS(NativeLevelRuntime, Node)

	Ref<NativeTriggerRuntime> triggers;
	Node *level_manager = nullptr;
	Node *context_level = nullptr;
	bool coordinates_rendering = false;

	// Effect targets resolve against the group members present when the level
	// starts. The runtime is a RefCounted without tree access, so the owner
	// Node snapshots membership here: once at finalize, never per fire.
	void snapshot_effect_groups() {
		SceneTree *tree = get_tree();
		if (!tree) return;
		for (const String &group : triggers->referenced_effect_groups()) {
			Array members;
			const Array nodes = tree->get_nodes_in_group(StringName(group));
			for (int64_t i = 0; i < nodes.size(); ++i) {
				Node2D *candidate = Object::cast_to<Node2D>(nodes[i]);
				// Nodes of other levels can still be in the tree while their
				// queue_free resolves; only this level's objects are targets.
				if (candidate && (!context_level || context_level->is_ancestor_of(candidate))) {
					members.append(candidate);
				}
			}
			triggers->set_group_members(group, members);
		}
	}

	static void ensure_visible(Object *object) {
		CanvasItem *item = Object::cast_to<CanvasItem>(object);
		if (item) item->set_visible(true);
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("clear"), &NativeLevelRuntime::clear);
		ClassDB::bind_method(D_METHOD("register_trigger", "trigger", "x", "y", "flags", "source_order", "groups", "gd_id", "properties"), &NativeLevelRuntime::register_trigger, DEFVAL(0.0));
		ClassDB::bind_method(D_METHOD("register_packed_trigger", "x", "y", "flags", "source_order", "groups", "gd_id", "properties"), &NativeLevelRuntime::register_packed_trigger, DEFVAL(0.0));
		ClassDB::bind_method(D_METHOD("bind_context", "level", "camera", "config"), &NativeLevelRuntime::bind_context);
		ClassDB::bind_method(D_METHOD("register_channel", "name", "data"), &NativeLevelRuntime::register_channel);
		ClassDB::bind_method(D_METHOD("finalize"), &NativeLevelRuntime::finalize);
		ClassDB::bind_method(D_METHOD("reset"), &NativeLevelRuntime::reset);
		ClassDB::bind_method(D_METHOD("snapshot"), &NativeLevelRuntime::snapshot);
		ClassDB::bind_method(D_METHOD("restore", "state"), &NativeLevelRuntime::restore);
		ClassDB::bind_method(D_METHOD("trigger_count"), &NativeLevelRuntime::trigger_count);
		ClassDB::bind_method(D_METHOD("active_fade_count"), &NativeLevelRuntime::active_fade_count);
		ClassDB::bind_method(D_METHOD("render_stats"), &NativeLevelRuntime::render_stats);
	}

	void _notification(int what) {
		if (what == Node::NOTIFICATION_ENTER_TREE && !coordinates_rendering) {
			coordinates_rendering = true;
			decoration_coordinator_enter();
			return;
		}
		if (what == Node::NOTIFICATION_EXIT_TREE && coordinates_rendering) {
			coordinates_rendering = false;
			decoration_coordinator_exit();
			return;
		}
		if (what == Node::NOTIFICATION_READY) {
			SceneTree *tree = Object::cast_to<SceneTree>(Engine::get_singleton()->get_main_loop());
			if (tree) level_manager = tree->get_root()->get_node_or_null(NodePath("LevelManager"));
			set_process(true);
			set_physics_process(true);
			return;
		}
		if (what == Node::NOTIFICATION_PROCESS) {
			update_registered_decoration_renderers(get_process_delta_time());
			return;
		}
		if (what != Node::NOTIFICATION_PHYSICS_PROCESS || !level_manager || !triggers.is_valid()) return;
		if (!static_cast<bool>(level_manager->get("level_playing"))) return;
		// 2026-09-13 device forensics: an interacted handler reached from
		// advance_player()/tick() can free this node synchronously (an
		// immediate free() of an ancestor in the scene). Snapshot every
		// member this step needs before the first reentry point, and hold a
		// strong local Ref so the runtime outlives the whole step even if
		// this node's destructor releases the member reference with tick()
		// still on the stack. Nothing below touches `this` after the first
		// advance_player call.
		Node *const manager = level_manager;
		Ref<NativeTriggerRuntime> const runtime = triggers;
		const double physics_delta = get_physics_process_delta_time();
		Variant main_value = manager->get("player");
		Object *main_player = main_value;
		runtime->advance_player(main_player);
		// advance_player can reenter GDScript (a trigger activation that
		// restarts the level replaces the dual icons), so re-read the array
		// every iteration instead of holding one snapshot of Object pointers.
		for (int64_t i = 0; ; ++i) {
			const Array duals = manager->get("player_duals");
			if (i >= duals.size()) break;
			runtime->advance_player(duals[i]);
		}
		runtime->tick(physics_delta);
	}

public:
	NativeLevelRuntime() { triggers.instantiate(); }

	void clear() { triggers->clear(); context_level = nullptr; }
	int64_t register_trigger(Object *trigger, double x, double y, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		return triggers->register_trigger(trigger, x, y, flags, source_order, groups, gd_id, properties);
	}
	int64_t register_packed_trigger(double x, double y, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		return triggers->register_packed_trigger(x, y, flags, source_order, groups, gd_id, properties);
	}
	void bind_context(Object *level, Object *camera, Object *config) {
		Node *level_node = Object::cast_to<Node>(level);
		if (level_node) context_level = level_node;
		triggers->bind_context(level, camera, config);
	}
	void register_channel(const String &name, Object *data) { triggers->register_channel(name, data); }
	void finalize() {
		snapshot_effect_groups();
		triggers->finalize();
	}
	void reset() {
		triggers->reset();
		// A Hide Player trigger must not survive the restart: Geometry Dash
		// always respawns a visible icon.
		if (level_manager) {
			ensure_visible(level_manager->get("player"));
			const Array duals = level_manager->get("player_duals");
			for (int64_t i = 0; i < duals.size(); ++i) ensure_visible(duals[i]);
		}
	}
	Dictionary snapshot() const { return triggers->snapshot(); }
	void restore(const Dictionary &state) { triggers->restore(state); }
	int64_t trigger_count() const { return triggers->trigger_count(); }
	int64_t active_fade_count() const { return triggers->active_fade_count(); }
	Dictionary render_stats() const { return registered_decoration_stats(); }
};

class GdashNative : public RefCounted {
	GDCLASS(GdashNative, RefCounted)

	static String standard_base64(String value) {
		value = value.replace("-", "+").replace("_", "/");
		while ((value.length() & 3) != 0) {
			value += "=";
		}
		return value;
	}

	static String url_base64(String value) {
		return value.replace("+", "-").replace("/", "_").replace("=", "");
	}

	static uint32_t crc32(const PackedByteArray &bytes) {
		uint32_t crc = 0xffffffffU;
		for (int64_t i = 0; i < bytes.size(); ++i) {
			crc ^= static_cast<uint8_t>(bytes[i]);
			for (int bit = 0; bit < 8; ++bit) {
				crc = (crc >> 1U) ^ (0xedb88320U & static_cast<uint32_t>(-(static_cast<int32_t>(crc & 1U))));
			}
		}
		return crc ^ 0xffffffffU;
	}

	static PackedByteArray wrap_gzip(const PackedByteArray &raw, const PackedByteArray &deflated) {
		PackedByteArray out;
		out.resize(10 + deflated.size() + 8);
		const uint8_t header[10] = {0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3};
		for (int i = 0; i < 10; ++i) out.set(i, header[i]);
		for (int64_t i = 0; i < deflated.size(); ++i) out.set(10 + i, deflated[i]);
		const uint32_t checksum = crc32(raw);
		const uint32_t size = static_cast<uint32_t>(raw.size());
		const int64_t trailer = 10 + deflated.size();
		for (int i = 0; i < 4; ++i) {
			out.set(trailer + i, (checksum >> (8 * i)) & 0xff);
			out.set(trailer + 4 + i, (size >> (8 * i)) & 0xff);
		}
		return out;
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("build_string"), &GdashNative::build_string);
		ClassDB::bind_method(D_METHOD("version"), &GdashNative::version);
		ClassDB::bind_method(D_METHOD("add", "a", "b"), &GdashNative::add);
		ClassDB::bind_method(D_METHOD("parse_gd_pairs", "chunk"), &GdashNative::parse_gd_pairs);
		ClassDB::bind_method(D_METHOD("parse_online_level", "level_string"), &GdashNative::parse_online_level);
		ClassDB::bind_method(D_METHOD("decode_level_string", "encoded"), &GdashNative::decode_level_string);
		ClassDB::bind_method(D_METHOD("encode_level_string", "plain"), &GdashNative::encode_level_string);
		ClassDB::bind_method(D_METHOD("sort_decoration_indices", "z_orders", "draw_orders", "texture_ids"), &GdashNative::sort_decoration_indices);
		ClassDB::bind_method(D_METHOD("build_x_buckets", "origins", "bucket_width"), &GdashNative::build_x_buckets);
		ClassDB::bind_method(D_METHOD("visible_bucket_keys", "keys", "first", "last"), &GdashNative::visible_bucket_keys);
		ClassDB::bind_method(D_METHOD("commit_collision_shapes", "body", "source", "descriptors"), &GdashNative::commit_collision_shapes);
		ClassDB::bind_method(D_METHOD("reenable_collision_shapes", "container"), &GdashNative::reenable_collision_shapes);
	}

public:
	String build_string() const {
		return String("gdash_native 1.10.0 / native animation / spatial retained RIDs / worker culling / native color channels / api 4.7");
	}
	int64_t version() const { return 20; }
	int64_t add(int64_t a, int64_t b) const { return a + b; }

	// Geometry Dash values are allowed to be empty. String::split(..., false)
	// discarded those fields and shifted every following key onto the previous
	// value, silently changing trigger semantics. Scan pairs directly so empty
	// values retain their position and large levels avoid a temporary token
	// array for every object.
	Dictionary parse_pairs(const String &chunk, int64_t *odd_fields = nullptr,
			int64_t *duplicate_keys = nullptr, int64_t *empty_keys = nullptr) const {
		Dictionary result;
		String key;
		bool expecting_key = true;
		int64_t token_start = 0;
		const int64_t length = chunk.length();
		for (int64_t cursor = 0; cursor <= length; ++cursor) {
			if (cursor < length && chunk[cursor] != ',') continue;
			const String token = chunk.substr(token_start, cursor - token_start);
			token_start = cursor + 1;
			if (expecting_key) {
				key = token.strip_edges();
				expecting_key = false;
			} else {
				if (key.is_empty()) {
					if (empty_keys) ++*empty_keys;
				} else {
					if (result.has(key) && duplicate_keys) ++*duplicate_keys;
					// Last value wins, matching Geometry Dash and the old Dictionary
					// assignment behavior for duplicate properties.
					result[key] = token;
				}
				expecting_key = true;
			}
		}
		if (!expecting_key && odd_fields) ++*odd_fields;
		return result;
	}

	Dictionary parse_gd_pairs(const String &chunk) const {
		return parse_pairs(chunk);
	}

	// Parses one complete decompressed server level in a single native pass.
	// The online download response can contain hundreds of thousands of comma
	// pairs; crossing the GDScript/native boundary once per object was both
	// expensive and made partial parsing harder to diagnose. Keep one entry per
	// source chunk so converter indices and draw order remain exact.
	Dictionary parse_online_level(const String &level_string) const {
		Dictionary parsed;
		Array objects;
		PackedByteArray object_validity;
		int64_t odd_pair_chunks = 0;
		int64_t duplicate_keys = 0;
		int64_t empty_keys = 0;
		int64_t valid_objects = 0;
		int64_t malformed_objects = 0;
		int64_t invalid_numeric_objects = 0;
		int64_t source_chunks = 0;
		Dictionary object_id_counts;
		Dictionary header;
		double min_x = INFINITY;
		double max_x = -INFINITY;
		bool have_header = false;

		// Scan semicolon chunks directly. String::split retained a second complete
		// array of object strings until the entire parse ended, peaking badly on
		// levels with hundreds of thousands of placements.
		int64_t chunk_start = 0;
		const int64_t length = level_string.length();
		for (int64_t cursor = 0; cursor <= length; ++cursor) {
			if (cursor < length && level_string[cursor] != ';') continue;
			const String chunk = level_string.substr(chunk_start, cursor - chunk_start);
			chunk_start = cursor + 1;
			if (chunk.strip_edges().is_empty()) continue;
			if (!have_header) {
				int64_t header_odd = 0;
				header = parse_pairs(chunk, &header_odd, &duplicate_keys, &empty_keys);
				odd_pair_chunks += header_odd;
				have_header = true;
				continue;
			}

			++source_chunks;
			int64_t chunk_odd = 0;
			const Dictionary properties = parse_pairs(chunk, &chunk_odd, &duplicate_keys, &empty_keys);
			odd_pair_chunks += chunk_odd;
			objects.append(properties);
			object_validity.append(0);
			if (chunk_odd != 0 || !properties.has("1") || !properties.has("2") || !properties.has("3")) {
				++malformed_objects;
				continue;
			}
			const String id_text = String(properties["1"]).strip_edges();
			const String x_text = String(properties["2"]).strip_edges();
			const String y_text = String(properties["3"]).strip_edges();
			if (!id_text.is_valid_int() || !x_text.is_valid_float() || !y_text.is_valid_float()) {
				++invalid_numeric_objects;
				++malformed_objects;
				continue;
			}
			const int64_t object_id = id_text.to_int();
			if (object_id <= 0) {
				++invalid_numeric_objects;
				++malformed_objects;
				continue;
			}
			++valid_objects;
			object_validity.set(object_validity.size() - 1, 1);
			object_id_counts[object_id] = static_cast<int64_t>(object_id_counts.get(object_id, 0)) + 1;
			const double x = x_text.to_float();
			min_x = std::min(min_x, x);
			max_x = std::max(max_x, x);
		}

		parsed["header"] = header;
		parsed["objects"] = objects;
		parsed["object_validity"] = object_validity;
		parsed["source_chunks"] = source_chunks;
		parsed["valid_objects"] = valid_objects;
		parsed["malformed_objects"] = malformed_objects;
		parsed["invalid_numeric_objects"] = invalid_numeric_objects;
		parsed["odd_pair_chunks"] = odd_pair_chunks;
		parsed["duplicate_keys"] = duplicate_keys;
		parsed["empty_keys"] = empty_keys;
		parsed["object_id_counts"] = object_id_counts;
		parsed["min_x"] = std::isfinite(min_x) ? min_x : 0.0;
		parsed["max_x"] = std::isfinite(max_x) ? max_x : 0.0;
		return parsed;
	}

	String decode_level_string(const String &encoded) const {
		String data = encoded.strip_edges();
		if (data.is_empty()) return String();
		if (data.begins_with("kS") || data.begins_with("kA") || data.begins_with("1,") || data.contains(";1,")) return data;

		Marshalls *marshalls = Marshalls::get_singleton();
		if (!marshalls) return String();

		// Downloaded user levels carry a complete URL-safe Base64 payload.  The
		// 13-character H4sIAAAAAAAAA prefix is omitted ONLY by bundled official
		// levels.  Prefixing every payload whose text did not happen to begin
		// with H4sI corrupted valid user levels with a different gzip timestamp or
		// a zlib wrapper.  Decode first, inspect the binary wrapper, and use the
		// official-level compatibility prefix only as a final fallback.
		auto decode_payload = [&](const String &payload) -> String {
			const PackedByteArray bytes = marshalls->base64_to_raw(standard_base64(payload));
			if (bytes.is_empty()) return String();

			PackedByteArray inflated;
			if (bytes.size() >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
				inflated = bytes.decompress_dynamic(-1, 3); // FileAccess::COMPRESSION_GZIP
			} else if (bytes.size() >= 2 && (bytes[0] & 0x0f) == 8 &&
					(((static_cast<int>(bytes[0]) << 8) | bytes[1]) % 31) == 0) {
				// GD documentation describes the format as zlib and recommends
				// inflateInit2(15|32), which accepts either zlib or gzip wrappers.
				inflated = bytes.decompress_dynamic(-1, 1); // FileAccess::COMPRESSION_DEFLATE
			} else {
				const String plain = bytes.get_string_from_utf8();
				if (plain.begins_with("kS") || plain.begins_with("kA") || plain.contains(";1,")) return plain;
				return String();
			}
			if (inflated.is_empty()) return String();
			const String plain = inflated.get_string_from_utf8();
			// A successful inflate is not sufficient: reject binary garbage before
			// it reaches the object parser.
			if (!plain.begins_with("kS") && !plain.begins_with("kA") &&
					!plain.begins_with("1,") && !plain.contains(";1,")) return String();
			return plain;
		};

		String plain = decode_payload(data);
		if (!plain.is_empty()) return plain;
		if (!data.begins_with("H4sI")) {
			plain = decode_payload(String("H4sIAAAAAAAAA") + data);
		}
		return plain;
	}

	String encode_level_string(const String &plain) const {
		const PackedByteArray raw = plain.to_utf8_buffer();
		PackedByteArray compressed = raw.compress(3); // FileAccess::COMPRESSION_GZIP
		if (compressed.size() < 2 || compressed[0] != 0x1f || compressed[1] != 0x8b) {
			compressed = wrap_gzip(raw, compressed);
		}
		Marshalls *marshalls = Marshalls::get_singleton();
		return marshalls ? url_base64(marshalls->raw_to_base64(compressed)) : String();
	}

	PackedInt32Array sort_decoration_indices(const PackedInt32Array &z_orders,
			const PackedInt32Array &draw_orders, const PackedInt64Array &texture_ids) const {
		const int64_t count = std::min(z_orders.size(), std::min(draw_orders.size(), texture_ids.size()));
		std::vector<int32_t> indices(static_cast<size_t>(count));
		std::iota(indices.begin(), indices.end(), 0);
		std::stable_sort(indices.begin(), indices.end(), [&](int32_t a, int32_t b) {
			if (z_orders[a] != z_orders[b]) return z_orders[a] < z_orders[b];
			if (draw_orders[a] != draw_orders[b]) return draw_orders[a] < draw_orders[b];
			if (texture_ids[a] != texture_ids[b]) return texture_ids[a] < texture_ids[b];
			return a < b;
		});
		PackedInt32Array result;
		result.resize(count);
		for (int64_t i = 0; i < count; ++i) result.set(i, indices[static_cast<size_t>(i)]);
		return result;
	}

	Dictionary build_x_buckets(const PackedFloat32Array &origins, double bucket_width) const {
		Dictionary result;
		if (bucket_width <= 0.0) return result;
		std::map<int32_t, std::vector<int32_t>> buckets;
		for (int64_t i = 0; i < origins.size(); ++i) {
			buckets[static_cast<int32_t>(std::floor(origins[i] / bucket_width))].push_back(static_cast<int32_t>(i));
		}
		for (const auto &[key, values] : buckets) {
			PackedInt32Array packed;
			packed.resize(static_cast<int64_t>(values.size()));
			for (size_t i = 0; i < values.size(); ++i) packed.set(static_cast<int64_t>(i), values[i]);
			result[key] = packed;
		}
		return result;
	}

	PackedInt32Array visible_bucket_keys(const PackedInt32Array &keys, int64_t first, int64_t last) const {
		PackedInt32Array result;
		for (int64_t i = 0; i < keys.size(); ++i) {
			const int32_t key = keys[i];
			if (key >= first && key <= last) result.append(key);
		}
		return result;
	}

	Array commit_collision_shapes(Node2D *body, Node2D *source, const Array &descriptors) const {
		Array added;
		if (!body || !source) return added;
		for (int64_t i = 0; i < descriptors.size(); ++i) {
			const Dictionary descriptor = descriptors[i];
			Ref<Shape2D> shape = descriptor.get("resource", Variant());
			if (shape.is_null()) continue;
			CollisionShape2D *shape_node = memnew(CollisionShape2D);
			shape_node->set_shape(shape);
			shape_node->set_debug_color(descriptor.get("debug_color", Color()));
			body->add_child(shape_node);
			const Transform2D local = descriptor.get("local_xform", Transform2D());
			shape_node->set_global_transform(source->get_global_transform() * local);
			added.append(shape_node);
		}
		return added;
	}

	void reenable_collision_shapes(Node *container) const {
		if (!container) return;
		const Array bodies = container->get_children();
		for (int64_t i = 0; i < bodies.size(); ++i) {
			Node *body = Object::cast_to<Node>(static_cast<Object *>(bodies[i]));
			if (!body) continue;
			const Array shapes = body->get_children();
			for (int64_t j = 0; j < shapes.size(); ++j) {
				Object *shape = shapes[j];
				if (shape && static_cast<bool>(shape->get("disabled"))) shape->set("disabled", false);
			}
		}
	}
};

// Native visibility index used by FrustumCuller. The facade still computes the
// camera rectangle (a handful of operations); all large object-set storage,
// intersection and visibility transitions happen here without GDScript loops.
class NativeFrustumIndex : public RefCounted {
	GDCLASS(NativeFrustumIndex, RefCounted)

	struct Entry {
		uint64_t id = 0;
		double left = 0.0;
		double right = 0.0;
		int64_t first = 0;
		int64_t last = 0;
	};
	std::vector<Entry> entries;
	// OpenGD also partitions the level into fixed horizontal sections. Keep an
	// index from section to entry here so normal camera motion touches only the
	// sections leaving/entering the view instead of scanning the full level.
	std::map<int64_t, std::vector<size_t>> sections;
	std::vector<uint32_t> visited;
	uint32_t visit_generation = 0;
	double section_width = 1024.0;
	std::set<uint64_t> hidden;
	int64_t current_first = INT64_MAX;
	int64_t current_last = INT64_MIN;
	double current_left = INFINITY;
	double current_right = -INFINITY;

	CanvasItem *canvas_for(uint64_t id) const {
		Object *object = ObjectDB::get_instance(ObjectID(id));
		return Object::cast_to<CanvasItem>(object);
	}

	void apply_visibility(size_t index, double left, double right) {
		if (index >= entries.size()) return;
		const Entry &entry = entries[index];
		CanvasItem *canvas = canvas_for(entry.id);
		if (!canvas) {
			hidden.erase(entry.id);
			return;
		}
		const bool desired = entry.right >= left && entry.left <= right;
		if (desired) {
			auto found = hidden.find(entry.id);
			if (found != hidden.end()) {
				Node *node = Object::cast_to<Node>(canvas);
				if (!node || node->get_process_mode() != Node::PROCESS_MODE_DISABLED) canvas->set_visible(true);
				hidden.erase(found);
			}
		} else if (canvas->is_visible()) {
			canvas->set_visible(false);
			hidden.insert(entry.id);
		}
	}

	void visit_sections(int64_t first, int64_t last, double desired_left, double desired_right) {
		if (first > last) return;
		auto section = sections.lower_bound(first);
		while (section != sections.end() && section->first <= last) {
			for (size_t index : section->second) {
				if (visited[index] == visit_generation) continue;
				visited[index] = visit_generation;
				apply_visibility(index, desired_left, desired_right);
			}
			++section;
		}
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("configure", "objects", "lefts", "rights", "bucket_width"), &NativeFrustumIndex::configure);
		ClassDB::bind_method(D_METHOD("set_view", "left", "right"), &NativeFrustumIndex::set_view);
		ClassDB::bind_method(D_METHOD("show_all"), &NativeFrustumIndex::show_all);
		ClassDB::bind_method(D_METHOD("tracked_count"), &NativeFrustumIndex::tracked_count);
		ClassDB::bind_method(D_METHOD("hidden_count"), &NativeFrustumIndex::hidden_count);
	}

public:
	void configure(const Array &objects, const PackedFloat32Array &lefts,
			const PackedFloat32Array &rights, double bucket_width) {
		show_all();
		entries.clear();
		sections.clear();
		const int64_t count = std::min(objects.size(), std::min(lefts.size(), rights.size()));
		if (bucket_width <= 0.0) return;
		section_width = bucket_width;
		entries.reserve(static_cast<size_t>(count));
		for (int64_t i = 0; i < count; ++i) {
			Object *object = objects[i];
			CanvasItem *canvas = Object::cast_to<CanvasItem>(object);
			if (!canvas) continue;
			Entry entry;
			entry.id = canvas->get_instance_id();
			entry.left = std::min(static_cast<double>(lefts[i]), static_cast<double>(rights[i]));
			entry.right = std::max(static_cast<double>(lefts[i]), static_cast<double>(rights[i]));
			entry.first = static_cast<int64_t>(std::floor(entry.left / bucket_width));
			entry.last = static_cast<int64_t>(std::floor(entry.right / bucket_width));
			const size_t index = entries.size();
			entries.push_back(entry);
			for (int64_t key = entry.first; key <= entry.last; ++key) sections[key].push_back(index);
		}
		visited.assign(entries.size(), 0);
		visit_generation = 0;
		current_first = INT64_MAX;
		current_last = INT64_MIN;
		current_left = INFINITY;
		current_right = -INFINITY;
	}

	void set_view(double left, double right) {
		if (right < left) std::swap(left, right);
		if (left == current_left && right == current_right) return;
		const int64_t first = sections.empty() ? 0 : static_cast<int64_t>(std::floor(left / section_width));
		const int64_t last = sections.empty() ? -1 : static_cast<int64_t>(std::floor(right / section_width));
		if (current_first > current_last) {
			// One complete reconciliation at level start. Later frames inspect only
			// the old and new screen sections, but retain exact world-coordinate
			// bounds so an object disappears precisely after its final pixel exits.
			for (size_t index = 0; index < entries.size(); ++index) apply_visibility(index, left, right);
		} else {
			if (++visit_generation == 0) {
				std::fill(visited.begin(), visited.end(), 0);
				visit_generation = 1;
			}
			visit_sections(current_first, current_last, left, right);
			visit_sections(first, last, left, right);
		}
		current_first = first;
		current_last = last;
		current_left = left;
		current_right = right;
	}

	void show_all() {
		for (uint64_t id : hidden) {
			CanvasItem *canvas = canvas_for(id);
			Node *node = Object::cast_to<Node>(canvas);
			if (canvas && (!node || node->get_process_mode() != Node::PROCESS_MODE_DISABLED)) canvas->set_visible(true);
		}
		hidden.clear();
		current_first = INT64_MAX;
		current_last = INT64_MIN;
		current_left = INFINITY;
		current_right = -INFINITY;
	}

	int64_t tracked_count() const { return static_cast<int64_t>(entries.size()); }
	int64_t hidden_count() const { return static_cast<int64_t>(hidden.size()); }
};

// Native fast path for ColorChannelWatcher.refresh_objects_color. A colour
// trigger (and every pulse-animation frame of one) repaints every HSVWatcher of
// its channel: the old path cost a GDScript call plus ~15 Variant property
// accesses per object, each frame, for channels with thousands of members.
// The index snapshots the per-object state once and applies a channel update
// with direct CanvasItem calls, skipping the interpreter entirely. The bridge
// in ColorChannelWatcher.gd rebuilds the snapshot whenever watcher state or
// group membership changes, and keeps the old loop for editor builds.
class NativeColorChannelIndex : public RefCounted {
	GDCLASS(NativeColorChannelIndex, RefCounted)

	struct Record {
		ObjectID watcher;
		float hsv[3] = { 0.0f, 0.0f, 0.0f };
		float intensity = 1.0f;
		float alpha = 1.0f;
		bool sat_multiplies = false;
		bool val_multiplies = false;
	};
	std::vector<Record> records;
	// base_intensity/base_alpha are channel-wide values mirrored onto every
	// watcher for later GDScript reads (update_color, to_data). Skipping the
	// property writes when the channel values did not change removes two
	// hashed script-property sets per object on colour-only pulses.
	bool base_valid = false;
	double last_intensity = 0.0;
	double last_alpha = 0.0;

	static Node *node_for(ObjectID id) {
		return Object::cast_to<Node>(ObjectDB::get_instance(id));
	}

public:
	void clear() {
		records.clear();
		base_valid = false;
	}

	// watchers: the channel group's HSVWatcher nodes. Per-object shift,
	// intensity, alpha and the multiply flags are read once; the caller is
	// responsible for re-configuring when that state changes (the GDScript
	// bridge tracks a generation counter for this).
	void configure(const Array &watchers) {
		clear();
		records.reserve(static_cast<size_t>(watchers.size()));
		for (int64_t i = 0; i < watchers.size(); ++i) {
			Object *object = watchers[i];
			Node *node = Object::cast_to<Node>(object);
			if (!node || !node->get_parent()) continue;
			// Selection highlights are an editor-only state that repaints to a
			// fixed colour; leave those to the GDScript path.
			if (static_cast<int64_t>(node->get("selection_highlight")) != 0) continue;
			Record record;
			record.watcher = node->get_instance_id();
			const Array shift = node->get("hsv_shift");
			for (int component = 0; component < 3 && component < shift.size(); ++component)
				record.hsv[component] = static_cast<float>(static_cast<double>(shift[component]));
			record.intensity = static_cast<float>(static_cast<double>(node->get("intensity")));
			record.alpha = static_cast<float>(static_cast<double>(node->get("alpha")));
			record.sat_multiplies = static_cast<bool>(node->get("saturation_multiplies"));
			record.val_multiplies = static_cast<bool>(node->get("value_multiplies"));
			records.push_back(record);
		}
	}

	// Applies one channel update: the channel colour (already copy-resolved by
	// the caller), the channel HSV shift, and the channel intensity/alpha.
	// Mirrors ColorChannelWatcher.refresh_objects_color + HSVWatcher.update_color
	// operation for operation, including the s, v, h apply order (each Color
	// component write round-trips through RGB, so order is observable).
	void apply(const Color &channel_color, double shift_h, double shift_s, double shift_v,
			double intensity, double alpha) {
		const bool write_base = !base_valid || intensity != last_intensity || alpha != last_alpha;
		base_valid = true;
		last_intensity = intensity;
		last_alpha = alpha;
		const float fh = static_cast<float>(shift_h);
		const float fs = static_cast<float>(shift_s);
		const float fv = static_cast<float>(shift_v);
		for (const Record &record : records) {
			CanvasItem *watcher = Object::cast_to<CanvasItem>(node_for(record.watcher));
			if (!watcher) continue;
			// watcher.modulate = channel colour + channel shift (s, v, h).
			Color modulate = channel_color;
			modulate.set_s(modulate.get_s() + fs);
			modulate.set_v(modulate.get_v() + fv);
			modulate.set_h(modulate.get_h() + fh);
			// HSVWatcher.update_color: per-object shift on top (s, v, h), then
			// intensity product and alpha override on the parent's modulate.
			// An all-zero shift in multiplicative mode is Geometry Dash's
			// "HSV enabled but untouched" encoding and must not black the
			// object out (GDRweb's shiftColor guard; the GDScript watcher
			// and DecorationBatch paths match this).
			Color shifted = modulate;
			if (!(record.hsv[0] == 0.0f && record.hsv[1] == 0.0f && record.hsv[2] == 0.0f)) {
				if (record.sat_multiplies) shifted.set_s(shifted.get_s() * record.hsv[1]);
				else shifted.set_s(shifted.get_s() + record.hsv[1]);
				if (record.val_multiplies) shifted.set_v(shifted.get_v() * record.hsv[2]);
				else shifted.set_v(shifted.get_v() + record.hsv[2]);
				shifted.set_h(shifted.get_h() + record.hsv[0]);
			}
			Color parent_modulate = shifted * (record.intensity * static_cast<float>(intensity));
			parent_modulate.a = modulate.a * record.alpha * static_cast<float>(alpha);
			watcher->set_modulate(modulate);
			CanvasItem *target = Object::cast_to<CanvasItem>(watcher->get_parent());
			if (target) target->set_modulate(parent_modulate);
			if (write_base) {
				watcher->set("base_intensity", intensity);
				watcher->set("base_alpha", alpha);
			}
		}
	}

	int64_t item_count() const { return static_cast<int64_t>(records.size()); }

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("clear"), &NativeColorChannelIndex::clear);
		ClassDB::bind_method(D_METHOD("configure", "watchers"), &NativeColorChannelIndex::configure);
		ClassDB::bind_method(D_METHOD("apply", "color", "shift_h", "shift_s", "shift_v", "intensity", "alpha"), &NativeColorChannelIndex::apply);
		ClassDB::bind_method(D_METHOD("item_count"), &NativeColorChannelIndex::item_count);
	}
};

// Native state machine for runtime level construction. It owns iteration,
// layer creation, placement dispatch and sealing; GDScript's LevelBuildJob is
// only a source/editor fallback and stable API facade.
class NativeLevelBuildJob : public RefCounted {
	GDCLASS(NativeLevelBuildJob, RefCounted)

	Dictionary data;
	Array layers_data;
	Array decoration_data;
	Ref<Script> level_script;
	Ref<Script> layer_script;
	Ref<Script> decoration_loader_script;
	Node *level = nullptr;
	Node *layer = nullptr;
	int64_t layer_index = 0;
	int64_t object_index = 0;
	bool layer_initialized = false;
	bool finished = false;
	bool drop_decoration = false;

	static Ref<Script> load_script(const String &path) {
		return ResourceLoader::get_singleton()->load(path);
	}

	static Node *new_script_node(const Ref<Script> &script) {
		if (script.is_null()) return nullptr;
		Variant value = script->call("new");
		Object *object = value;
		return Object::cast_to<Node>(object);
	}

	void start_next_layer() {
		if (layer_index >= layers_data.size()) {
			finish_build();
			return;
		}
		const Dictionary layer_data = layers_data[layer_index];
		layer = new_script_node(layer_script);
		if (!layer) {
			finish_build();
			return;
		}
		layer->set_name(layer_data.get("name", String("Layer")));
		layer->set("locked", layer_data.get("locked", false));
		layer_initialized = true;
		object_index = 0;
	}

	void place(const Dictionary &object_data) {
		// Generic 2.2 triggers are already complete packed records for
		// NativeTriggerRuntime. Instantiating an Area2D, CollisionShape and script
		// shell for each one wastes the majority of trigger-heavy level memory.
		if (static_cast<bool>(object_data.get("native_only_trigger", false))) return;
		if (static_cast<bool>(object_data.get("decoration", false))) {
			if (!drop_decoration) decoration_data.append(object_data);
			return;
		}
		const Dictionary static_art = object_data.get("native_static_art", Dictionary());
		if (!static_art.is_empty()) decoration_data.append(static_art);
		Variant value = level_script->call("instantiate_object_from_data", object_data, level);
		Object *object = value;
		Node *node = Object::cast_to<Node>(object);
		if (!node) return;
		// Static gameplay art is now represented by a node-free native renderer.
		// Preserve the root/group transform and authored Collision subtree, while
		// dropping Sprite2D descendants and their per-node render state.
		if (!static_art.is_empty()) {
			node->set_meta("_gd_native_packed_art", true);
			for (const char *name : {"Base", "Detail"}) {
				Node *visual = node->get_node_or_null(NodePath(name));
				if (!visual) continue;
				node->remove_child(visual);
				visual->queue_free();
			}
		}
		node->set_meta("layer", layer);
		layer->add_child(node);
	}

	void seal_layer() {
		if (!decoration_data.is_empty()) {
			const double scale = decoration_loader_script->call("art_scale");
			const Array batches = decoration_loader_script->call("build_batches", decoration_data, scale);
			for (int64_t i = 0; i < batches.size(); ++i) {
				Object *object = batches[i];
				Node *batch = Object::cast_to<Node>(object);
				if (!batch) continue;
				batch->set_meta("layer", layer);
				layer->add_child(batch);
			}
			decoration_data.clear();
		}
		Array layers = level->get("layers");
		layers.append(layer);
		level->set("layers", layers);
		level->add_child(layer);
		layer = nullptr;
		layer_initialized = false;
		++layer_index;
	}

	void finish_build() {
		if (finished || !level) return;
		level->call("use_data", data, 1);
		level->connect("ready", Callable(level, "setup_color_channel_watchers"), Object::CONNECT_ONE_SHOT);
		finished = true;
	}

	void work() {
		if (!layer_initialized) {
			start_next_layer();
			return;
		}
		const Dictionary layer_data = layers_data[layer_index];
		const Array objects = layer_data.get("objects", Array());
		if (object_index < objects.size()) {
			place(objects[object_index]);
			++object_index;
			return;
		}
		seal_layer();
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("initialize", "data", "drop_decoration"), &NativeLevelBuildJob::initialize);
		ClassDB::bind_method(D_METHOD("step", "budget_ms"), &NativeLevelBuildJob::step);
		ClassDB::bind_method(D_METHOD("get_level"), &NativeLevelBuildJob::get_level);
		ClassDB::bind_method(D_METHOD("is_finished"), &NativeLevelBuildJob::is_finished);
	}

public:
	void initialize(const Dictionary &p_data, bool p_drop_decoration) {
		data = p_data;
		drop_decoration = p_drop_decoration;
		layers_data = data.get("layers", Array());
		level_script = load_script("res://src/Level.gd");
		layer_script = load_script("res://src/Layer.gd");
		decoration_loader_script = load_script("res://src/static/GDDecorationLoader.gd");
		level = new_script_node(level_script);
		if (!level || layers_data.is_empty()) finish_build();
	}

	void step(int64_t budget_ms) {
		if (finished) return;
		const uint64_t deadline = Time::get_singleton()->get_ticks_msec() + static_cast<uint64_t>(std::max<int64_t>(1, budget_ms));
		while (!finished && Time::get_singleton()->get_ticks_msec() < deadline) work();
	}

	Node *get_level() const { return level; }
	bool is_finished() const { return finished; }
};

class NativeDecorationRenderer;
static std::set<NativeDecorationRenderer *> registered_decoration_renderers;
static int decoration_coordinator_count = 0;
static uint64_t decoration_last_update_frame = UINT64_MAX;

// Node-free retained renderer. DecorationBatch remains a lightweight Node2D
// group/trigger proxy, while its artwork is emitted directly into a
// RenderingServer canvas-item RID parented to that proxy's canvas item.
class NativeDecorationRenderer : public RefCounted {
	GDCLASS(NativeDecorationRenderer, RefCounted)

	struct Record {
		Ref<Texture2D> texture;
		Rect2 region;
		Transform2D transform;
		Color color;
		float base_alpha = 1.0f;
		float hsv[5] = {0, 0, 0, 0, 0};
		bool has_hsv = false;
		float spin_radians = 0.0f;
		Vector2 spin_pivot;
		// Blend override after a colour trigger flips the channel (key 17):
		// 0 inherits the batch's import-time material, 1 additive, 2 normal.
		uint8_t blend = 0;
	};

	uint64_t owner_id = 0;
	RID canvas_item;
	// Records a colour trigger flipped away from the batch's own blend mode
	// are re-routed onto these instead, so one batch can hold normal and
	// additive sprites at once without rebuilding either side.
	RID canvas_item_plain;
	RID canvas_item_add;
	Ref<CanvasItemMaterial> additive_material;
	std::vector<Record> records;
	// Dense indices are effectively a small SoA hot set: animation touches only
	// transform/spin data for rotating records, never every static Record.
	std::vector<size_t> spinning_indices;
	// Generation stamps replace a per-rebuild "emitted" byte vector: a camera
	// bucket change used to allocate and zero records.size() bytes on every
	// rebuild, every renderer, every frame of a scrolling level.
	std::vector<uint32_t> emitted_stamp;
	uint32_t emit_stamp = 0;
	std::map<int64_t, std::map<int64_t, std::vector<size_t>>> sections;
	bool cull = true;
	double bucket_width = 256.0;
	double cull_margin = 0.0;
	int64_t first_bucket = INT64_MIN;
	int64_t last_bucket = INT64_MAX;
	int64_t first_row = INT64_MIN;
	int64_t last_row = INT64_MAX;
	Vector2 last_viewport_size;
	bool view_initialized = false;
	bool range_has_records = false;
	bool commands_dirty = false;
	int64_t last_drawn_items = 0;

	CanvasItem *owner() const {
		return Object::cast_to<CanvasItem>(ObjectDB::get_instance(ObjectID(owner_id)));
	}

	bool selected_range_has_records() const {
		auto column = sections.lower_bound(first_bucket);
		while (column != sections.end() && column->first <= last_bucket) {
			auto row = column->second.lower_bound(first_row);
			if (row != column->second.end() && row->first <= last_row && !row->second.empty()) return true;
			++column;
		}
		return false;
	}

	void rebuild_commands() {
		commands_dirty = false;
		RenderingServer *server = RenderingServer::get_singleton();
		if (!server || !canvas_item.is_valid()) return;
		server->canvas_item_clear(canvas_item);
		if (canvas_item_plain.is_valid()) server->canvas_item_clear(canvas_item_plain);
		if (canvas_item_add.is_valid()) server->canvas_item_clear(canvas_item_add);
		last_drawn_items = 0;
		if (!range_has_records && cull) return;
		auto draw_record = [&](const Record &record) {
			// Flipped records draw on their own canvas item; everything else
			// keeps the batch's import-time material through the parent.
			RID target = canvas_item;
			if (record.blend == 1 && canvas_item_add.is_valid()) target = canvas_item_add;
			else if (record.blend == 2 && canvas_item_plain.is_valid()) target = canvas_item_plain;
			server->canvas_item_add_set_transform(target, record.transform);
			server->canvas_item_add_texture_rect_region(
					target, Rect2(-record.region.size * 0.5, record.region.size),
					record.texture->get_rid(), record.region, record.color, false, true);
			++last_drawn_items;
		};
		if (!cull) {
			for (const Record &record : records) draw_record(record);
			return;
		}
		// Records spanning several cells are indexed into each touched cell.
		// Emit them once even when several of those cells are visible.
		if (records.size() != emitted_stamp.size()) emitted_stamp.assign(records.size(), 0);
		uint32_t stamp = ++emit_stamp;
		if (stamp == 0) { // wrapped: retire every old stamp at once
			std::fill(emitted_stamp.begin(), emitted_stamp.end(), 0);
			stamp = emit_stamp = 1;
		}
		auto column = sections.lower_bound(first_bucket);
		while (column != sections.end() && column->first <= last_bucket) {
			auto row = column->second.lower_bound(first_row);
			while (row != column->second.end() && row->first <= last_row) {
			for (size_t index : row->second) {
				if (emitted_stamp[index] == stamp) continue;
				emitted_stamp[index] = stamp;
				draw_record(records[index]);
			}
				++row;
			}
			++column;
		}
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("configure", "owner", "textures", "regions", "transforms", "colors", "origins", "base_alphas", "hsv_data", "spins", "spin_pivots", "enable_culling", "width", "margin"), &NativeDecorationRenderer::configure);
		ClassDB::bind_method(D_METHOD("queue_redraw"), &NativeDecorationRenderer::request_redraw);
		ClassDB::bind_method(D_METHOD("update_camera_range"), &NativeDecorationRenderer::update_camera_range);
		ClassDB::bind_method(D_METHOD("set_visible_buckets", "first", "last"), &NativeDecorationRenderer::set_visible_buckets);
		ClassDB::bind_method(D_METHOD("apply_channel_color", "indices", "color"), &NativeDecorationRenderer::apply_channel_color);
		ClassDB::bind_method(D_METHOD("set_channel_blending", "indices", "additive"), &NativeDecorationRenderer::set_channel_blending);
		ClassDB::bind_method(D_METHOD("get_item_blend", "index"), &NativeDecorationRenderer::get_item_blend);
		ClassDB::bind_method(D_METHOD("get_item_color", "index"), &NativeDecorationRenderer::get_item_color);
		ClassDB::bind_method(D_METHOD("set_item_color", "index", "color"), &NativeDecorationRenderer::set_item_color);
		ClassDB::bind_method(D_METHOD("set_item_transform", "index", "transform"), &NativeDecorationRenderer::set_item_transform);
		ClassDB::bind_method(D_METHOD("advance_animation", "delta"), &NativeDecorationRenderer::advance_animation);
		ClassDB::bind_method(D_METHOD("get_item_transform", "index"), &NativeDecorationRenderer::get_item_transform);
		ClassDB::bind_method(D_METHOD("item_count"), &NativeDecorationRenderer::item_count);
		ClassDB::bind_method(D_METHOD("last_drawn_count"), &NativeDecorationRenderer::last_drawn_count);
	}

public:
	NativeDecorationRenderer() {
		RenderingServer *server = RenderingServer::get_singleton();
		if (server) {
			canvas_item = server->canvas_item_create();
			canvas_item_plain = server->canvas_item_create();
			canvas_item_add = server->canvas_item_create();
		}
		registered_decoration_renderers.insert(this);
	}
	~NativeDecorationRenderer() override {
		registered_decoration_renderers.erase(this);
		RenderingServer *server = RenderingServer::get_singleton();
		if (server) {
			if (canvas_item.is_valid()) server->free_rid(canvas_item);
			if (canvas_item_plain.is_valid()) server->free_rid(canvas_item_plain);
			if (canvas_item_add.is_valid()) server->free_rid(canvas_item_add);
		}
	}

	void request_redraw() { commands_dirty = true; }
	void flush_commands() {
		if (!commands_dirty || (cull && !view_initialized)) return;
		rebuild_commands();
		commands_dirty = false;
	}

	void configure(Object *p_owner, const Array &textures, const Array &regions, const Array &transforms,
			const PackedColorArray &colors, const PackedFloat32Array &origins,
			const PackedFloat32Array &base_alphas, const PackedFloat32Array &hsv_data,
			const PackedFloat32Array &spins, const PackedFloat32Array &spin_pivots,
			bool enable_culling, double width, double margin) {
		CanvasItem *owner_canvas = Object::cast_to<CanvasItem>(p_owner);
		owner_id = owner_canvas ? owner_canvas->get_instance_id() : 0;
		RenderingServer *server = RenderingServer::get_singleton();
		if (server && owner_canvas && canvas_item.is_valid()) {
			server->canvas_item_set_parent(canvas_item, owner_canvas->get_canvas_item());
			server->canvas_item_set_use_parent_material(canvas_item, true);
			server->canvas_item_set_visible(canvas_item, false);
			// The two override canvas items ignore the batch's material: one
			// always adds, one is always plain. Records only reach them after
			// a colour trigger flips their channel's blending.
			if (canvas_item_plain.is_valid()) {
				server->canvas_item_set_parent(canvas_item_plain, owner_canvas->get_canvas_item());
				server->canvas_item_set_use_parent_material(canvas_item_plain, false);
				server->canvas_item_set_visible(canvas_item_plain, false);
			}
			if (canvas_item_add.is_valid()) {
				if (additive_material.is_null()) {
					additive_material.instantiate();
					additive_material->set_blend_mode(CanvasItemMaterial::BLEND_MODE_ADD);
				}
				server->canvas_item_set_parent(canvas_item_add, owner_canvas->get_canvas_item());
				server->canvas_item_set_use_parent_material(canvas_item_add, false);
				server->canvas_item_set_material(canvas_item_add, additive_material->get_rid());
				server->canvas_item_set_visible(canvas_item_add, false);
			}
		}
		const int64_t count = std::min({textures.size(), regions.size(), transforms.size(), colors.size(), origins.size(), base_alphas.size()});
		records.clear(); spinning_indices.clear(); sections.clear(); records.reserve(static_cast<size_t>(count));
		emitted_stamp.clear();
		bucket_width = width > 0.0 ? width : 256.0;
		for (int64_t i = 0; i < count; ++i) {
			Record record;
			record.texture = textures[i]; record.region = regions[i];
			record.transform = transforms[i]; record.color = colors[i];
			record.base_alpha = base_alphas[i];
			if (hsv_data.size() >= (i + 1) * 5) {
				record.has_hsv = hsv_data[i * 5 + 4] >= 0.0f;
				for (int component = 0; component < 5; ++component) record.hsv[component] = hsv_data[i * 5 + component];
			}
			if (spins.size() > i) record.spin_radians = spins[i] * 0.01745329251994329577f;
			if (spin_pivots.size() >= (i + 1) * 2) record.spin_pivot = Vector2(spin_pivots[i * 2], spin_pivots[i * 2 + 1]);
			else record.spin_pivot = record.transform.get_origin();
			const Rect2 bounds = record.transform.xform(Rect2(-record.region.size * 0.5, record.region.size));
			// Index the complete conservative rotation circle, not only the origin.
			// The previous batch-wide maximum radius let one giant background sprite
			// expand the query for every ordinary object and effectively submitted
			// the whole level. Per-record coverage keeps large art correct without
			// poisoning culling for its neighbours.
			const Vector2 center = record.spin_pivot;
			const double radius = record.transform.get_origin().distance_to(center) + (bounds.size * 0.5).length();
			const Rect2 coverage(center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0));
			const size_t index = records.size(); records.push_back(record);
			if (record.spin_radians != 0.0f) spinning_indices.push_back(index);
			const int64_t first_column = static_cast<int64_t>(std::floor(coverage.position.x / bucket_width));
			const int64_t last_column = static_cast<int64_t>(std::floor(coverage.get_end().x / bucket_width));
			const int64_t top_row = static_cast<int64_t>(std::floor(coverage.position.y / bucket_width));
			const int64_t bottom_row = static_cast<int64_t>(std::floor(coverage.get_end().y / bucket_width));
			for (int64_t column = first_column; column <= last_column; ++column) {
				for (int64_t row = top_row; row <= bottom_row; ++row) sections[column][row].push_back(index);
			}
		}
		cull = enable_culling; cull_margin = std::max(0.0, margin);
		view_initialized = false; range_has_records = !cull;
		if (!cull) rebuild_commands();
	}

	void advance_animation(double delta) {
		if (spinning_indices.empty() || delta <= 0.0) return;
		for (size_t index : spinning_indices) {
			Record &record = records[index];
			const double angle = static_cast<double>(record.spin_radians) * delta;
			const Vector2 old_origin = record.transform.get_origin();
			record.transform = record.transform.rotated_local(angle);
			record.transform.set_origin(record.spin_pivot + (old_origin - record.spin_pivot).rotated(angle));
		}
		commands_dirty = true;
	}

	bool capture_cull_job(DecorationCullJob &job) const {
		CanvasItem *owner_canvas = owner();
		if (!cull || !owner_canvas || !owner_canvas->is_inside_tree()) return false;
		job.renderer_id = get_instance_id();
		job.from_screen = owner_canvas->get_global_transform_with_canvas().affine_inverse();
		job.screen_size = owner_canvas->get_viewport_rect().size;
		job.radius = cull_margin;
		job.cell_size = bucket_width;
		return true;
	}

	void apply_cull_job(const DecorationCullJob &job) {
		RenderingServer *server = RenderingServer::get_singleton();
		if (!server || !canvas_item.is_valid()) return;
		if (view_initialized && job.first == first_bucket && job.last == last_bucket &&
				job.top == first_row && job.bottom == last_row && job.screen_size == last_viewport_size) return;
		first_bucket = job.first; last_bucket = job.last;
		first_row = job.top; last_row = job.bottom;
		last_viewport_size = job.screen_size; view_initialized = true;
		range_has_records = selected_range_has_records();
		server->canvas_item_set_visible(canvas_item, range_has_records);
		if (canvas_item_plain.is_valid()) server->canvas_item_set_visible(canvas_item_plain, range_has_records);
		if (canvas_item_add.is_valid()) server->canvas_item_set_visible(canvas_item_add, range_has_records);
		rebuild_commands();
	}

	void update_camera_range() {
		CanvasItem *owner_canvas = owner();
		RenderingServer *server = RenderingServer::get_singleton();
		if (!cull || !owner_canvas || !owner_canvas->is_inside_tree() || !server) return;
		const Transform2D from_screen = owner_canvas->get_global_transform_with_canvas().affine_inverse();
		const Vector2 screen_size = owner_canvas->get_viewport_rect().size;
		Rect2 local_view(from_screen.xform(Vector2()), Vector2());
		local_view = local_view.expand(from_screen.xform(Vector2(screen_size.x, 0)));
		local_view = local_view.expand(from_screen.xform(screen_size));
		local_view = local_view.expand(from_screen.xform(Vector2(0, screen_size.y)));
		local_view = local_view.grow(cull_margin);
		const int64_t first = static_cast<int64_t>(std::floor(local_view.position.x / bucket_width));
		const int64_t last = static_cast<int64_t>(std::floor(local_view.get_end().x / bucket_width));
		const int64_t top = static_cast<int64_t>(std::floor(local_view.position.y / bucket_width));
		const int64_t bottom = static_cast<int64_t>(std::floor(local_view.get_end().y / bucket_width));
		if (view_initialized && first == first_bucket && last == last_bucket && top == first_row && bottom == last_row && screen_size == last_viewport_size) return;
		first_bucket = first; last_bucket = last; first_row = top; last_row = bottom;
		last_viewport_size = screen_size; view_initialized = true;
		range_has_records = selected_range_has_records();
		server->canvas_item_set_visible(canvas_item, range_has_records);
		if (canvas_item_plain.is_valid()) server->canvas_item_set_visible(canvas_item_plain, range_has_records);
		if (canvas_item_add.is_valid()) server->canvas_item_set_visible(canvas_item_add, range_has_records);
		rebuild_commands();
	}

	void set_visible_buckets(int64_t first, int64_t last) { first_bucket = first; last_bucket = last; range_has_records = selected_range_has_records(); rebuild_commands(); }
	// Flips the given records between normal and additive blending when a
	// colour trigger toggles their channel (key 17). Idempotent: the batch's
	// GDScript side caches the last state per channel.
	void set_channel_blending(const PackedInt32Array &indices, bool additive) {
		for (int64_t i = 0; i < indices.size(); ++i) {
			const int64_t index = indices[i];
			if (index < 0 || index >= static_cast<int64_t>(records.size())) continue;
			records[static_cast<size_t>(index)].blend = additive ? 1 : 2;
		}
		commands_dirty = true;
	}
	// Blend override of one record (0 inherit, 1 additive, 2 normal) for tests.
	int64_t get_item_blend(int64_t index) const {
		if (index < 0 || index >= static_cast<int64_t>(records.size())) return -1;
		return records[static_cast<size_t>(index)].blend;
	}
	void apply_channel_color(const PackedInt32Array &indices, const Color &channel_color) {
		for (int64_t i = 0; i < indices.size(); ++i) {
			const int64_t index = indices[i]; if (index < 0 || index >= static_cast<int64_t>(records.size())) continue;
			Record &record = records[static_cast<size_t>(index)]; Color tinted = channel_color;
			// An all-zero shift with the sliders in multiplicative mode is
			// Geometry Dash's "HSV enabled but untouched" encoding; the
			// zeros would otherwise multiply saturation and value to 0 and
			// render the item as a black silhouette. GDRweb's
			// HSVShift.shiftColor returns the colour unchanged then.
			if (record.has_hsv && !(record.hsv[0] == 0.0f && record.hsv[1] == 0.0f && record.hsv[2] == 0.0f)) {
				float hue = std::fmod(tinted.get_h() + record.hsv[0], 1.0f); if (hue < 0) hue += 1.0f;
				const float saturation = std::clamp(record.hsv[3] > 0.5f ? tinted.get_s() + record.hsv[1] : tinted.get_s() * record.hsv[1], 0.0f, 1.0f);
				const float value = std::clamp(record.hsv[4] > 0.5f ? tinted.get_v() + record.hsv[2] : tinted.get_v() * record.hsv[2], 0.0f, 1.0f);
				tinted = Color::from_hsv(hue, saturation, value, channel_color.a);
			}
			tinted.a = channel_color.a * record.base_alpha; record.color = tinted;
		}
		commands_dirty = true;
	}
	Color get_item_color(int64_t index) const { return index >= 0 && index < static_cast<int64_t>(records.size()) ? records[index].color : Color(1,1,1,1); }
	void set_item_color(int64_t index, const Color &color) { if (index >= 0 && index < static_cast<int64_t>(records.size())) { records[index].color = color; commands_dirty = true; } }
	void set_item_transform(int64_t index, const Transform2D &transform) { if (index >= 0 && index < static_cast<int64_t>(records.size())) { records[index].transform = transform; commands_dirty = true; } }
	Transform2D get_item_transform(int64_t index) const { return index >= 0 && index < static_cast<int64_t>(records.size()) ? records[index].transform : Transform2D(); }
	int64_t item_count() const { return static_cast<int64_t>(records.size()); }
	int64_t animated_item_count() const { return static_cast<int64_t>(spinning_indices.size()); }
	int64_t last_drawn_count() const { return last_drawn_items; }
	bool is_spatially_culled() const { return cull; }
};
static void decoration_coordinator_enter() {
	++decoration_coordinator_count;
}

static void decoration_coordinator_exit() {
	decoration_coordinator_count = std::max(0, decoration_coordinator_count - 1);
}

static void update_registered_decoration_renderers(double delta) {
	// Several level runtimes can briefly coexist during scene replacement.
	const uint64_t frame = Engine::get_singleton()->get_process_frames();
	if (frame == decoration_last_update_frame) return;
	decoration_last_update_frame = frame;
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	static Ref<NativeDecorationCullWorker> worker;
	static int64_t active_group = -1;
	// Coalesce any number of channel/spin updates into one RID command rebuild
	// per renderer per frame instead of clearing/re-emitting after every item.
	for (NativeDecorationRenderer *renderer : registered_decoration_renderers) {
		if (!renderer) continue;
		renderer->advance_animation(delta);
		renderer->flush_commands();
	}
	if (!pool) return;
	if (worker.is_null()) worker.instantiate();

	// Never wait on the game thread. Apply a completed previous-frame result;
	// if workers are still busy, retain the conservative old cells and try next
	// frame. This makes culling incapable of becoming a new frame-time spike.
	if (active_group >= 0) {
		if (!pool->is_group_task_completed(active_group)) return;
		pool->wait_for_group_task_completion(active_group);
		for (const DecorationCullJob &job : decoration_cull_jobs) {
			Object *object = ObjectDB::get_instance(ObjectID(job.renderer_id));
			NativeDecorationRenderer *renderer = Object::cast_to<NativeDecorationRenderer>(object);
			if (renderer) renderer->apply_cull_job(job);
		}
		active_group = -1;
	}

	decoration_cull_jobs.clear();
	decoration_cull_jobs.reserve(registered_decoration_renderers.size());
	for (NativeDecorationRenderer *renderer : registered_decoration_renderers) {
		if (!renderer) continue;
		DecorationCullJob job;
		if (renderer->capture_cull_job(job)) decoration_cull_jobs.push_back(job);
	}
	if (!decoration_cull_jobs.empty()) {
		active_group = pool->add_group_task(
				Callable(worker.ptr(), "compute"), static_cast<int32_t>(decoration_cull_jobs.size()),
				-1, true, "GD visible-cell culling");
	}
}

static Dictionary registered_decoration_stats() {
	Dictionary stats;
	int64_t records = 0;
	int64_t animated_records = 0;
	int64_t submitted = 0;
	int64_t empty_canvases = 0;
	int64_t culled_canvases = 0;
	for (NativeDecorationRenderer *canvas : registered_decoration_renderers) {
		if (!canvas) continue;
		records += canvas->item_count();
		animated_records += canvas->animated_item_count();
		submitted += canvas->last_drawn_count();
		if (canvas->last_drawn_count() == 0) ++empty_canvases;
		if (canvas->is_spatially_culled()) ++culled_canvases;
	}
	stats["canvases"] = static_cast<int64_t>(registered_decoration_renderers.size());
	stats["culled_canvases"] = culled_canvases;
	stats["empty_canvases"] = empty_canvases;
	stats["records"] = records;
	stats["animated_records"] = animated_records;
	stats["submitted_records"] = submitted;
	return stats;
}

} // namespace godot

namespace {
void gdash_native_initialize(godot::ModuleInitializationLevel p_level) {
	if (p_level == godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(godot::NativeTriggerRuntime);
		GDREGISTER_CLASS(godot::NativeDecorationCullWorker);
		GDREGISTER_CLASS(godot::NativeLevelRuntime);
		GDREGISTER_CLASS(godot::GdashNative);
		GDREGISTER_CLASS(godot::NativeFrustumIndex);
		GDREGISTER_CLASS(godot::NativeLevelBuildJob);
		GDREGISTER_CLASS(godot::NativeDecorationRenderer);
		GDREGISTER_CLASS(godot::NativeColorChannelIndex);
	}
}
void gdash_native_terminate(godot::ModuleInitializationLevel) {}
} // namespace

extern "C" {
GDExtensionBool GDE_EXPORT gdash_native_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(gdash_native_initialize);
	init_obj.register_terminator(gdash_native_terminate);
	init_obj.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
