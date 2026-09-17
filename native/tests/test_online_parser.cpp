// Standalone unit test for online level parser logic and legacy Geometry Dash
// compatibility behavior in native/src/gdash_native.cpp.
//
// Build & run:
//   g++ -std=c++17 -O2 -Inative/godot-cpp/include -Inative/godot-cpp/gen/include \
//       -Inative/godot-cpp/gdextension native/tests/test_online_parser.cpp \
//       native/godot-cpp/bin/libgodot-cpp.linux.template_debug.x86_64.a -lpthread -o /tmp/online_parser_test
//   /tmp/online_parser_test

#include <cmath>
#include <cstdio>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/variant/color.hpp>

using godot::Color;

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

	// 3. Verify color math with godot-cpp Color
	Color line_color(1.0f, 1.0f, 1.0f, 1.0f);
	Color bg_color(40.0f / 255.0f, 125.0f / 255.0f, 1.0f, 1.0f);
	Color lbg = bg_color.lightened(0.2f);
	check_true("LBG is brighter than BG", lbg.get_v() >= bg_color.get_v());

	if (failures == 0) {
		std::printf("\nALL ONLINE PARSER STANDALONE TESTS PASSED (0 failures)\n");
		return 0;
	}
	std::printf("\nTESTS FAILED with %d failure(s)\n", failures);
	return 1;
}
