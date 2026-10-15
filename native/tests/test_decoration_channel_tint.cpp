// Uses the pinned godot-cpp Color implementation, not an approximation.
#include "../src/decoration_channel_tint.h"
#include "../src/decoration_visibility_cache.h"
#include "../src/neutral_hsv.h"
#include <godot_cpp/variant/color.hpp>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <random>
#include <string>

using godot::Color;
static uint64_t checks = 0;
static volatile uint64_t sink = 0;
static void require(bool ok, const char *message) {
	++checks;
	if (!ok) { std::cerr << "CHANNEL_TINT_FAIL " << message << '\n'; std::exit(1); }
}

// Frozen pre-optimization NativeDecorationRenderer::apply_channel_color math.
static Color before(const Color &channel, bool has_hsv, const float *hsv, float alpha) {
	Color tinted = channel;
	if (has_hsv) {
		float hue = std::fmod(tinted.get_h() + hsv[0], 1.0f); if (hue < 0) hue += 1.0f;
		const float saturation = std::clamp(hsv[3] > 0.5f ? tinted.get_s() + hsv[1] : tinted.get_s() * hsv[1], 0.0f, 1.0f);
		const float value = std::clamp(hsv[4] > 0.5f ? tinted.get_v() + hsv[2] : tinted.get_v() * hsv[2], 0.0f, 1.0f);
		tinted = Color::from_hsv(hue, saturation, value, channel.a);
	}
	tinted.a = channel.a * alpha;
	return tinted;
}
static void equal(const Color &a, const Color &b) {
	for (int i = 0; i < 4; ++i) require(std::memcmp(&a[i], &b[i], sizeof(float)) == 0, "RGBA bits differ");
}

struct CountedColor : Color {
	inline static int reads = 0;
	CountedColor(const Color &c) : Color(c) {}
	float get_h() const { ++reads; return Color::get_h(); }
	float get_s() const { ++reads; return Color::get_s(); }
	float get_v() const { ++reads; return Color::get_v(); }
};
static void parity() {
	const Color source(0.5f, 0.25f, 0.75f, 0.6f);
	CountedColor counted(source);
	gdash::DecorationChannelTint<CountedColor> lazy(counted);
	const float hsv[5] = {-0.2f, 0.4f, 0.8f, 1.0f, 0.0f};
	require(CountedColor::reads == 0, "neutral records must not decompose RGB");
	for (int i = 0; i < 100; ++i) lazy.shifted(hsv);
	require(CountedColor::reads == 3, "one decomposition per call context");
	gdash::DecorationChannelTint<CountedColor> next(counted);
	next.shifted(hsv);
	require(CountedColor::reads == 6, "new context must recompute");

	std::mt19937 rng(20261015);
	std::uniform_real_distribution<float> rgb(-0.5f, 4.0f), shift(-2.0f, 2.0f), alpha(-1.0f, 2.0f);
	for (int sample = 0; sample < 20000; ++sample) {
		Color channel(rgb(rng), rgb(rng), rgb(rng), alpha(rng));
		if (sample % 7 == 0) channel = Color(0, 0, 0, alpha(rng));
		if (sample % 11 == 0) channel = Color(1, 1, 1, alpha(rng));
		if (sample % 13 == 0) channel = Color(-0.0f, 0, std::numeric_limits<float>::denorm_min(), -0.0f);
		gdash::DecorationChannelTint<Color> tint(channel);
		for (int i = 0; i < 24; ++i) {
			float values[5] = {shift(rng), shift(rng), shift(rng), i & 1 ? 1.0f : 0.0f, i & 2 ? 1.0f : 0.0f};
			if (i % 7 == 0) values[0] = values[1] = values[2] = 0.0f;
			const bool enabled = i % 5 != 0 && !gdash::neutral_hsv(values[0], values[1], values[2],
				!(values[3] > 0.5f), !(values[4] > 0.5f));
			const float base_alpha = alpha(rng);
			const Color expected = before(channel, enabled, values, base_alpha);
			Color actual = enabled ? tint.shifted(values) : channel;
			actual.a = channel.a * base_alpha;
			equal(actual, expected);
			bool dirty = false;
			Color stored = expected;
			gdash::assign_render_value(stored, actual, dirty);
			require(!dirty, "identical update must not dirty");
			stored.r = actual.r + 1.0f;
			gdash::assign_render_value(stored, actual, dirty);
			require(dirty, "external color overwrite must be restored");
			equal(stored, expected);
		}
	}
}

struct Record {
	Color color;
	float hsv[5], alpha;
	bool enabled;
};
static std::vector<Record> fixture(const std::string &pattern) {
	std::vector<Record> records(20000);
	for (size_t i = 0; i < records.size(); ++i) {
		auto &r = records[i];
		r.color = Color(1, 1, 1, 1);
		r.hsv[0] = static_cast<float>(i % 17) / 17.0f - 0.5f;
		r.hsv[1] = static_cast<float>(i % 13) / 13.0f;
		r.hsv[2] = static_cast<float>(i % 19) / 19.0f;
		r.hsv[3] = i % 2 ? 1.0f : 0.0f; r.hsv[4] = i % 3 ? 1.0f : 0.0f;
		r.alpha = static_cast<float>(i % 7) / 7.0f;
		r.enabled = pattern == "all" || (pattern == "half" && i % 2) || (pattern == "sparse" && i % 100 == 0);
	}
	return records;
}

template <bool Optimized>
static double measure(std::vector<Record> &records, uint64_t &hash) {
	const auto start = std::chrono::steady_clock::now();
	for (int tick = 0; tick < 240; ++tick) {
		const Color channel(0.2f + tick * 0.003f, 0.8f, 0.3f, 0.4f + tick * 0.001f);
		gdash::DecorationChannelTint<Color> tint(channel);
		bool dirty = false;
		for (auto &r : records) {
			Color incoming = channel;
			if (r.enabled) {
				if constexpr (Optimized) incoming = tint.shifted(r.hsv);
				else {
					// Frozen loop inlined here, not an extra function call/record.
					float hue = std::fmod(incoming.get_h() + r.hsv[0], 1.0f); if (hue < 0) hue += 1.0f;
					const float saturation = std::clamp(r.hsv[3] > 0.5f ? incoming.get_s() + r.hsv[1] : incoming.get_s() * r.hsv[1], 0.0f, 1.0f);
					const float value = std::clamp(r.hsv[4] > 0.5f ? incoming.get_v() + r.hsv[2] : incoming.get_v() * r.hsv[2], 0.0f, 1.0f);
					incoming = Color::from_hsv(hue, saturation, value, channel.a);
				}
			}
			incoming.a = channel.a * r.alpha;
			gdash::assign_render_value(r.color, incoming, dirty);
		}
		sink = sink ^ static_cast<uint64_t>(dirty);
	}
	const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	hash = 0;
	for (const auto &r : records) for (int i = 0; i < 4; ++i) {
		uint32_t bits; std::memcpy(&bits, &r.color[i], sizeof(bits)); hash = hash * 31 + bits;
	}
	sink = hash;
	return ms;
}
static void benchmark() {
	for (const std::string pattern : {"all", "half", "sparse", "none"}) {
		std::vector<double> old_times, new_times;
		for (int trial = -1; trial < 5; ++trial) {
			auto old = fixture(pattern), current = old;
			uint64_t old_hash, new_hash;
			double old_ms, new_ms;
			if (trial % 2 == 0) { old_ms = measure<false>(old, old_hash); new_ms = measure<true>(current, new_hash); }
			else { new_ms = measure<true>(current, new_hash); old_ms = measure<false>(old, old_hash); }
			require(old_hash == new_hash, "benchmark checksum mismatch");
			if (trial >= 0) { old_times.push_back(old_ms); new_times.push_back(new_ms); }
		}
		std::sort(old_times.begin(), old_times.end()); std::sort(new_times.begin(), new_times.end());
		std::cout << "CHANNEL_TINT_BENCH pattern=" << pattern << " records=20000 ticks=240 trials=5 old_ms="
			<< old_times[2] << " new_ms=" << new_times[2] << " ratio=" << old_times[2] / new_times[2] << '\n';
	}
}
int main(int argc, char **argv) {
	parity();
	if (argc > 1 && std::string(argv[1]) == "--benchmark") benchmark();
	std::cout << "CHANNEL_TINT_TEST checks=" << checks << " failed=0\n";
}
