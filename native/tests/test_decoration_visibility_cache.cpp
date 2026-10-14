// No Godot SDK required: tests the actual selection cache used by the renderer.
#include "../src/decoration_visibility_cache.h"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
#include <set>
#include <string>

using gdash::DecorationRange;
using gdash::DecorationSections;
static size_t checks = 0;
static volatile uint64_t sink = 0;

static void require(bool condition, const char *message) {
	++checks;
	if (!condition) {
		std::cerr << "DECORATION_CACHE_FAIL " << message << '\n';
		std::exit(1);
	}
}

// Independent oracle: preserve traversal and first occurrence, not sorted IDs.
static std::vector<size_t> oracle(const DecorationSections &sections, const DecorationRange &range) {
	std::vector<size_t> result;
	std::set<size_t> seen;
	for (const auto &column : sections) {
		if (column.first < range.first || column.first > range.last) continue;
		for (const auto &row : column.second) {
			if (row.first < range.top || row.first > range.bottom) continue;
			for (size_t index : row.second) if (seen.insert(index).second) result.push_back(index);
		}
	}
	return result;
}

static void test_parity() {
	std::mt19937 rng(20261014);
	DecorationSections sections;
	for (size_t i = 0; i < 1000; ++i) {
		const int x = static_cast<int>(rng() % 80) - 40;
		const int y = static_cast<int>(rng() % 30) - 15;
		for (int dx = 0; dx <= static_cast<int>(i % 7); ++dx)
			for (int dy = 0; dy <= static_cast<int>(i % 5); ++dy) sections[x + dx][y + dy].push_back(i);
	}
	// Intentionally unsorted duplicate IDs: ordering is a visual contract.
	sections[-1][-1] = {19, 3, 901, 3, 0, 19};
	gdash::DecorationVisibilityCache<uint8_t> cache; // many generation wraps
	for (int sample = 0; sample < 2000; ++sample) {
		const int x = static_cast<int>(rng() % 120) - 60;
		const int y = static_cast<int>(rng() % 60) - 30;
		const DecorationRange range{x, x + static_cast<int>(rng() % 20), y, y + static_cast<int>(rng() % 12)};
		const auto expected = oracle(sections, range);
		for (int repeat = 0; repeat < 3; ++repeat) {
			std::vector<size_t> actual;
			cache.for_each(sections, 1000, range, [&](size_t id) { actual.push_back(id); });
			require(actual == expected, "cached/uncached ordered IDs differ from oracle");
		}
	}
	for (DecorationRange range : {DecorationRange{5, -5, 0, 1}, {0, 1, 5, -5},
		{INT64_MIN, INT64_MAX, INT64_MIN, INT64_MAX}}) {
		std::vector<size_t> actual;
		cache.for_each(sections, 1000, range, [&](size_t id) { actual.push_back(id); });
		require(actual == oracle(sections, range), "empty/extreme range mismatch");
	}
	// Same record count and range but different index after streaming/rebuild.
	const DecorationRange all{INT64_MIN, INT64_MAX, INT64_MIN, INT64_MAX};
	sections.clear();
	sections[0][0] = {7, 2, 999, 7};
	cache.invalidate();
	std::vector<size_t> actual;
	cache.for_each(sections, 1000, all, [&](size_t id) { actual.push_back(id); });
	require(actual == std::vector<size_t>({7, 2, 999}), "same-size reindex must invalidate");
	sections[0][0] = {0};
	actual.clear();
	cache.for_each(sections, 1, all, [&](size_t id) { actual.push_back(id); });
	require(actual == std::vector<size_t>({0}), "record count change invalidates");
	sections.clear();
	actual.clear();
	cache.invalidate();
	cache.for_each(sections, 0, all, [&](size_t id) { actual.push_back(id); });
	require(actual.empty(), "empty rebuild");
	// Cache hits must still read the latest drawing state, not copied records.
	sections[0][0] = {0};
	cache.invalidate();
	int color = 1, drawn = 0;
	cache.for_each(sections, 1, all, [&](size_t) { drawn = color; });
	const auto builds = cache.build_count();
	color = 9;
	cache.for_each(sections, 1, all, [&](size_t) { drawn = color; });
	require(drawn == 9 && cache.build_count() == builds, "warm redraw uses live content");
}

static void test_dirty() {
	bool dirty = false;
	double value = 1.0;
	gdash::assign_render_value(value, 1.0, dirty);
	require(!dirty, "equal values do not dirty a clean renderer");
	gdash::assign_render_value(value, 1.0 + 1e-14, dirty);
	require(dirty && value == 1.0 + 1e-14, "tiny changes must not be dropped");
	gdash::assign_render_value(value, value, dirty);
	require(dirty, "no-op cannot erase earlier dirty state");
	dirty = false;
	const double nan = std::numeric_limits<double>::quiet_NaN();
	gdash::assign_render_value(value, nan, dirty);
	require(dirty, "non-finite value must not be mistaken for an unchanged value");
}

// Previous production algorithm: generation stamps, but rewalk cells each redraw.
struct Baseline {
	std::vector<uint32_t> marks;
	uint32_t stamp = 0;
	template <typename Emit>
	void for_each(const DecorationSections &sections, size_t count, DecorationRange range, Emit emit) {
		if (marks.size() != count) marks.assign(count, 0);
		if (++stamp == 0) { std::fill(marks.begin(), marks.end(), 0); stamp = 1; }
		auto col = sections.lower_bound(range.first);
		while (col != sections.end() && col->first <= range.last) {
			auto row = col->second.lower_bound(range.top);
			while (row != col->second.end() && row->first <= range.bottom) {
				for (size_t id : row->second) {
					if (marks[id] == stamp) continue;
					marks[id] = stamp;
					emit(id);
				}
				++row;
			}
			++col;
		}
	}
};

template <typename Selector>
static double measure(Selector &selector, const DecorationSections &sections, int change_every, uint64_t &checksum) {
	checksum = 0;
	const auto start = std::chrono::steady_clock::now();
	for (int frame = 0; frame < 2000; ++frame) {
		const int x = change_every == 0 ? 50 : 50 + (frame / change_every) % 80;
		selector.for_each(sections, 20000, {x, x + 15, -8, 8}, [&](size_t id) {
			checksum = checksum * 31 + id + static_cast<uint64_t>(frame);
		});
	}
	sink = checksum;
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

static void benchmark() {
	DecorationSections sections;
	std::mt19937 rng(42);
	for (size_t i = 0; i < 20000; ++i) {
		const int x = static_cast<int>(rng() % 400);
		const int y = static_cast<int>(rng() % 40) - 20;
		const int radius = i % 10 == 0 ? 6 : 1;
		for (int dx = -radius; dx <= radius; ++dx)
			for (int dy = -radius; dy <= radius; ++dy) sections[x + dx][y + dy].push_back(i);
	}
	for (int interval : {0, 60, 1}) {
		std::vector<double> old_ms, new_ms;
		size_t retained = 0, extra = 0;
		for (int trial = 0; trial < 5; ++trial) {
			Baseline old;
			gdash::DecorationVisibilityCache<> cached;
			uint64_t old_sum, new_sum;
			// Alternate timing order to limit cache/frequency bias.
			if (trial % 2 == 0) {
				old_ms.push_back(measure(old, sections, interval, old_sum));
				new_ms.push_back(measure(cached, sections, interval, new_sum));
			} else {
				new_ms.push_back(measure(cached, sections, interval, new_sum));
				old_ms.push_back(measure(old, sections, interval, old_sum));
			}
			require(old_sum == new_sum, "benchmark draw sequence differs");
			retained = cached.retained_bytes(); extra = cached.index_bytes();
		}
		std::sort(old_ms.begin(), old_ms.end()); std::sort(new_ms.begin(), new_ms.end());
		std::cout << "DECORATION_CACHE_BENCH records=20000 redraws=2000 change_every=" << interval
			<< " old_ms=" << old_ms[2] << " cached_ms=" << new_ms[2]
			<< " old_retained_bytes=80000 cached_retained_bytes=" << retained << " extra_index_bytes=" << extra << '\n';
	}
}

int main(int argc, char **argv) {
	test_parity();
	test_dirty();
	if (argc > 1 && std::string(argv[1]) == "--benchmark") benchmark();
	std::cout << "DECORATION_CACHE_SUMMARY checks=" << checks << " failed=0\n";
}
