// Standalone equivalence test for NativeColorChannelIndex::apply's colour
// math against the GDScript reference semantics of
// ColorChannelWatcher.refresh_objects_color + HSVWatcher.update_color.
//
// Both sides use godot-cpp's own Color implementation (the exact code the
// engine runs for `color.s += x` in GDScript), so any difference is a real
// difference. Build & run:
//   g++ -std=c++17 -O2 -Inative/godot-cpp/include -Inative/godot-cpp/gen/include \
//       -Inative/godot-cpp/gdextension native/tests/test_color_channel_math.cpp \
//       native/godot-cpp/bin/libgodot-cpp.linux.template_release.x86_64.a -lpthread -o /tmp/color_test
//   /tmp/color_test

#include <godot_cpp/variant/color.hpp>

#include <cmath>
#include <cstdio>
#include <cstdint>
#include <random>

using godot::Color;

struct WatcherState {
	float hsv[3] = { 0, 0, 0 };
	float intensity = 1.0f;
	float alpha = 1.0f;
	bool sat_multiplies = false;
	bool val_multiplies = false;
};

// Exactly what HSVWatcher.update_color computes, given the watcher's own
// modulate (already set by refresh_objects_color) and the channel values.
static Color reference_parent_modulate(Color watcher_modulate, const WatcherState &state,
		float channel_intensity, float channel_alpha) {
	Color shifted = watcher_modulate;
	if (state.sat_multiplies) shifted.set_s(shifted.get_s() * state.hsv[1]);
	else shifted.set_s(shifted.get_s() + state.hsv[1]);
	if (state.val_multiplies) shifted.set_v(shifted.get_v() * state.hsv[2]);
	else shifted.set_v(shifted.get_v() + state.hsv[2]);
	shifted.set_h(shifted.get_h() + state.hsv[0]);
	Color parent = shifted * state.intensity * channel_intensity;
	parent.a = watcher_modulate.a * state.alpha * channel_alpha;
	return parent;
}

// The body of NativeColorChannelIndex::apply for a single record.
static Color native_parent_modulate(const Color &channel_color, float sh, float ss, float sv,
		const WatcherState &record, float intensity, float alpha, Color *r_watcher_modulate) {
	Color modulate = channel_color;
	modulate.set_s(modulate.get_s() + ss);
	modulate.set_v(modulate.get_v() + sv);
	modulate.set_h(modulate.get_h() + sh);
	Color shifted = modulate;
	if (record.sat_multiplies) shifted.set_s(shifted.get_s() * record.hsv[1]);
	else shifted.set_s(shifted.get_s() + record.hsv[1]);
	if (record.val_multiplies) shifted.set_v(shifted.get_v() * record.hsv[2]);
	else shifted.set_v(shifted.get_v() + record.hsv[2]);
	shifted.set_h(shifted.get_h() + record.hsv[0]);
	Color parent = shifted * (record.intensity * intensity);
	parent.a = modulate.a * record.alpha * alpha;
	*r_watcher_modulate = modulate;
	return parent;
}

static bool approx(float a, float b) {
	return std::fabs(a - b) <= 1e-6f + std::fabs(b) * 1e-6f;
}

int main() {
	std::mt19937 rng(20260912);
	std::uniform_real_distribution<float> hue(-1.5f, 1.5f);
	std::uniform_real_distribution<float> unit(0.0f, 1.0f);
	std::uniform_real_distribution<float> wide(-0.8f, 1.6f);
	std::uniform_real_distribution<float> gain(0.0f, 2.0f);
	std::uniform_int_distribution<int> boolean(0, 1);

	int cases = 200000;
	int failures = 0;
	for (int i = 0; i < cases; ++i) {
		// Channel state.
		Color channel_color = Color::from_hsv(hue(rng), unit(rng), unit(rng), unit(rng));
		float shift_h = wide(rng), shift_s = wide(rng), shift_v = wide(rng);
		float intensity = gain(rng), alpha = unit(rng);
		// Per-object state.
		WatcherState state;
		state.hsv[0] = wide(rng);
		state.hsv[1] = wide(rng);
		state.hsv[2] = wide(rng);
		state.intensity = gain(rng);
		state.alpha = unit(rng);
		state.sat_multiplies = boolean(rng);
		state.val_multiplies = boolean(rng);

		// GDScript reference: refresh_objects_color sets the watcher modulate
		// (s, then v, then h), then update_color derives the parent modulate.
		Color ref_modulate = channel_color;
		ref_modulate.set_s(ref_modulate.get_s() + shift_s);
		ref_modulate.set_v(ref_modulate.get_v() + shift_v);
		ref_modulate.set_h(ref_modulate.get_h() + shift_h);
		Color ref_parent = reference_parent_modulate(ref_modulate, state, intensity, alpha);

		// Native path.
		Color native_modulate;
		Color native_parent = native_parent_modulate(channel_color, shift_h, shift_s, shift_v,
				state, intensity, alpha, &native_modulate);

		bool ok = true;
		for (int c = 0; c < 4; ++c) {
			if (!approx(ref_modulate[c], native_modulate[c])) ok = false;
			if (!approx(ref_parent[c], native_parent[c])) ok = false;
		}
		if (!ok) {
			if (failures < 5) {
				std::printf("MISMATCH case %d\n  watcher ref (%f,%f,%f,%f) native (%f,%f,%f,%f)\n  parent  ref (%f,%f,%f,%f) native (%f,%f,%f,%f)\n",
					i,
					ref_modulate.r, ref_modulate.g, ref_modulate.b, ref_modulate.a,
					native_modulate.r, native_modulate.g, native_modulate.b, native_modulate.a,
					ref_parent.r, ref_parent.g, ref_parent.b, ref_parent.a,
					native_parent.r, native_parent.g, native_parent.b, native_parent.a);
			}
			++failures;
		}
	}
	if (failures == 0) {
		std::printf("COLOR CHANNEL EQUIVALENCE OK: %d randomized cases matched\n", cases);
		return 0;
	}
	std::printf("COLOR CHANNEL EQUIVALENCE FAILED: %d/%d cases\n", failures, cases);
	return 1;
}
