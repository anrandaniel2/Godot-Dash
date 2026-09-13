// Standalone test for the native trigger effect engine's pure math: the 19
// Geometry Dash easing curves ported onto Godot's Tween transitions. Runs
// without the engine (godot-cpp's Math header is self-contained); the
// property-parsing side is exercised end-to-end by the engine-hosted smoke
// test (tools/runtime_visual_smoke_test.gd), which asserts moved offsets,
// colour fades, pulse envelopes, zoom values and timewarp targets.
//
// Build & run:
//   g++ -std=c++17 -O2 -Inative/godot-cpp/include -Inative/godot-cpp/gen/include \
//       -Inative/godot-cpp/gdextension native/tests/test_trigger_effect_parse.cpp \
//       native/godot-cpp/bin/libgodot-cpp.linux.template_release.x86_64.a -lpthread -o /tmp/trigger_test
//   /tmp/trigger_test

#include "../src/gdash_native.cpp"

#include <cmath>
#include <cstdio>

using namespace godot;

static int failures = 0;

static void expect_close(const char *name, double actual, double expected, double epsilon = 1e-6) {
	if (std::fabs(actual - expected) > epsilon) {
		std::printf("FAIL %s: expected %f, got %f\n", name, expected, actual);
		++failures;
	}
}

static void expect_true(const char *name, bool condition) {
	if (!condition) {
		std::printf("FAIL %s\n", name);
		++failures;
	}
}

int main() {
	// GD easing order: 0 linear; 1-3 quad in-out/in/out; 4-6 elastic;
	// 7-9 bounce; 10-12 expo; 13-15 sine; 16-18 back.
	expect_close("linear", ease_weight(0, 0.25), 0.25);
	expect_close("quad in-out at 0.25", ease_weight(1, 0.25), 0.125);
	expect_close("quad in at 0.5", ease_weight(2, 0.5), 0.25);
	expect_close("quad out at 0.5", ease_weight(3, 0.5), 0.75);
	expect_close("quad in-out at 0.75", ease_weight(1, 0.75), 0.875);
	expect_close("expo in at 0.5", ease_weight(11, 0.5), std::pow(2.0, -5.0));
	expect_close("expo out at 0.5", ease_weight(12, 0.5), 1.0 - std::pow(2.0, -5.0));
	expect_close("sine in-out at 0.5", ease_weight(13, 0.5), 0.5);
	expect_close("sine out at 0.25", ease_weight(15, 0.25), std::sin(0.25 * Math::PI / 2.0));
	expect_close("bounce out at 0.5", ease_weight(9, 0.5), 7.5625 * std::pow(0.5 - 1.5 / 2.75, 2.0) + 0.75);
	// Back out overshoots above 1 before settling at 1.
	const double back_out_half = ease_weight(18, 0.5);
	expect_true("back out overshoots", back_out_half > 1.0 && back_out_half < 1.15);
	// Elastic out overshoots just above 1 at the midpoint (its bounce) and
	// lands exactly on 1 at the end.
	const double elastic_out_half = ease_weight(6, 0.5);
	expect_true("elastic out midpoint sane", elastic_out_half > 0.9 && elastic_out_half < 1.1);
	// Endpoints hold for every curve index, and unknown indices are linear.
	for (int i = 0; i <= 18; ++i) {
		expect_close("easing start", ease_weight(i, 0.0), 0.0);
		expect_close("easing end", ease_weight(i, 1.0), 1.0);
	}
	expect_close("unknown easing is linear", ease_weight(19, 0.3), 0.3);
	expect_close("negative easing is linear", ease_weight(-1, 0.3), 0.3);
	// Weights clamp outside [0, 1] for every curve.
	expect_close("clamped low", ease_weight(2, -1.0), 0.0);
	expect_close("clamped high", ease_weight(3, 4.0), 1.0);
	// The family/mode decomposition maps every index as the converter does.
	expect_true("family of easing 5 is elastic", 5 >= 4 && 5 <= 6);
	expect_true("mode of easing 5 is in", (5 - 1) % 3 == 1);

	if (failures == 0) {
		std::printf("trigger easing curves: all checks passed\n");
		return 0;
	}
	std::printf("trigger easing curves: %d failure(s)\n", failures);
	return 1;
}
