// Unit test for the shared Geometry Dash HSV shift (native/src/hsv_shift.h),
// the math a Pulse trigger in HSV mode (1006, keys 48/49) and a copied colour
// (key 49 / kS38 key 10) apply to a channel's colour.
//
// Standalone, no Godot:
//   g++ -std=c++17 -O2 native/tests/test_hsv_shift.cpp -o /tmp/hsv_shift_test
//   /tmp/hsv_shift_test

#include "../src/hsv_shift.h"

#include <cstdio>
#include <cmath>

static int failures = 0;

static void expect_close(const char *name, double actual, double expected) {
	if (std::fabs(actual - expected) > 1e-6) {
		std::printf("FAIL %s: expected %.6f, got %.6f\n", name, expected, actual);
		++failures;
	}
}

static void expect_rgb(const char *name, const RGB &actual, double r, double g, double b) {
	if (std::fabs(actual.r - r) > 1e-6 || std::fabs(actual.g - g) > 1e-6
			|| std::fabs(actual.b - b) > 1e-6) {
		std::printf("FAIL %s: expected (%.4f, %.4f, %.4f), got (%.4f, %.4f, %.4f)\n",
				name, r, g, b, actual.r, actual.g, actual.b);
		++failures;
	}
}

static RGB make(double r, double g, double b) {
	RGB c;
	c.r = r;
	c.g = g;
	c.b = b;
	return c;
}

int main() {
	// Godot's get_h/get_s/get_v: pure red is h=0, s=1, v=1, and a mid grey has
	// no hue and no saturation.
	const HSV red = rgb_to_hsv(make(1.0, 0.0, 0.0));
	expect_close("red hue", red.h, 0.0);
	expect_close("red saturation", red.s, 1.0);
	expect_close("red value", red.v, 1.0);
	const HSV grey = rgb_to_hsv(make(0.5, 0.5, 0.5));
	expect_close("grey hue", grey.h, 0.0);
	expect_close("grey saturation", grey.s, 0.0);
	expect_close("grey value", grey.v, 0.5);

	// A neutral shift is the identity, and is_identity() says so.
	const HSVShift neutral;
	const RGB base = make(0.2, 0.6, 0.9);
	if (!neutral.is_identity()) {
		std::printf("FAIL neutral shift is not identity\n");
		++failures;
	}
	const RGB unchanged = apply_hsv_shift(base, neutral);
	expect_rgb("neutral shift", unchanged, base.r, base.g, base.b);

	// Multiplicative is the default: a 50% saturation slider halves saturation
	// and leaves value alone (GDRweb HSVShift::shiftColor).
	HSVShift half_saturation;
	half_saturation.saturation = 0.5;
	expect_rgb("half saturation", apply_hsv_shift(make(1.0, 0.0, 0.0), half_saturation), 1.0, 0.5, 0.5);

	// The additive flag switches the slider to a delta and saturates at the
	// clamp instead of growing past the gamut.
	HSVShift add_saturation;
	add_saturation.saturation = 0.25;
	add_saturation.saturation_additive = true;
	expect_rgb("additive saturation", apply_hsv_shift(make(1.0, 0.5, 0.5), add_saturation), 1.0, 0.25, 0.25);
	HSVShift add_value;
	add_value.value = 0.5;
	add_value.value_additive = true;
	expect_rgb("additive value clamps", apply_hsv_shift(make(1.0, 1.0, 1.0), add_value), 1.0, 1.0, 1.0);

	// Hue is stored in degrees and becomes turns: 180 degrees is the opposite
	// hue, so pure red pulses to pure cyan.
	HSVShift half_turn;
	half_turn.hue = 180.0 / 360.0;
	expect_rgb("180 degree hue", apply_hsv_shift(make(1.0, 0.0, 0.0), half_turn), 0.0, 1.0, 1.0);

	// Hue wraps instead of clamping: a full turn is the identity, and a shift
	// that runs past 1.0 comes back around (90 degrees is a yellow-green, so
	// red + 1.25 turns = 0.25 turns).
	HSVShift full_turn;
	full_turn.hue = 1.0;
	expect_rgb("full turn wraps", apply_hsv_shift(make(0.1, 0.7, 0.3), full_turn), 0.1, 0.7, 0.3);
	HSVShift past_one;
	past_one.hue = 1.25;
	expect_rgb("hue wrap past one", apply_hsv_shift(make(1.0, 0.0, 0.0), past_one), 0.5, 1.0, 0.0);

	// A grey has no hue to rotate and no saturation to scale: only the value
	// slider moves it (GD's sliders are useless there, and must stay harmless).
	HSVShift hue_and_saturation;
	hue_and_saturation.hue = 0.25;
	hue_and_saturation.saturation = 0.5;
	expect_rgb("grey ignores hue and saturation", apply_hsv_shift(make(0.4, 0.4, 0.4), hue_and_saturation), 0.4, 0.4, 0.4);
	HSVShift value_only;
	value_only.value = 0.5;
	expect_rgb("grey value scales", apply_hsv_shift(make(0.4, 0.4, 0.4), value_only), 0.2, 0.2, 0.2);

	// Black keeps working: value 0 has no hue, and multiplying zero stays zero
	// rather than producing a NaN out of the delta division.
	expect_rgb("black stays black", apply_hsv_shift(make(0.0, 0.0, 0.0), hue_and_saturation), 0.0, 0.0, 0.0);

	// The identity test has to read the flags, not just the numbers: "s + 0"
	// is the identity while "s * 0" would be grey, and "v + 1" is not the
	// identity even though "v * 1" is.
	HSVShift additive_zero;
	additive_zero.saturation = 0.0;
	additive_zero.saturation_additive = true;
	if (!additive_zero.is_identity()) {
		std::printf("FAIL additive zero saturation should be the identity\n");
		++failures;
	}
	HSVShift multiplicative_zero;
	multiplicative_zero.saturation = 0.0;
	if (multiplicative_zero.is_identity()) {
		std::printf("FAIL multiplying saturation by 0 is not the identity\n");
		++failures;
	}
	expect_rgb("saturation 0 is grey at the same value", apply_hsv_shift(make(0.2, 0.4, 0.6), multiplicative_zero), 0.6, 0.6, 0.6);
	HSVShift additive_value_one;
	additive_value_one.value = 1.0;
	additive_value_one.value_additive = true;
	if (additive_value_one.is_identity()) {
		std::printf("FAIL additive value 1 is not the identity (it brightens)\n");
		++failures;
	}
	// Value saturation to 1.0 keeps the hue and saturation: (0.2, 0.4, 0.6) is
	// hue 0.583 turns, saturation 0.667.
	expect_rgb("additive value 1 brightens",
			apply_hsv_shift(make(0.2, 0.4, 0.6), additive_value_one), 1.0 / 3.0, 2.0 / 3.0, 1.0);

	if (failures == 0) {
		std::printf("all HSV shift checks passed\n");
	}
	return failures == 0 ? 0 : 1;
}
