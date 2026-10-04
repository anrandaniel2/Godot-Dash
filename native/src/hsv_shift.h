#pragma once

// Geometry Dash HSV adjustments, shared by the native trigger runtime and its
// standalone test. Header-only and Godot-free on purpose, so it builds with
// plain g++ (native/tests/test_hsv_shift.cpp).
//
// The arithmetic is Geometry Dash's, as GDRweb reads it out of the level
// string (HSVShift::shiftColor, third_party/gdrweb/src/util/hsvshift.ts): hue
// rotates, saturation and value either multiply (the default) or add when the
// slider's "add" flag is set, and the result is clamped into range.
//
// The conversion mirrors Godot's Color::get_h / get_s / get_v and
// Color::set_hsv exactly (godotengine/godot 4.4, core/math/color.cpp), because
// that is what the engine computes with: the runtime converts a Color in,
// applies the shift here, and converts back, so a device run and this test
// agree down to the last float.

#include <cmath>

struct RGB {
	double r = 0.0;
	double g = 0.0;
	double b = 0.0;
};

struct HSV {
	double h = 0.0; // turns, [0, 1)
	double s = 0.0;
	double v = 0.0;
};

// One HSV adjustment: a copied-colour kS38 entry's key 10, a Color trigger's
// copy HSV (key 49), or a Pulse trigger's HSV sliders (keys 48/49).
struct HSVShift {
	double hue = 0.0; // turns, not degrees (the level string stores degrees)
	double saturation = 1.0;
	double value = 1.0;
	bool saturation_additive = false;
	bool value_additive = false;

	// True when the shift cannot change any colour, so callers can skip the
	// round trip (GDRweb's HSVShift::isEmpty).
	bool is_identity() const {
		return hue == 0.0
				&& saturation == (saturation_additive ? 0.0 : 1.0)
				&& value == (value_additive ? 0.0 : 1.0);
	}
};

// Color::get_h / get_s / get_v.
inline HSV rgb_to_hsv(const RGB &c) {
	HSV out;
	const double min = std::fmin(std::fmin(c.r, c.g), c.b);
	const double max = std::fmax(std::fmax(c.r, c.g), c.b);
	const double delta = max - min;

	if (delta != 0.0) {
		double h;
		if (c.r == max) {
			h = (c.g - c.b) / delta;
		} else if (c.g == max) {
			h = 2.0 + (c.b - c.r) / delta;
		} else {
			h = 4.0 + (c.r - c.g) / delta;
		}
		h /= 6.0;
		if (h < 0.0) {
			h += 1.0;
		}
		out.h = h;
	}
	out.s = max != 0.0 ? delta / max : 0.0;
	out.v = max;
	return out;
}

// Color::set_hsv, minus alpha: the caller keeps the base colour's alpha.
inline RGB hsv_to_rgb(const HSV &c) {
	RGB out;
	if (c.s == 0.0) {
		// Achromatic (grey).
		out.r = c.v;
		out.g = c.v;
		out.b = c.v;
		return out;
	}
	double h = c.h * 6.0;
	h = std::fmod(h, 6.0);
	const int i = static_cast<int>(std::floor(h));
	const double f = h - i;
	const double p = c.v * (1.0 - c.s);
	const double q = c.v * (1.0 - c.s * f);
	const double t = c.v * (1.0 - c.s * (1.0 - f));
	switch (i) {
		case 0:
			out.r = c.v;
			out.g = t;
			out.b = p;
			break;
		case 1:
			out.r = q;
			out.g = c.v;
			out.b = p;
			break;
		case 2:
			out.r = p;
			out.g = c.v;
			out.b = t;
			break;
		case 3:
			out.r = p;
			out.g = q;
			out.b = c.v;
			break;
		case 4:
			out.r = t;
			out.g = p;
			out.b = c.v;
			break;
		default:
			out.r = c.v;
			out.g = p;
			out.b = q;
			break;
	}
	return out;
}

// Applies one HSV adjustment to an RGB colour, wrapping hue into [0, 1) and
// clamping saturation and value into [0, 1].
inline RGB apply_hsv_shift(const RGB &base, const HSVShift &shift) {
	const HSV hsv = rgb_to_hsv(base);
	HSV shifted;
	shifted.h = hsv.h + shift.hue;
	shifted.h -= std::floor(shifted.h);
	const double s = shift.saturation_additive ? hsv.s + shift.saturation : hsv.s * shift.saturation;
	const double v = shift.value_additive ? hsv.v + shift.value : hsv.v * shift.value;
	shifted.s = std::fmin(std::fmax(s, 0.0), 1.0);
	shifted.v = std::fmin(std::fmax(v, 0.0), 1.0);
	return hsv_to_rgb(shifted);
}
