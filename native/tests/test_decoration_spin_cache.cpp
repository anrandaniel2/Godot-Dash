// Production coefficient reuse versus the frozen pre-cache parent-space loop.
// Standalone CPU parity/benchmark, not a renderer, GPU or level FPS benchmark.
#include "../src/decoration_spin.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
#include <string>
#include <vector>

static uint64_t checks = 0;
static volatile uint64_t sink = 0;
static void require(bool condition, const char *message) {
	++checks;
	if (!condition) { std::cerr << "SPIN_CACHE_FAIL " << message << '\n'; std::exit(1); }
}

// Frozen from decoration_spin.h before this optimization. Do not delegate to
// spin_about_pivot/spin_with_rotation: the oracle must not share the new code.
static SpinTransform2D before(const SpinTransform2D &t, double px, double py, double angle) {
	const double c = std::cos(angle);
	const double s = std::sin(angle);
	SpinTransform2D r;
	r.xx = c * t.xx - s * t.xy;
	r.xy = s * t.xx + c * t.xy;
	r.yx = c * t.yx - s * t.yy;
	r.yy = s * t.yx + c * t.yy;
	const double dx = t.ox - px;
	const double dy = t.oy - py;
	r.ox = px + c * dx - s * dy;
	r.oy = py + s * dx + c * dy;
	return r;
}

static std::array<double, 6> components(const SpinTransform2D &t) {
	return {t.xx, t.xy, t.yx, t.yy, t.ox, t.oy};
}
static bool same(double a, double b) {
	return std::memcmp(&a, &b, sizeof(a)) == 0 || (std::isnan(a) && std::isnan(b));
}
static void equal(const SpinTransform2D &a, const SpinTransform2D &b) {
	const auto aa = components(a), bb = components(b);
	for (size_t i = 0; i < aa.size(); ++i) require(same(aa[i], bb[i]), "transform component differs");
}
static SpinTransform2D stored(SpinTransform2D t, bool single) {
	if (single) {
		t.xx = static_cast<float>(t.xx); t.xy = static_cast<float>(t.xy);
		t.yx = static_cast<float>(t.yx); t.yy = static_cast<float>(t.yy);
		t.ox = static_cast<float>(t.ox); t.oy = static_cast<float>(t.oy);
	}
	return t;
}

static void parity() {
	SpinRunProfile profile;
	require(!profile.use_cache(), "empty profile");
	profile.add(3.0f); require(!profile.use_cache(), "single record");
	profile.add(3.0f); require(profile.use_cache(), "equal pair");
	profile = SpinRunProfile();
	for (int i = 0; i < 100; ++i) profile.add(i % 2 ? -3.0f : 3.0f);
	require(!profile.use_cache(), "alternating speeds must bypass cache");
	profile = SpinRunProfile();
	for (int i = 0; i < 100; ++i) profile.add(static_cast<float>(i / 4));
	require(profile.use_cache(), "four-record runs");
	profile = SpinRunProfile();
	profile.add(0.0f); profile.add(-0.0f);
	require(!profile.use_cache(), "signed zero keys must differ");
	profile = SpinRunProfile();
	profile.add(3.0f); profile.add(std::nextafter(3.0f, 4.0f));
	require(!profile.use_cache(), "nearly equal speeds must differ");
	const std::array<float, 11> rates = {0.0f, -0.0f, 0.0000001f, -3.0f, 3.0f,
		std::nextafter(3.0f, 4.0f), std::numeric_limits<float>::denorm_min(),
		std::numeric_limits<float>::max(), std::numeric_limits<float>::infinity(),
		-std::numeric_limits<float>::infinity(), std::numeric_limits<float>::quiet_NaN()};
	for (double delta : {0.0, -0.0, 1.0 / 240.0, 1.0 / 60.0, 0.001, 2.0, -0.5}) {
		SpinRotationRunCache cache(delta);
		for (int repeat = 0; repeat < 4; ++repeat) for (float rate : rates) {
			for (int hit = 0; hit < 4; ++hit) {
				const SpinTransform2D t{-2.0, 0.25, 1.5, -0.0, 360.0 + hit, -420.0};
				equal(spin_with_rotation(t, -17.0, 43.0, cache.get(rate)),
					before(t, -17.0, 43.0, static_cast<double>(rate) * delta));
			}
		}
	}
	// Many incremental frames, float storage like normal Godot plus double
	// storage, skew/mirrors, changing delta/pivots and external pose updates.
	std::mt19937 random(20261015);
	for (bool single : {true, false}) {
		std::vector<SpinTransform2D> old(1024), current(1024);
		for (size_t i = 0; i < old.size(); ++i) {
			old[i] = stored({i % 2 ? -1.25 : 1.75, 0.375, -0.25, 2.0,
				static_cast<double>(random() % 10000), -static_cast<double>(random() % 10000)}, single);
		}
		current = old;
		for (int frame = 0; frame < 600; ++frame) {
			const double delta = frame % 97 == 0 ? 0.2 : (frame % 3 + 1) / 240.0;
			SpinRotationRunCache cache(delta); // Reset even when count/speeds stay equal.
			for (size_t i = 0; i < old.size(); ++i) {
				const float rate = static_cast<float>((i / 4) % 13 + 1) * ((frame % 2 ? i / 4 : i) % 2 ? -0.75f : 0.5f);
				const double px = static_cast<double>(i % 23), py = -static_cast<double>((i + frame) % 37);
				if (frame % 53 == 0) old[i].ox = current[i].ox = 100.0; // trigger/monster reset
				old[i] = stored(before(old[i], px, py, static_cast<double>(rate) * delta), single);
				current[i] = stored(spin_with_rotation(current[i], px, py, cache.get(rate)), single);
				equal(old[i], current[i]);
			}
		}
	}
}

// Deliberately retain some cold record storage, as the renderer does; this is
// still a synthetic workload and excludes Godot calls, culling and submission.
struct Record {
	SpinTransform2D transform;
	float speed, px, py;
	std::array<uint8_t, 64> cold = {};
};
static std::vector<Record> fixture(const std::string &pattern) {
	std::vector<Record> records(20000);
	for (size_t i = 0; i < records.size(); ++i) {
		auto &r = records[i];
		r.transform = {i % 2 ? -1.0 : 1.0, 0.25, -0.5, 1.5, static_cast<double>(i), -120.0};
		r.px = static_cast<float>(i); r.py = -100.0f;
		if (pattern == "same") r.speed = 3.0f;
		else if (pattern == "runs2") r.speed = static_cast<float>((i / 2) % 8 + 1);
		else if (pattern == "sparse") r.speed = static_cast<float>(i % 4 == 0 ? i + 1 : i);
		else if (pattern == "runs4") r.speed = static_cast<float>((i / 4) % 8 + 1);
		else if (pattern == "alternating") r.speed = i % 2 ? -3.0f : 3.0f;
		else r.speed = static_cast<float>(i + 1) * 0.001f;
	}
	return records;
}

template <bool Cached>
static void step(std::vector<Record> &records, double delta) {
	SpinRotationRunCache cache(delta);
	for (auto &r : records) {
		if constexpr (Cached) r.transform = stored(spin_with_rotation(r.transform, r.px, r.py, cache.get(r.speed)), true);
		else r.transform = stored(before(r.transform, r.px, r.py, static_cast<double>(r.speed) * delta), true);
	}
}

template <bool Optimized>
static double measure(std::vector<Record> &records, uint64_t &checksum) {
	SpinRunProfile profile;
	for (const auto &r : records) profile.add(r.speed);
	const bool reuse = profile.use_cache(); // Production builds this with the index.
	const auto start = std::chrono::steady_clock::now();
	for (int frame = 0; frame < 240; ++frame) {
		const double delta = (frame % 3 + 1) / 240.0;
		if constexpr (Optimized) {
			if (reuse) step<true>(records, delta);
			else step<false>(records, delta);
		} else step<false>(records, delta);
	}
	const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	checksum = 0;
	for (const auto &r : records) for (double component : components(r.transform)) {
		uint64_t bits; std::memcpy(&bits, &component, sizeof(bits));
		checksum = checksum * 31 + bits;
	}
	sink = checksum;
	return ms;
}
static void benchmark() {
	for (const std::string pattern : {"same", "runs4", "runs2", "sparse", "alternating", "unique"}) {
		const auto initial = fixture(pattern);
		std::vector<double> old_times, new_times;
		for (int trial = -1; trial < 5; ++trial) { // First pair warms caches; not sampled.
			auto old = initial, current = initial;
			uint64_t old_hash = 0, new_hash = 0;
			double old_ms, new_ms;
			if (trial % 2 == 0) { old_ms = measure<false>(old, old_hash); new_ms = measure<true>(current, new_hash); }
			else { new_ms = measure<true>(current, new_hash); old_ms = measure<false>(old, old_hash); }
			require(old_hash == new_hash, "benchmark output checksum differs");
			if (trial >= 0) { old_times.push_back(old_ms); new_times.push_back(new_ms); }
		}
		std::sort(old_times.begin(), old_times.end()); std::sort(new_times.begin(), new_times.end());
		std::cout << "SPIN_CACHE_BENCH pattern=" << pattern << " records=20000 frames=240 trials=5 old_ms="
			<< old_times[2] << " new_ms=" << new_times[2] << " ratio=" << old_times[2] / new_times[2] << '\n';
	}
}
int main(int argc, char **argv) {
	parity();
	if (argc > 1 && std::string(argv[1]) == "--benchmark") benchmark();
	std::cout << "SPIN_CACHE_TEST checks=" << checks << " failed=0\n";
}
