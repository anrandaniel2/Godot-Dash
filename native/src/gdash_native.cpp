// Native hot-path kernels for Godot Dash's large-level pipeline.
//
// Godot-facing orchestration intentionally remains callable from GDScript so
// editor builds without this optional GDExtension keep working. Android uses
// these C++ kernels for compressed GMD payloads, the per-object GD property
// parser, decoration ordering/bucketing, and spatial range calculations.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/marshalls.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <numeric>
#include <vector>

namespace godot {

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
		ClassDB::bind_method(D_METHOD("decode_level_string", "encoded"), &GdashNative::decode_level_string);
		ClassDB::bind_method(D_METHOD("encode_level_string", "plain"), &GdashNative::encode_level_string);
		ClassDB::bind_method(D_METHOD("sort_decoration_indices", "z_orders", "draw_orders", "texture_ids"), &GdashNative::sort_decoration_indices);
		ClassDB::bind_method(D_METHOD("build_x_buckets", "origins", "bucket_width"), &GdashNative::build_x_buckets);
		ClassDB::bind_method(D_METHOD("visible_bucket_keys", "keys", "first", "last"), &GdashNative::visible_bucket_keys);
	}

public:
	String build_string() const {
		return String("gdash_native 0.3.0 / native decoration canvas / godot-cpp 6cceaf6a5f8b / api 4.7");
	}
	int64_t version() const { return 2; }
	int64_t add(int64_t a, int64_t b) const { return a + b; }

	Dictionary parse_gd_pairs(const String &chunk) const {
		Dictionary result;
		const PackedStringArray fields = chunk.split(",", false);
		const int64_t end = fields.size() - 1;
		for (int64_t i = 0; i < end; i += 2) {
			result[fields[i]] = fields[i + 1];
		}
		return result;
	}

	String decode_level_string(const String &encoded) const {
		String data = encoded.strip_edges();
		if (data.is_empty()) return String();
		if (data.begins_with("kS") || data.begins_with("1,") || data.contains(";1,")) return data;
		if (!data.begins_with("H4sI")) data = String("H4sIAAAAAAAAA") + data;
		Marshalls *marshalls = Marshalls::get_singleton();
		if (!marshalls) return String();
		const PackedByteArray bytes = marshalls->base64_to_raw(standard_base64(data));
		if (bytes.is_empty()) return String();
		if (bytes.size() < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return bytes.get_string_from_utf8();
		const PackedByteArray inflated = bytes.decompress_dynamic(-1, 3); // FileAccess::COMPRESSION_GZIP
		return inflated.get_string_from_utf8();
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
};

// A retained CanvasItem command builder for decoration. DecorationBatch keeps
// trigger/channel semantics in its compatibility facade, while this class
// performs the expensive atlas command emission and spatial filtering in C++.
// Godot retains the resulting draw list until queue_redraw(), so stationary
// frames execute no GDScript drawing loop at all.
class NativeDecorationCanvas : public Node2D {
	GDCLASS(NativeDecorationCanvas, Node2D)

	struct Record {
		Ref<Texture2D> texture;
		Rect2 region;
		Transform2D transform;
		Color color;
		float origin_x = 0.0f;
		float base_alpha = 1.0f;
		float hsv[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
		bool has_hsv = false;
	};

	std::vector<Record> records;
	bool cull = false;
	double bucket_width = 4096.0;
	int64_t first_bucket = INT64_MIN;
	int64_t last_bucket = INT64_MAX;

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("configure", "textures", "regions", "transforms", "colors", "origins", "base_alphas", "hsv_data", "enable_culling", "width"), &NativeDecorationCanvas::configure);
		ClassDB::bind_method(D_METHOD("set_visible_buckets", "first", "last"), &NativeDecorationCanvas::set_visible_buckets);
		ClassDB::bind_method(D_METHOD("apply_channel_color", "indices", "color"), &NativeDecorationCanvas::apply_channel_color);
		ClassDB::bind_method(D_METHOD("get_item_color", "index"), &NativeDecorationCanvas::get_item_color);
		ClassDB::bind_method(D_METHOD("set_item_color", "index", "color"), &NativeDecorationCanvas::set_item_color);
		ClassDB::bind_method(D_METHOD("set_item_transform", "index", "transform"), &NativeDecorationCanvas::set_item_transform);
		ClassDB::bind_method(D_METHOD("item_count"), &NativeDecorationCanvas::item_count);
	}

	void _notification(int what) {
		if (what != CanvasItem::NOTIFICATION_DRAW) return;
		for (const Record &record : records) {
			if (cull) {
				const int64_t bucket = static_cast<int64_t>(std::floor(record.origin_x / bucket_width));
				if (bucket < first_bucket || bucket > last_bucket) continue;
			}
			draw_set_transform_matrix(record.transform);
			draw_texture_rect_region(record.texture,
					Rect2(-record.region.size * 0.5, record.region.size),
					record.region, record.color);
		}
		draw_set_transform_matrix(Transform2D());
	}

public:
	NativeDecorationCanvas() { set_use_parent_material(true); }

	void configure(const Array &textures, const Array &regions, const Array &transforms,
			const PackedColorArray &colors, const PackedFloat32Array &origins,
			const PackedFloat32Array &base_alphas, const PackedFloat32Array &hsv_data,
			bool enable_culling, double width) {
		const int64_t count = std::min({textures.size(), regions.size(), transforms.size(), colors.size(), origins.size(), base_alphas.size()});
		records.clear();
		records.reserve(static_cast<size_t>(count));
		for (int64_t i = 0; i < count; ++i) {
			Record record;
			record.texture = textures[i];
			record.region = regions[i];
			record.transform = transforms[i];
			record.color = colors[i];
			record.origin_x = origins[i];
			record.base_alpha = base_alphas[i];
			if (hsv_data.size() >= (i + 1) * 5) {
				record.has_hsv = hsv_data[i * 5 + 4] >= 0.0f;
				for (int component = 0; component < 5; ++component) record.hsv[component] = hsv_data[i * 5 + component];
			}
			records.push_back(record);
		}
		cull = enable_culling;
		bucket_width = width > 0.0 ? width : 4096.0;
		queue_redraw();
	}

	void set_visible_buckets(int64_t first, int64_t last) {
		if (first == first_bucket && last == last_bucket) return;
		first_bucket = first;
		last_bucket = last;
		queue_redraw();
	}

	void apply_channel_color(const PackedInt32Array &indices, const Color &channel_color) {
		for (int64_t i = 0; i < indices.size(); ++i) {
			const int64_t index = indices[i];
			if (index < 0 || index >= static_cast<int64_t>(records.size())) continue;
			Record &record = records[static_cast<size_t>(index)];
			Color tinted = channel_color;
			if (record.has_hsv) {
				float hue = std::fmod(tinted.get_h() + record.hsv[0], 1.0f);
				if (hue < 0.0f) hue += 1.0f;
				const float saturation = std::clamp(record.hsv[3] > 0.5f ? tinted.get_s() + record.hsv[1] : tinted.get_s() * record.hsv[1], 0.0f, 1.0f);
				const float value = std::clamp(record.hsv[4] > 0.5f ? tinted.get_v() + record.hsv[2] : tinted.get_v() * record.hsv[2], 0.0f, 1.0f);
				tinted = Color::from_hsv(hue, saturation, value, channel_color.a);
			}
			tinted.a = channel_color.a * record.base_alpha;
			record.color = tinted;
		}
		queue_redraw();
	}

	Color get_item_color(int64_t index) const {
		if (index < 0 || index >= static_cast<int64_t>(records.size())) return Color(1, 1, 1, 1);
		return records[static_cast<size_t>(index)].color;
	}

	void set_item_color(int64_t index, const Color &color) {
		if (index < 0 || index >= static_cast<int64_t>(records.size())) return;
		records[static_cast<size_t>(index)].color = color;
		queue_redraw();
	}

	void set_item_transform(int64_t index, const Transform2D &transform) {
		if (index < 0 || index >= static_cast<int64_t>(records.size())) return;
		records[static_cast<size_t>(index)].transform = transform;
		queue_redraw();
	}

	int64_t item_count() const { return static_cast<int64_t>(records.size()); }
};

} // namespace godot

namespace {
void gdash_native_initialize(godot::ModuleInitializationLevel p_level) {
	if (p_level == godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(godot::GdashNative);
		GDREGISTER_CLASS(godot::NativeDecorationCanvas);
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
