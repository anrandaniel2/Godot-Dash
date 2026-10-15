// Exact ordered parity + allocation accounting for the production compact index.
#include "../src/decoration_visibility_cache.h"
#include "reference/decoration_visibility_cache_before_compact.h"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <new>
#include <limits>
#include <utility>
#include <random>
#include <set>
#include <string>

// Requested live C++ allocation bytes, not RSS or allocator bookkeeping. The
// prefix preserves fundamental alignment. Only this test executable overrides new.
// Keep allocator wrappers opaque to GCC's mismatched-new-delete diagnostic;
// otherwise inlining the matching delete's free() produces a false positive.
#if defined(_MSC_VER)
#define TEST_NOINLINE __declspec(noinline)
#else
#define TEST_NOINLINE __attribute__((noinline))
#endif
namespace allocations {
struct alignas(__STDCPP_DEFAULT_NEW_ALIGNMENT__) Header { size_t size; };
static size_t live = 0, peak = 0;
}
TEST_NOINLINE void *operator new(std::size_t size) {
	if (size > std::numeric_limits<size_t>::max() - sizeof(allocations::Header)) throw std::bad_alloc();
	auto *header = static_cast<allocations::Header *>(std::malloc(sizeof(allocations::Header) + size));
	if (!header) throw std::bad_alloc();
	header->size = size;
	allocations::live += size;
	allocations::peak = std::max(allocations::peak, allocations::live);
	return header + 1;
}
TEST_NOINLINE void operator delete(void *pointer) noexcept {
	if (!pointer) return;
	auto *header = static_cast<allocations::Header *>(pointer) - 1;
	allocations::live -= header->size;
	std::free(header);
}
TEST_NOINLINE void operator delete(void *p, std::size_t) noexcept { ::operator delete(p); }
TEST_NOINLINE void *operator new[](std::size_t size) { return ::operator new(size); }
TEST_NOINLINE void operator delete[](void *p) noexcept { ::operator delete(p); }
TEST_NOINLINE void operator delete[](void *p, std::size_t) noexcept { ::operator delete(p); }

#undef TEST_NOINLINE

using gdash::DecorationSections;
using gdash::DecorationRange;
using gdash::CompactDecorationSections;
static size_t checks = 0;
static volatile uint64_t sink = 0;
static void require(bool ok, const char *message) {
	++checks;
	if (!ok) { std::cerr << "COMPACT_SECTIONS_FAIL " << message << '\n'; std::exit(1); }
}
static std::vector<size_t> oracle(const DecorationSections &sections, DecorationRange range, bool deduplicate) {
	std::vector<size_t> output;
	std::set<size_t> seen;
	for (const auto &column : sections) {
		if (column.first < range.first || column.first > range.last) continue;
		for (const auto &row : column.second) {
			if (row.first < range.top || row.first > range.bottom) continue;
			for (size_t id : row.second) if (!deduplicate || seen.insert(id).second) output.push_back(id);
		}
	}
	return output;
}
static DecorationSections fixture(size_t count, int wide_every) {
	DecorationSections sections;
	if (wide_every < 0) {
		for (size_t id = 0; id < count; ++id) sections[0][0].push_back(id);
		return sections; // Concentrated worst case for column-at-a-time peak.
	}
	std::mt19937 rng(42);
	for (size_t id = 0; id < count; ++id) {
		const int x = static_cast<int>(rng() % 400), y = static_cast<int>(rng() % 40) - 20;
		const int radius = wide_every && id % wide_every == 0 ? 6 : 1;
		for (int dx = -radius; dx <= radius; ++dx)
			for (int dy = -radius; dy <= radius; ++dy) sections[x + dx][y + dy].push_back(id);
	}
	return sections;
}
static void parity() {
	auto source = fixture(1000, 10);
	source[-1][-1] = {19, 3, 901, 3, 0, 19}; // never sort the IDs
	source[INT64_MIN][INT64_MIN] = {4, 2};
	source[INT64_MAX][INT64_MAX] = {999, 0};
	source[-999][-999] = {}; // empty construction cells have no candidates
	CompactDecorationSections compact;
	compact.build(DecorationSections(source));
	gdash::DecorationVisibilityCache<uint8_t> cache;
	std::mt19937 rng(20261015);
	for (int sample = 0; sample < 3000; ++sample) {
		const int64_t x = static_cast<int>(rng() % 500) - 50, y = static_cast<int>(rng() % 80) - 40;
		DecorationRange range{x, x + static_cast<int>(rng() % 30), y, y + static_cast<int>(rng() % 20)};
		if (sample % 101 == 0) range = {INT64_MIN, INT64_MAX, INT64_MIN, INT64_MAX};
		if (sample % 103 == 0) range = {10, -10, 0, 1};
		if (sample % 107 == 0) range = {0, 1, 10, -10};
		const auto expected = oracle(source, range, true);
		require(compact.has_records(range) == !expected.empty(), "range existence differs");
		std::vector<size_t> raw;
		compact.for_each(range, [&](size_t id) { raw.push_back(id); });
		require(raw == oracle(source, range, false), "raw cell order/duplicates differ");
		for (int repeat = 0; repeat < 3; ++repeat) {
			std::vector<size_t> actual;
			cache.for_each(compact, 1000, range, [&](size_t id) { actual.push_back(id); });
			require(actual == expected, "cached first-occurrence order differs");
		}
	}
	const DecorationRange all{INT64_MIN, INT64_MAX, INT64_MIN, INT64_MAX};
	for (int rebuild = 0; rebuild < 50; ++rebuild) {
		source.clear();
		if (rebuild % 2) source[0][0] = {7, 2, 999, 7};
		compact.build(DecorationSections(source));
		cache.invalidate();
		std::vector<size_t> actual;
		cache.for_each(compact, 1000, all, [&](size_t id) { actual.push_back(id); });
		require(actual == oracle(source, all, true), "same-size/empty rebuild differs");
	}
	// Compact storage must own its data after the temporary builder is destroyed.
	source.clear();
	source[0][0] = {0};
	compact.build(DecorationSections(source)); source.clear(); cache.invalidate();
	int color = 1, drawn = 0;
	cache.for_each(compact, 1, all, [&](size_t) { drawn = color; });
	const auto builds = cache.build_count();
	color = 9;
	cache.for_each(compact, 1, all, [&](size_t) { drawn = color; });
	require(drawn == 9 && cache.build_count() == builds, "warm redraw must read live values");
	compact.clear();
	require(compact.retained_bytes() == 0 && !compact.has_records(all), "clear releases old index");
}

template <typename Cache, typename Sections>
static double measure(Cache &cache, const Sections &sections, int change_every, uint64_t &hash) {
	hash = 0;
	const auto start = std::chrono::steady_clock::now();
	for (int frame = 0; frame < 2000; ++frame) {
		const int x = change_every == 0 ? 50 : 50 + (frame / change_every) % 80;
		cache.for_each(sections, 20000, {x, x + 15, -8, 8}, [&](size_t id) {
			hash = hash * 31 + id + static_cast<uint64_t>(frame);
		});
	}
	sink = hash;
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}
static void benchmark() {
	for (int wide_every : {0, 10, -1}) {
		const size_t initial = allocations::live;
		allocations::peak = initial;
		CompactDecorationSections compact;
		double build_ms, compact_ms;
		size_t map_bytes, map_peak;
		{
			const auto start = std::chrono::steady_clock::now();
			auto builder = fixture(20000, wide_every);
			build_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
			map_bytes = allocations::live - initial; map_peak = allocations::peak - initial;
			const auto compact_start = std::chrono::steady_clock::now();
			compact.build(std::move(builder));
			compact_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - compact_start).count();
			require(builder.empty(), "builder must be released during compaction");
		} // Also release MSVC's empty-map sentinel before measuring retained bytes.
		const size_t compact_bytes = allocations::live - initial;
		require(compact_bytes == compact.retained_bytes(), "allocation accounting mismatch");
		std::cout << "COMPACT_SECTIONS_MEMORY records=20000 wide_every=" << wide_every
			<< " map_bytes=" << map_bytes << " compact_bytes=" << compact_bytes
			<< " map_peak_bytes=" << map_peak << " build_peak_bytes=" << allocations::peak - initial
			<< " map_build_ms=" << build_ms << " compact_extra_ms=" << compact_ms << '\n';
		if (wide_every < 0) continue; // Memory-only concentrated fixture.
		auto sections = fixture(20000, wide_every); // Timing reference; outside memory sample.
		for (int change_every : {0, 60, 1}) {
			std::vector<double> old_times, new_times;
			for (int trial = -1; trial < 5; ++trial) {
				before_compact::DecorationVisibilityCache<> old;
				gdash::DecorationVisibilityCache<> current;
				uint64_t old_hash, new_hash;
				double old_ms, new_ms;
				if (trial % 2 == 0) { old_ms = measure(old, sections, change_every, old_hash); new_ms = measure(current, compact, change_every, new_hash); }
				else { new_ms = measure(current, compact, change_every, new_hash); old_ms = measure(old, sections, change_every, old_hash); }
				require(old_hash == new_hash, "benchmark order checksum differs");
				if (trial >= 0) { old_times.push_back(old_ms); new_times.push_back(new_ms); }
			}
			std::sort(old_times.begin(), old_times.end()); std::sort(new_times.begin(), new_times.end());
			std::cout << "COMPACT_SECTIONS_BENCH wide_every=" << wide_every << " change_every=" << change_every
				<< " old_ms=" << old_times[2] << " new_ms=" << new_times[2] << " ratio=" << old_times[2] / new_times[2] << '\n';
		}
	}
}
int main(int argc, char **argv) {
	parity();
	if (argc > 1 && std::string(argv[1]) == "--benchmark") benchmark();
	std::cout << "COMPACT_SECTIONS_TEST checks=" << checks << " failed=0\n";
}
