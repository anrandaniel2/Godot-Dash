// No Godot SDK required: tests the actual selection cache used by the renderer.
#include "../src/decoration_visibility_cache.h"
#include "../src/neutral_hsv.h"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
#include <set>
#include <string>
#include <thread>

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

static void test_worker_preselection() {
	DecorationSections source;
	source[-1][0] = {5, 2, 5};
	source[0][0] = {9, 2};
	source[1][0] = {4};
	const DecorationRange range{-1, 0, 0, 0};
	const auto expected = oracle(source, range);
	gdash::CompactDecorationSections sections;
	sections.build(std::move(source));
	gdash::DecorationVisibilityCache<> selection;
	std::thread worker([&] { selection.prepare(sections, 10, range); });
	worker.join();
	std::vector<size_t> actual;
	selection.for_each_selected([&](size_t id) { actual.push_back(id); });
	require(actual == expected, "worker-prepared visible order and dedup match oracle");
	const uint64_t builds = selection.build_count();
	std::thread cache_hit([&] { selection.prepare(sections, 10, range); });
	cache_hit.join();
	require(selection.build_count() == builds, "worker cache hit avoids rebuilding selection");
}

// The animation gate asks "is this record in the current selection?" once per
// spinning record per frame. It must be a strict subset of what
// for_each_selected emits: a false negative would leave an on-screen spinner's
// accumulated rotation unsubmitted until the camera crosses a cell boundary.
static void test_membership() {
	DecorationSections source;
	source[-2][0] = {11, 12};
	source[0][0] = {13, 13, 101};
	source[2][1] = {14};
	gdash::CompactDecorationSections sections;
	sections.build(std::move(source));
	gdash::DecorationVisibilityCache<> cache;
	require(!cache.contains(11), "empty cache selects nothing");
	cache.prepare(sections, 110, DecorationRange{-2, 0, 0, 0});
	std::set<size_t> emitted;
	cache.for_each_selected([&](size_t id) { emitted.insert(id); });
	require(cache.contains(11) && cache.contains(12) && cache.contains(13) && cache.contains(101),
		"selected records report membership");
	require(!cache.contains(14), "record outside the range is not a member");
	require(!cache.contains(110), "out-of-range index is never a member");
	require(emitted.size() == 4, "deduplicated emission count");
	for (size_t id : {11, 12, 13, 101}) {
		require(emitted.count(id) == 1, "membership matches emission");
		require(cache.contains(id), "every emitted record is a member");
	}
	// A new range replaces the selection: stale IDs must stop reporting true.
	cache.prepare(sections, 110, DecorationRange{2, 2, 1, 1});
	require(cache.contains(14), "new range selects its own records");
	require(!cache.contains(11) && !cache.contains(13), "old selection is not retained");
	// invalidate() (index rebuild with unchanged count) must clear membership.
	cache.invalidate();
	require(!cache.contains(14), "invalidate clears membership");
	cache.prepare(sections, 110, DecorationRange{2, 2, 1, 1});
	require(cache.contains(14), "reprepare restores membership");
	// Generation wraparound (uint8_t stamps) must not resurrect old IDs.
	gdash::DecorationVisibilityCache<uint8_t> wrapping;
	for (int i = 0; i < 600; ++i) {
		DecorationRange range{-2, 0, 0, 0};
		wrapping.prepare(sections, 110, range);
		require(wrapping.contains(11) && !wrapping.contains(14), "wrapped stamp stays exact");
		DecorationRange other{2, 2, 1, 1};
		wrapping.prepare(sections, 110, other);
		require(wrapping.contains(14) && !wrapping.contains(11), "wrapped range switch stays exact");
	}
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

static void test_neutral_hsv() {
	const float nan = std::numeric_limits<float>::quiet_NaN();
	const float inf = std::numeric_limits<float>::infinity();
	for (float h : {0.0f, -0.0f, 1e-14f, 0.5f, inf, nan})
		for (float sat : {0.0f, 1.0f, 1e-14f, inf, nan})
			for (float val : {0.0f, 1.0f, 1e-14f, inf, nan})
				for (float sat_flag : {0.0f, 0.5f, 1.0f, nan})
					for (float val_flag : {0.0f, 0.5f, 1.0f, nan}) {
						const bool previous = (h == 0.0f && sat == 0.0f && val == 0.0f) ||
							(h == 0.0f && sat == (sat_flag > 0.5f ? 0.0f : 1.0f) &&
							 val == (val_flag > 0.5f ? 0.0f : 1.0f));
						require(gdash::neutral_hsv(h, sat, val, !(sat_flag > 0.5f), !(val_flag > 0.5f)) == previous,
							"precomputed neutral classification preserves exact old predicate");
					}
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
	test_worker_preselection();
	test_membership();
	test_dirty();
	test_neutral_hsv();
	if (argc > 1 && std::string(argv[1]) == "--benchmark") benchmark();
	std::cout << "DECORATION_CACHE_SUMMARY checks=" << checks << " failed=0\n";
}
