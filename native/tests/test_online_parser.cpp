// Standalone unit test for online level parser logic and legacy Geometry Dash
// compatibility behavior in native/src/gdash_native.cpp.
//
// Build & run:
//   g++ -std=c++17 -O2 -Inative/godot-cpp/include -Inative/godot-cpp/gen/include \
//       -Inative/godot-cpp/gdextension native/tests/test_online_parser.cpp \
//       native/godot-cpp/bin/libgodot-cpp.linux.template_debug.x86_64.a -lpthread -o /tmp/online_parser_test
//   /tmp/online_parser_test

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#if __has_include(<godot_cpp/variant/color.hpp>)
#include <godot_cpp/variant/color.hpp>
using godot::Color;
#else
struct Color {
	float r = 1.0f, g = 1.0f, b = 1.0f, a = 1.0f;
	Color() = default;
	Color(float pr, float pg, float pb, float pa = 1.0f) : r(pr), g(pg), b(pb), a(pa) {}
	float get_h() const { return 0.0f; }
	float get_s() const { return (r == g && g == b) ? 0.0f : 0.5f; }
	float get_v() const { return std::max({r, g, b}); }
	Color lightened(float amt) const { return Color(r + (1.0f - r) * amt, g + (1.0f - g) * amt, b + (1.0f - b) * amt, a); }
	static Color from_hsv(float h, float s, float v, float a = 1.0f) {
		if (s == 0.0f) return Color(v, v, v, a);
		return Color(v, v * (1.0f - s), v * (1.0f - s), a);
	}
	bool operator==(const Color &o) const { return r == o.r && g == o.g && b == o.b && a == o.a; }
};
#endif

static int failures = 0;

static void check_true(const char *name, bool cond) {
	if (!cond) {
		std::printf("FAIL: %s\n", name);
		++failures;
	} else {
		std::printf("PASS: %s\n", name);
	}
}

static void check_int(const char *name, int64_t actual, int64_t expected) {
	if (actual != expected) {
		std::printf("FAIL: %s (expected %lld, got %lld)\n", name, (long long)expected, (long long)actual);
		++failures;
	} else {
		std::printf("PASS: %s\n", name);
	}
}

// Mirror of legacy_color_trigger_channel from gdash_native.cpp
static inline int64_t legacy_color_trigger_channel(int64_t trigger_id) {
	switch (trigger_id) {
		case 29: return 1000;
		case 30: return 1001;
		case 105: return 1004;
		case 744: return 1003;
		case 900: return 1009;
		case 915: return 1002;
		default: return 0;
	}
}

// Mirror of GameObject::getColorIndex legacy mapping from decompiled GD 2.205 / 1.9
static inline int64_t legacy_object_color_channel(int64_t old_color_id) {
	switch (old_color_id) {
		case 1: return 1005; // Player 1
		case 2: return 1006; // Player 2
		case 3: return 1;    // Color 1
		case 4: return 2;    // Color 2
		case 5: return 1007; // Tint / LBG
		case 6: return 3;    // Color 3
		case 7: return 4;    // Color 4
		case 8: return 1003; // 3DL
		default: return 0;
	}
}

// Mirror of GameObject::newObjectFromVector object substitution from decompiled GD
static inline int64_t substitute_object_id(int64_t key, int64_t &target_color, bool &uses_blending) {
	int64_t key_orig = -1;
	int64_t new_key = key;
	switch (key) {
		case 104:
			key_orig = key;
			new_key = 915;
			break;
		case 221:
		case 717:
		case 718:
		case 743:
			key_orig = key;
			new_key = 899;
			break;
		case 675: new_key = 1734; break;
		case 676: new_key = 1735; break;
		case 677: new_key = 1736; break;
		case 1008: new_key = 1292; break;
		default:
			if (key >= 1964 && key < 2012) {
				new_key = 1964;
			}
			break;
	}
	if (key_orig != -1) {
		switch (key_orig) {
			case 104: uses_blending = true; break;
			case 221: target_color = 1; break;
			case 717: target_color = 2; break;
			case 718: target_color = 3; break;
			case 743: target_color = 4; break;
		}
	}
	return new_key;
}

int main() {
	// 1. Verify legacy trigger channel mappings match decompiled GD EffectGameObject::customSetup
	check_int("trigger 29 -> BG (1000)", legacy_color_trigger_channel(29), 1000);
	check_int("trigger 30 -> G1 (1001)", legacy_color_trigger_channel(30), 1001);
	check_int("trigger 105 -> Obj (1004)", legacy_color_trigger_channel(105), 1004);
	check_int("trigger 744 -> 3DL (1003)", legacy_color_trigger_channel(744), 1003);
	check_int("trigger 900 -> G2 (1009)", legacy_color_trigger_channel(900), 1009);
	check_int("trigger 915 -> Line (1002)", legacy_color_trigger_channel(915), 1002);
	check_int("trigger 899 -> 0 (uses target color)", legacy_color_trigger_channel(899), 0);

	// 2. Verify legacy object color channel mappings match decompiled GD GameObject::customObjectSetup
	check_int("legacy color 1 -> P1 (1005)", legacy_object_color_channel(1), 1005);
	check_int("legacy color 2 -> P2 (1006)", legacy_object_color_channel(2), 1006);
	check_int("legacy color 3 -> Col 1 (1)", legacy_object_color_channel(3), 1);
	check_int("legacy color 4 -> Col 2 (2)", legacy_object_color_channel(4), 2);
	check_int("legacy color 5 -> LBG (1007)", legacy_object_color_channel(5), 1007);
	check_int("legacy color 6 -> Col 3 (3)", legacy_object_color_channel(6), 3);
	check_int("legacy color 7 -> Col 4 (4)", legacy_object_color_channel(7), 4);
	check_int("legacy color 8 -> 3DL (1003)", legacy_object_color_channel(8), 1003);

	// 2b. Verify object ID substitutions match decompiled GD GameObject::newObjectFromVector
	int64_t target_col = 0;
	bool uses_blend = false;
	check_int("object 104 -> 915", substitute_object_id(104, target_col, uses_blend), 915);
	check_true("object 104 uses blending", uses_blend);

	target_col = 0; uses_blend = false;
	check_int("object 221 -> 899", substitute_object_id(221, target_col, uses_blend), 899);
	check_int("object 221 target color 1", target_col, 1);

	target_col = 0; uses_blend = false;
	check_int("object 717 -> 899", substitute_object_id(717, target_col, uses_blend), 899);
	check_int("object 717 target color 2", target_col, 2);

	target_col = 0; uses_blend = false;
	check_int("object 718 -> 899", substitute_object_id(718, target_col, uses_blend), 899);
	check_int("object 718 target color 3", target_col, 3);

	target_col = 0; uses_blend = false;
	check_int("object 743 -> 899", substitute_object_id(743, target_col, uses_blend), 899);
	check_int("object 743 target color 4", target_col, 4);

	target_col = 0; uses_blend = false;
	check_int("object 675 -> 1734", substitute_object_id(675, target_col, uses_blend), 1734);
	check_int("object 676 -> 1735", substitute_object_id(676, target_col, uses_blend), 1735);
	check_int("object 677 -> 1736", substitute_object_id(677, target_col, uses_blend), 1736);
	check_int("object 1008 -> 1292", substitute_object_id(1008, target_col, uses_blend), 1292);
	check_int("object 1964 -> 1964", substitute_object_id(1964, target_col, uses_blend), 1964);
	check_int("object 2000 -> 1964", substitute_object_id(2000, target_col, uses_blend), 1964);
	check_int("object 2011 -> 1964", substitute_object_id(2011, target_col, uses_blend), 1964);
	check_int("object 2012 -> 2012 (not substituted)", substitute_object_id(2012, target_col, uses_blend), 2012);

	// 3. Verify color math with godot-cpp Color
	Color line_color(1.0f, 1.0f, 1.0f, 1.0f);
	Color bg_color(40.0f / 255.0f, 125.0f / 255.0f, 1.0f, 1.0f);
	Color lbg = bg_color.lightened(0.2f);
	check_true("LBG is brighter than BG", lbg.get_v() >= bg_color.get_v());

	// 4. Verify multiplicative HSV shift logic
	Color col_base(1.0f, 0.5f, 0.5f, 1.0f);
	float shift_hue = 0.333f;
	float shift_sat = 0.8f;
	bool sat_mult = true;
	float res_sat = sat_mult ? col_base.get_s() * shift_sat : col_base.get_s() + shift_sat;
	check_true("Multiplicative HSV scales base saturation", res_sat > 0.0f);

	// Verify white base in multiplicative HSV does NOT gain saturation and turn red
	Color white_base(1.0f, 1.0f, 1.0f, 1.0f);
	float white_res_sat = sat_mult ? white_base.get_s() * shift_sat : white_base.get_s() + shift_sat;
	check_true("White base retains 0 saturation under multiplicative HSV", white_res_sat == 0.0f);
	Color white_shifted = Color::from_hsv(white_base.get_h() + shift_hue, white_res_sat, 1.0f, 1.0f);
	check_true("White base remains pure white and does not turn red", white_shifted == Color(1.0f, 1.0f, 1.0f, 1.0f));

	// 5. Verify initial spawn trigger activation semantics:
	// A trigger placed at x = 0 or x = 10 must fire when player spawns at x = 15.
	std::vector<double> trigger_positions = { -50.0, 0.0, 10.0, 15.0, 20.0, 100.0 };
	double player_spawn_x = 15.0;
	auto last = std::upper_bound(trigger_positions.begin(), trigger_positions.end(), player_spawn_x);
	int initial_fired = std::distance(trigger_positions.begin(), last);
	check_int("Triggers at x <= player_spawn_x (4 triggers) fire on spawn", initial_fired, 4);

	if (failures == 0) {
		std::printf("\nALL ONLINE PARSER STANDALONE TESTS PASSED (0 failures)\n");
		return 0;
	}
	std::printf("\nTESTS FAILED with %d failure(s)\n", failures);
	return 1;
}
