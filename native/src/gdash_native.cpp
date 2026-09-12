// Native hot-path kernels for Godot Dash's large-level pipeline.
//
// Godot-facing orchestration intentionally remains callable from GDScript so
// editor builds without this optional GDExtension keep working. Android uses
// these C++ kernels for compressed GMD payloads, the per-object GD property
// parser, decoration ordering/bucketing, and spatial range calculations.

#include <godot_cpp/classes/camera2d.hpp>
#include <godot_cpp/classes/canvas_item.hpp>
#include <godot_cpp/classes/collision_shape2d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/shape2d.hpp>
#include <godot_cpp/classes/marshalls.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
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

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <numeric>
#include <set>
#include <vector>

namespace godot {

// Packed trigger scheduler. One instance replaces thousands of Area2D broad-
// phase checks: trigger crossings, spawn/event delays, activation state and
// checkpoint snapshots stay in C++. Trigger effects are still emitted through
// the existing Interactable signal so families can migrate incrementally
// without changing their observable behaviour.
class NativeTriggerRuntime : public RefCounted {
	GDCLASS(NativeTriggerRuntime, RefCounted)

	enum Flags : int32_t {
		SPAWN_ONLY = 1,
		TOUCH_ONLY = 2,
		MULTI_ACTIVATE = 4,
	};
	struct Record {
		double x = 0.0;
		ObjectID object;
		int64_t source_order = 0;
		int32_t flags = 0;
		int64_t gd_id = 0;
		Dictionary properties;
		bool activated = false;
	};
	struct Event {
		double due = 0.0;
		uint64_t sequence = 0;
		StringName group;
		ObjectID player;
	};
	std::vector<Record> records;
	std::vector<size_t> x_order;
	// Direct group -> record index lookup makes spawn/event dispatch proportional
	// to the target group, not to every trigger in a 100k-object level.
	std::map<String, std::vector<size_t>> group_index;
	// Min-heap ordered by due time/source sequence. Inserting a spawn event is
	// O(log n), replacing the old full stable_sort after every insertion.
	std::vector<Event> events;
	double clock = 0.0;
	uint64_t event_sequence = 0;
	bool index_dirty = false;

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

	void activate(size_t index, Object *player, bool forced = false) {
		if (index >= records.size()) return;
		Record &record = records[index];
		if (record.activated && !(record.flags & MULTI_ACTIVATE)) return;
		if (!forced && (record.flags & (SPAWN_ONLY | TOUCH_ONLY))) return;
		if (!player) return;
		// Spawn is scheduled entirely here. The old component has no faithful
		// representation for GD's target-group property and otherwise warns with
		// an empty authored resource list.
		if (record.gd_id == 1268) {
			const String target_id = String(record.properties.get("51", "")).strip_edges();
			const String delay_text = String(record.properties.get("63", "0")).strip_edges();
			if (target_id.is_valid_int() && target_id.to_int() > 0)
				schedule_group(StringName("g_" + target_id), delay_text.is_valid_float() ? delay_text.to_float() : 0.0, player);
		} else {
			Object *target = ObjectDB::get_instance(record.object);
			if (target) target->call("emit_signal", StringName("interacted"), player);
		}
		if (!(record.flags & MULTI_ACTIVATE)) record.activated = true;
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("clear"), &NativeTriggerRuntime::clear);
		ClassDB::bind_method(D_METHOD("register_trigger", "trigger", "x", "flags", "source_order", "groups", "gd_id", "properties"), &NativeTriggerRuntime::register_trigger);
		ClassDB::bind_method(D_METHOD("register_packed_trigger", "x", "flags", "source_order", "groups", "gd_id", "properties"), &NativeTriggerRuntime::register_packed_trigger);
		ClassDB::bind_method(D_METHOD("finalize"), &NativeTriggerRuntime::finalize);
		ClassDB::bind_method(D_METHOD("advance", "player", "previous_x", "current_x"), &NativeTriggerRuntime::advance);
		ClassDB::bind_method(D_METHOD("activate_touch", "record_index", "player"), &NativeTriggerRuntime::activate_touch);
		ClassDB::bind_method(D_METHOD("schedule_group", "group", "delay", "player"), &NativeTriggerRuntime::schedule_group);
		ClassDB::bind_method(D_METHOD("tick", "delta"), &NativeTriggerRuntime::tick);
		ClassDB::bind_method(D_METHOD("reset"), &NativeTriggerRuntime::reset);
		ClassDB::bind_method(D_METHOD("snapshot"), &NativeTriggerRuntime::snapshot);
		ClassDB::bind_method(D_METHOD("restore", "state"), &NativeTriggerRuntime::restore);
		ClassDB::bind_method(D_METHOD("trigger_count"), &NativeTriggerRuntime::trigger_count);
		ClassDB::bind_integer_constant(get_class_static(), "Flags", "SPAWN_ONLY", SPAWN_ONLY);
		ClassDB::bind_integer_constant(get_class_static(), "Flags", "TOUCH_ONLY", TOUCH_ONLY);
		ClassDB::bind_integer_constant(get_class_static(), "Flags", "MULTI_ACTIVATE", MULTI_ACTIVATE);
	}

public:
	void clear() {
		records.clear(); x_order.clear(); group_index.clear(); events.clear(); clock = 0.0;
		event_sequence = 0; index_dirty = false;
	}
	int64_t register_trigger(Object *trigger, double x, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		Record record;
		record.x = x;
		if (trigger) record.object = trigger->get_instance_id();
		record.flags = static_cast<int32_t>(flags); record.source_order = source_order;
		record.gd_id = gd_id; record.properties = properties;
		const size_t index = records.size();
		for (int64_t i = 0; i < groups.size(); ++i)
			group_index[String(groups[i])].push_back(index);
		records.push_back(std::move(record)); index_dirty = true;
		return static_cast<int64_t>(index);
	}
	int64_t register_packed_trigger(double x, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		return register_trigger(nullptr, x, flags, source_order, groups, gd_id, properties);
	}
	void finalize() {
		ensure_index();
		records.shrink_to_fit();
		x_order.shrink_to_fit();
		for (auto &entry : group_index) {
			std::stable_sort(entry.second.begin(), entry.second.end(), [&](size_t a, size_t b) {
				return records[a].source_order < records[b].source_order;
			});
			entry.second.shrink_to_fit();
		}
	}
	void advance(Object *player, double previous_x, double current_x) {
		if (!player || Math::is_equal_approx(previous_x, current_x)) return;
		ensure_index();
		auto index_before_value = [&](size_t index, double value) { return records[index].x < value; };
		if (current_x > previous_x) {
			// (previous_x, current_x] in O(log n + crossed), rather than scanning
			// every trigger from the start once per player and physics frame.
			auto first = std::upper_bound(x_order.begin(), x_order.end(), previous_x,
				[&](double value, size_t index) { return value < records[index].x; });
			auto last = std::upper_bound(x_order.begin(), x_order.end(), current_x,
				[&](double value, size_t index) { return value < records[index].x; });
			for (auto it = first; it != last; ++it) activate(*it, player);
		} else {
			// [current_x, previous_x), preserving descending spatial/source order.
			auto first = std::lower_bound(x_order.begin(), x_order.end(), current_x, index_before_value);
			auto last = std::lower_bound(x_order.begin(), x_order.end(), previous_x, index_before_value);
			for (auto it = std::make_reverse_iterator(last); it != std::make_reverse_iterator(first); ++it) activate(*it, player);
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
		while (!events.empty() && events.front().due <= clock && dispatched < 10000) {
			std::pop_heap(events.begin(), events.end(), event_later);
			const Event event = std::move(events.back());
			events.pop_back();
			Object *player = ObjectDB::get_instance(event.player);
			if (player) {
				auto group = group_index.find(String(event.group));
				if (group != group_index.end()) {
					for (size_t index : group->second) activate(index, player, true);
				}
			}
			++dispatched;
		}
	}
	void reset() {
		for (Record &record : records) record.activated = false;
		events.clear(); clock = 0.0; event_sequence = 0;
	}
	Dictionary snapshot() const {
		Dictionary state; PackedByteArray active;
		active.resize(records.size());
		for (size_t i = 0; i < records.size(); ++i) active.set(i, records[i].activated ? 1 : 0);
		state["active"] = active; state["clock"] = clock;
		return state;
	}
	void restore(const Dictionary &state) {
		const PackedByteArray active = state.get("active", PackedByteArray());
		for (size_t i = 0; i < records.size(); ++i) records[i].activated = i < static_cast<size_t>(active.size()) && active[i] != 0;
		clock = state.get("clock", 0.0); events.clear();
	}
	int64_t trigger_count() const { return static_cast<int64_t>(records.size()); }
};

// Native owner for the packed runtime. Besides being the migration point for
// rendering/collision stores, this removes the last per-physics-frame
// GDScript->GDExtension calls: player discovery, crossing queries and event
// clock advancement happen in one C++ notification.
class NativeLevelRuntime : public Node {
	GDCLASS(NativeLevelRuntime, Node)

	Ref<NativeTriggerRuntime> triggers;
	Node *level_manager = nullptr;
	std::map<uint64_t, double> previous_x;

	void advance_player(Object *object) {
		Node2D *player = Object::cast_to<Node2D>(object);
		if (!player) return;
		const uint64_t id = static_cast<uint64_t>(player->get_instance_id());
		const double x = player->get_global_position().x;
		auto previous = previous_x.find(id);
		if (previous != previous_x.end()) triggers->advance(player, previous->second, x);
		previous_x[id] = x;
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("clear"), &NativeLevelRuntime::clear);
		ClassDB::bind_method(D_METHOD("register_trigger", "trigger", "x", "flags", "source_order", "groups", "gd_id", "properties"), &NativeLevelRuntime::register_trigger);
		ClassDB::bind_method(D_METHOD("register_packed_trigger", "x", "flags", "source_order", "groups", "gd_id", "properties"), &NativeLevelRuntime::register_packed_trigger);
		ClassDB::bind_method(D_METHOD("finalize"), &NativeLevelRuntime::finalize);
		ClassDB::bind_method(D_METHOD("reset"), &NativeLevelRuntime::reset);
		ClassDB::bind_method(D_METHOD("snapshot"), &NativeLevelRuntime::snapshot);
		ClassDB::bind_method(D_METHOD("restore", "state"), &NativeLevelRuntime::restore);
		ClassDB::bind_method(D_METHOD("trigger_count"), &NativeLevelRuntime::trigger_count);
	}

	void _notification(int what) {
		if (what == Node::NOTIFICATION_READY) {
			SceneTree *tree = Object::cast_to<SceneTree>(Engine::get_singleton()->get_main_loop());
			if (tree) level_manager = tree->get_root()->get_node_or_null(NodePath("LevelManager"));
			set_physics_process(true);
			return;
		}
		if (what != Node::NOTIFICATION_PHYSICS_PROCESS || !level_manager || !triggers.is_valid()) return;
		if (!static_cast<bool>(level_manager->get("level_playing"))) return;
		Variant main_value = level_manager->get("player");
		Object *main_player = main_value;
		advance_player(main_player);
		const Array duals = level_manager->get("player_duals");
		for (int64_t i = 0; i < duals.size(); ++i) {
			Object *dual = duals[i];
			advance_player(dual);
		}
		triggers->tick(get_physics_process_delta_time());
	}

public:
	NativeLevelRuntime() { triggers.instantiate(); }

	void clear() { triggers->clear(); previous_x.clear(); }
	int64_t register_trigger(Object *trigger, double x, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		return triggers->register_trigger(trigger, x, flags, source_order, groups, gd_id, properties);
	}
	int64_t register_packed_trigger(double x, int64_t flags, int64_t source_order, const PackedStringArray &groups, int64_t gd_id, const Dictionary &properties) {
		return triggers->register_packed_trigger(x, flags, source_order, groups, gd_id, properties);
	}
	void finalize() { triggers->finalize(); }
	void reset() { triggers->reset(); previous_x.clear(); }
	Dictionary snapshot() const { return triggers->snapshot(); }
	void restore(const Dictionary &state) { triggers->restore(state); previous_x.clear(); }
	int64_t trigger_count() const { return triggers->trigger_count(); }
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
		return String("gdash_native 1.4.0 / retained section renderer / NativeLevelRuntime / profiled LTO / api 4.7");
	}
	int64_t version() const { return 14; }
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
		Variant value = level_script->call("instantiate_object_from_data", object_data, level);
		Object *object = value;
		Node *node = Object::cast_to<Node>(object);
		if (!node) return;
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
		float base_alpha = 1.0f;
		float hsv[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
		bool has_hsv = false;
	};

	std::vector<Record> records;
	// One origin section per record, modelled after OpenGD's _sectionObjects.
	// Exact transformed bounds still make the final decision, while this index
	// avoids testing every sprite in the level on every scrolling frame.
	std::map<int64_t, std::vector<size_t>> sections;
	bool cull = false;
	double bucket_width = 1024.0;
	double cull_margin = 0.0;
	double max_local_radius = 0.0;
	int64_t first_bucket = INT64_MIN;
	int64_t last_bucket = INT64_MAX;
	Vector2 last_viewport_size;
	bool view_initialized = false;
	int64_t last_drawn_items = 0;

	bool update_view_range() {
		if (!cull || !is_inside_tree()) return false;
		const Transform2D from_screen = get_global_transform_with_canvas().affine_inverse();
		const Vector2 screen_size = get_viewport_rect().size;
		Rect2 local_view(from_screen.xform(Vector2()), Vector2());
		local_view = local_view.expand(from_screen.xform(Vector2(screen_size.x, 0.0)));
		local_view = local_view.expand(from_screen.xform(screen_size));
		local_view = local_view.expand(from_screen.xform(Vector2(0.0, screen_size.y)));
		local_view = local_view.grow(max_local_radius + cull_margin);
		const int64_t first = static_cast<int64_t>(std::floor(local_view.position.x / bucket_width));
		const int64_t last = static_cast<int64_t>(std::floor(local_view.get_end().x / bucket_width));
		const bool changed = !view_initialized || first != first_bucket || last != last_bucket || screen_size != last_viewport_size;
		first_bucket = first;
		last_bucket = last;
		last_viewport_size = screen_size;
		view_initialized = true;
		return changed;
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("configure", "textures", "regions", "transforms", "colors", "origins", "base_alphas", "hsv_data", "enable_culling", "width", "margin"), &NativeDecorationCanvas::configure);
		ClassDB::bind_method(D_METHOD("set_visible_buckets", "first", "last"), &NativeDecorationCanvas::set_visible_buckets);
		ClassDB::bind_method(D_METHOD("apply_channel_color", "indices", "color"), &NativeDecorationCanvas::apply_channel_color);
		ClassDB::bind_method(D_METHOD("get_item_color", "index"), &NativeDecorationCanvas::get_item_color);
		ClassDB::bind_method(D_METHOD("set_item_color", "index", "color"), &NativeDecorationCanvas::set_item_color);
		ClassDB::bind_method(D_METHOD("set_item_transform", "index", "transform"), &NativeDecorationCanvas::set_item_transform);
		ClassDB::bind_method(D_METHOD("item_count"), &NativeDecorationCanvas::item_count);
		ClassDB::bind_method(D_METHOD("last_drawn_count"), &NativeDecorationCanvas::last_drawn_count);
	}

	void _notification(int what) {
		if (what == Node::NOTIFICATION_PROCESS && cull && is_inside_tree()) {
			// Canvas commands are retained and automatically transformed/clipped by
			// RenderingServer. Rebuild only when the conservative section range
			// changes, not for every pixel of camera movement.
			if (update_view_range()) queue_redraw();
			return;
		}
		if (what != CanvasItem::NOTIFICATION_DRAW) return;

		last_drawn_items = 0;
		if (cull && !view_initialized) update_view_range();
		auto draw_record = [&](const Record &record) {
			const Rect2 quad(-record.region.size * 0.5, record.region.size);
			draw_set_transform_matrix(record.transform);
			draw_texture_rect_region(record.texture, quad, record.region, record.color);
			++last_drawn_items;
		};

		if (!cull) {
			for (const Record &record : records) draw_record(record);
		} else {
			// Objects in the selected sections become retained canvas commands.
			// Off-screen quads are clipped by RenderingServer and never rasterized;
			// avoiding CPU command regeneration each frame is far cheaper than an
			// exact AABB test and redraw for every scrolling pixel.
			auto section = sections.lower_bound(first_bucket);
			while (section != sections.end() && section->first <= last_bucket) {
				for (size_t index : section->second) draw_record(records[index]);
				++section;
			}
		}
		draw_set_transform_matrix(Transform2D());
	}

public:
	NativeDecorationCanvas() { set_use_parent_material(true); }

	void configure(const Array &textures, const Array &regions, const Array &transforms,
			const PackedColorArray &colors, const PackedFloat32Array &origins,
			const PackedFloat32Array &base_alphas, const PackedFloat32Array &hsv_data,
			bool enable_culling, double width, double margin) {
		const int64_t count = std::min({textures.size(), regions.size(), transforms.size(), colors.size(), origins.size(), base_alphas.size()});
		records.clear();
		sections.clear();
		records.reserve(static_cast<size_t>(count));
		max_local_radius = 0.0;
		bucket_width = width > 0.0 ? width : 1024.0;
		for (int64_t i = 0; i < count; ++i) {
			Record record;
			record.texture = textures[i];
			record.region = regions[i];
			record.transform = transforms[i];
			record.color = colors[i];
			record.base_alpha = base_alphas[i];
			if (hsv_data.size() >= (i + 1) * 5) {
				record.has_hsv = hsv_data[i * 5 + 4] >= 0.0f;
				for (int component = 0; component < 5; ++component) record.hsv[component] = hsv_data[i * 5 + component];
			}
			const Rect2 quad(-record.region.size * 0.5, record.region.size);
			const Rect2 bounds = record.transform.xform(quad);
			// Radius conservatively includes artwork whose centre lies just outside
			// the selected section range.
			const Vector2 extent = bounds.size * 0.5;
			max_local_radius = std::max(max_local_radius, static_cast<double>(extent.length()));
			const size_t index = records.size();
			records.push_back(record);
			sections[static_cast<int64_t>(std::floor(origins[i] / bucket_width))].push_back(index);
		}
		cull = enable_culling;
		cull_margin = std::max(0.0, margin);
		view_initialized = false;
		set_process(cull);
		if (!cull) {
			first_bucket = INT64_MIN;
			last_bucket = INT64_MAX;
		}
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
	int64_t last_drawn_count() const { return last_drawn_items; }
};

} // namespace godot

namespace {
void gdash_native_initialize(godot::ModuleInitializationLevel p_level) {
	if (p_level == godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(godot::NativeTriggerRuntime);
		GDREGISTER_CLASS(godot::NativeLevelRuntime);
		GDREGISTER_CLASS(godot::GdashNative);
		GDREGISTER_CLASS(godot::NativeFrustumIndex);
		GDREGISTER_CLASS(godot::NativeLevelBuildJob);
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
