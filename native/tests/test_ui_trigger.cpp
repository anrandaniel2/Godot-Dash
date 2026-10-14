// Unit test for Geometry Dash 2.2 UI Trigger (ID 3613) alignment math,
// edge offset calculations, and aspect ratio logic.
//
// Standalone runner:
//   g++ -std=c++17 -O2 native/tests/test_ui_trigger.cpp -o /tmp/test_ui_trigger && /tmp/test_ui_trigger

#include <cmath>
#include <cstdio>
#include <cstdint>

struct Vector2D {
	double x = 0.0;
	double y = 0.0;

	Vector2D() : x(0.0), y(0.0) {}
	Vector2D(double px, double py) : x(px), y(py) {}
};

#include "../src/ui_alignment.h"

static Vector2D compute_ui_anchor(Vector2D offset, int32_t xref, int32_t yref,
        bool rx, bool ry, Vector2D viewport, double zoom = 0.8) {
    const auto point = gdash::ui_anchor({offset.x, offset.y}, xref, yref, rx, ry,
            {viewport.x, viewport.y}, zoom);
    return Vector2D(point.x, point.y);
}

static int failures = 0;

static void expect_close(const char *name, double actual, double expected, double epsilon = 1e-4) {
	if (std::fabs(actual - expected) > epsilon) {
		std::printf("FAIL %s: expected %f, got %f (diff %f)\n", name, expected, actual, std::fabs(actual - expected));
		++failures;
	}
}

int main() {
    for (int ref = 0; ref <= 8; ++ref) {
        auto p = compute_ui_anchor(Vector2D(1012.5, 80), ref, ref, true, true, Vector2D(2560, 1080));
        expect_close("relative overrides every XRef", p.x, 1600);
        expect_close("relative inactive Y unchanged", p.y, 80);
        p = compute_ui_anchor(Vector2D(80, -600), ref, ref, true, true, Vector2D(1440, 1440));
        expect_close("relative overrides every YRef", p.y, -900);
        expect_close("relative inactive X unchanged", p.x, 80);
    }

	std::printf("--- Testing GD 2.2 UI Trigger (ID 3613) Alignment Math ---\n");

	// 1. Reference Aspect Ratio (3:2) - delta_x = 0, delta_y = 0
	{
		const Vector2D vp_3_2(1440.0, 960.0); // 1440 / 960 = 1.5
		const Vector2D offset(150.0, -100.0);
		// Left alignment in 3:2 should produce no change since delta_x is 0
		Vector2D anchor = compute_ui_anchor(offset, 3, 8, false, false, vp_3_2);
		expect_close("3:2 left alignment no shift", anchor.x, 150.0);
		expect_close("3:2 top alignment no shift", anchor.y, -100.0);

		// Relative in 3:2: W_active / W_ref = 1.0, so no scale change
		anchor = compute_ui_anchor(offset, 3, 8, true, true, vp_3_2);
		expect_close("3:2 relative left no scale", anchor.x, 150.0);
		expect_close("3:2 relative top no scale", anchor.y, -100.0);
	}

	// 2. Wide Aspect Ratio (16:9, 1920x1080)
	// aspect = 1.7778 > 1.5
	// H_ref = 1080 / 0.8 = 1350.0
	// W_ref = 1350.0 * 1.5 = 2025.0
	// W_active = 1350.0 * (16.0 / 9.0) = 2400.0
	// delta_x = (2400.0 - 2025.0) / 2.0 = 187.5
	// delta_y = 0.0
	{
		const Vector2D vp_16_9(1920.0, 1080.0);

		// Left edge alignment: reference bounds are [-1012.5, +1012.5]
		// An object placed at left reference edge (-1012.5) with Left alignment
		// shifts by -delta_x (-187.5) to -1200.0
		// In screen coordinates: 960 + (-1200.0 * 0.8) = 0.0 (exact screen left edge!)
		Vector2D left_edge = compute_ui_anchor(Vector2D(-1012.5, 0.0), 3, 0, false, false, vp_16_9);
		expect_close("16:9 left edge lands at -1200", left_edge.x, -1200.0);
		expect_close("16:9 screen pos is 0px", 960.0 + left_edge.x * 0.8, 0.0);

		// Right edge alignment: placed at +1012.5 with Right alignment
		// shifts by +delta_x (+187.5) to +1200.0
		// In screen coordinates: 960 + (+1200.0 * 0.8) = 1920.0 (exact screen right edge!)
		Vector2D right_edge = compute_ui_anchor(Vector2D(1012.5, 0.0), 4, 0, false, false, vp_16_9);
		expect_close("16:9 right edge lands at +1200", right_edge.x, 1200.0);
		expect_close("16:9 screen pos is 1920px", 960.0 + right_edge.x * 0.8, 1920.0);

		// Auto_x alignment:
		// Negative offset -> left
		Vector2D auto_neg = compute_ui_anchor(Vector2D(-200.0, 50.0), 1, 0, false, false, vp_16_9);
		expect_close("16:9 auto negative shifts left", auto_neg.x, -200.0 - 187.5);
		// Positive offset -> right
		Vector2D auto_pos = compute_ui_anchor(Vector2D(200.0, 50.0), 1, 0, false, false, vp_16_9);
		expect_close("16:9 auto positive shifts right", auto_pos.x, 200.0 + 187.5);

		// Center_x alignment: stays static relative to center
		Vector2D center_obj = compute_ui_anchor(Vector2D(320.0, -140.0), 2, 0, false, false, vp_16_9);
		expect_close("16:9 center_x preserves offset", center_obj.x, 320.0);

		// Relative alignment: scales by (2400 / 2025)
		Vector2D rel_obj = compute_ui_anchor(Vector2D(-506.25, 0.0), 3, 0, true, false, vp_16_9);
		expect_close("16:9 relative proportional scale", rel_obj.x, -506.25 * (2400.0 / 2025.0));

		// Y alignment is inactive when aspect >= 1.5
		Vector2D y_test = compute_ui_anchor(Vector2D(0.0, -450.0), 0, 8, false, false, vp_16_9);
		expect_close("16:9 Y offset untouched", y_test.y, -450.0);
	}

	// 3. Ultra-Wide Aspect Ratio (21:9, 2560x1080)
	// aspect = 2.37037 > 1.5
	// H_ref = 1080 / 0.8 = 1350.0
	// W_ref = 2025.0
	// W_active = 1350.0 * (2560.0 / 1080.0) = 3200.0
	// delta_x = (3200.0 - 2025.0) / 2.0 = 587.5
	{
		const Vector2D vp_21_9(2560.0, 1080.0);
		Vector2D left_edge = compute_ui_anchor(Vector2D(-1012.5, 0.0), 3, 0, false, false, vp_21_9);
		expect_close("21:9 left edge lands at -1600", left_edge.x, -1600.0);
		expect_close("21:9 screen pos is 0px", 1280.0 + left_edge.x * 0.8, 0.0);

		Vector2D right_edge = compute_ui_anchor(Vector2D(1012.5, 0.0), 4, 0, false, false, vp_21_9);
		expect_close("21:9 right edge lands at +1600", right_edge.x, 1600.0);
		expect_close("21:9 screen pos is 2560px", 1280.0 + right_edge.x * 0.8, 2560.0);
	}

	// 4. Tall Aspect Ratio (4:3, 1440x1080)
	// aspect = 1.3333 < 1.5
	// W_ref = 1440 / 0.8 = 1800.0
	// H_ref = 1800.0 / 1.5 = 1200.0
	// H_active = 1800.0 / (1440.0 / 1080.0) = 1350.0
	// delta_y = (1350.0 - 1200.0) / 2.0 = 75.0
	// delta_x = 0.0
	{
		const Vector2D vp_4_3(1440.0, 1080.0);

		// Top edge alignment: reference bounds are [-600.0, +600.0]
		// In Godot, Y increases downwards, so top is -600.0
		// With Top alignment (8), shifts by -delta_y (-75.0) to -675.0
		// Screen coordinates: 540.0 + (-675.0 * 0.8) = 0.0 (exact screen top edge!)
		Vector2D top_edge = compute_ui_anchor(Vector2D(0.0, -600.0), 0, 8, false, false, vp_4_3);
		expect_close("4:3 top edge lands at -675", top_edge.y, -675.0);
		expect_close("4:3 screen pos is 0px", 540.0 + top_edge.y * 0.8, 0.0);

		// Bottom edge alignment: placed at +600.0 with Bottom alignment (7)
		// shifts by +delta_y (+75.0) to +675.0
		// Screen coordinates: 540.0 + (+675.0 * 0.8) = 1080.0 (exact screen bottom edge!)
		Vector2D btm_edge = compute_ui_anchor(Vector2D(0.0, 600.0), 0, 7, false, false, vp_4_3);
		expect_close("4:3 bottom edge lands at +675", btm_edge.y, 675.0);
		expect_close("4:3 screen pos is 1080px", 540.0 + btm_edge.y * 0.8, 1080.0);

		// Auto_y alignment:
		// Negative offset -> top
		Vector2D auto_neg = compute_ui_anchor(Vector2D(0.0, -250.0), 0, 5, false, false, vp_4_3);
		expect_close("4:3 auto negative shifts top", auto_neg.y, -250.0 - 75.0);
		// Positive offset -> bottom
		Vector2D auto_pos = compute_ui_anchor(Vector2D(0.0, 250.0), 0, 5, false, false, vp_4_3);
		expect_close("4:3 auto positive shifts bottom", auto_pos.y, 250.0 + 75.0);

		// Center_y alignment: stays static relative to center
		Vector2D center_y = compute_ui_anchor(Vector2D(100.0, 180.0), 0, 6, false, false, vp_4_3);
		expect_close("4:3 center_y preserves offset", center_y.y, 180.0);

		// Relative alignment: scales by (1350 / 1200)
		Vector2D rel_y = compute_ui_anchor(Vector2D(0.0, -300.0), 0, 8, false, true, vp_4_3);
		expect_close("4:3 relative proportional scale", rel_y.y, -300.0 * (1350.0 / 1200.0));

		// X alignment is inactive when aspect < 1.5
		Vector2D x_test = compute_ui_anchor(Vector2D(400.0, 0.0), 3, 0, false, false, vp_4_3);
		expect_close("4:3 X offset untouched", x_test.x, 400.0);
	}

	if (failures == 0) {
		std::printf("ALL UI TRIGGER TESTS PASSED (0 failures)\n");
		return 0;
	}
	std::printf("UI TRIGGER TESTS FAILED: %d failure(s)\n", failures);
	return 1;
}
