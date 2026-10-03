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

static void expect_close(const char *name, double actual, double expected, double epsilon = 1e-4) {
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

	// is_shader_kind helper test
	expect_true("gray is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_GRAYSCALE));
	expect_true("sepia is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_SEPIA));
	expect_true("lens is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_LENS_CIRCLE));
	expect_true("invert is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_INVERT_COLOR));
	expect_true("move is not shader kind", !NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::MOVE));
	expect_true("color is not shader kind", !NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::COLOR));
	expect_true("ui is not shader kind", !NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::UI));

	// UI Trigger (ID 3613) compute_ui_anchor alignment math tests
	const Vector2 vp_16_9(1920.0, 1080.0);
	// 16:9 (aspect 1.7778 > 1.5): H_ref = 1080/0.8 = 1350, W_ref = 2025, W_active = 2400, delta_x = 187.5
	// Center offset stays at center
	const Vector2 center_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, 0.0), 0, 0, false, false, vp_16_9);
	expect_close("16:9 center X", center_anchor.x, 0.0);
	expect_close("16:9 center Y", center_anchor.y, 0.0);

	// Left alignment on left edge: offset.x = -1012.5 -> anchor.x = -1200.0 (lands at screen 0 px)
	const Vector2 left_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(-1012.5, -200.0), 3, 0, false, false, vp_16_9);
	expect_close("16:9 left edge X", left_anchor.x, -1200.0);
	expect_close("16:9 left edge Y preserved", left_anchor.y, -200.0);

	// Right alignment on right edge: offset.x = +1012.5 -> anchor.x = +1200.0 (lands at screen 1920 px)
	const Vector2 right_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(1012.5, 150.0), 4, 0, false, false, vp_16_9);
	expect_close("16:9 right edge X", right_anchor.x, 1200.0);
	expect_close("16:9 right edge Y preserved", right_anchor.y, 150.0);

	// Auto_x alignment: negative offset chooses left, positive chooses right
	const Vector2 auto_l = NativeTriggerRuntime::compute_ui_anchor(Vector2(-500.0, 0.0), 1, 0, false, false, vp_16_9);
	expect_close("16:9 auto negative selects left", auto_l.x, -500.0 - 187.5);
	const Vector2 auto_r = NativeTriggerRuntime::compute_ui_anchor(Vector2(500.0, 0.0), 1, 0, false, false, vp_16_9);
	expect_close("16:9 auto positive selects right", auto_r.x, 500.0 + 187.5);

	// Center_x alignment: maintains offset from center regardless of aspect ratio
	const Vector2 center_x = NativeTriggerRuntime::compute_ui_anchor(Vector2(350.0, -100.0), 2, 0, false, false, vp_16_9);
	expect_close("16:9 center_x keeps offset", center_x.x, 350.0);

	// Relative mode: scales proportionally between center and edge
	const Vector2 rel_half = NativeTriggerRuntime::compute_ui_anchor(Vector2(-506.25, 0.0), 3, 0, true, false, vp_16_9);
	expect_close("16:9 relative proportional scale", rel_half.x, -600.0);

	// 4:3 (aspect 1.3333 < 1.5): W_ref = 1440/0.8 = 1800, H_ref = 1200, H_active = 1350, delta_y = 75.0
	const Vector2 vp_4_3(1440.0, 1080.0);
	const Vector2 top_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(100.0, -600.0), 0, 8, false, false, vp_4_3);
	expect_close("4:3 top edge Y", top_anchor.y, -675.0); // 540 + (-675 * 0.8) = 0 px
	expect_close("4:3 top edge X preserved", top_anchor.x, 100.0);

	const Vector2 btm_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(100.0, 600.0), 0, 7, false, false, vp_4_3);
	expect_close("4:3 bottom edge Y", btm_anchor.y, 675.0); // 540 + (675 * 0.8) = 1080 px

	const Vector2 auto_top = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, -300.0), 0, 5, false, false, vp_4_3);
	expect_close("4:3 auto negative selects top", auto_top.y, -300.0 - 75.0);
	const Vector2 auto_btm = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, 300.0), 0, 5, false, false, vp_4_3);
	expect_close("4:3 auto positive selects bottom", auto_btm.y, 300.0 + 75.0);

	const Vector2 rel_y = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, -300.0), 0, 8, false, true, vp_4_3);
	expect_close("4:3 relative Y proportional scale", rel_y.y, -300.0 * (1350.0 / 1200.0));

	if (failures == 0) {
		std::printf("trigger easing curves & shader effects: all checks passed\n");
		return 0;
	}
	std::printf("trigger easing curves: %d failure(s)\n", failures);
	return 1;
}
