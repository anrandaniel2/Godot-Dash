// Static-frustum edge-band selection parity and CPU benchmark.
#include "../src/frustum_transition_ranges.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <map>
#include <random>
#include <string>
#include <vector>

using gdash::FrustumSectionRange;
using gdash::FrustumTransitionRanges;
using gdash::frustum_transition_ranges;

static size_t checks = 0;
static volatile uint64_t sink = 0;
static void require(bool condition, const char *message) {
	++checks;
	if (!condition) {
		std::cerr << "FRUSTUM_TRANSITION_FAIL " << message << '\n';
		std::exit(1);
	}
}

struct Entry {
	double left;
	double right;
};
using Sections = std::map<int64_t, std::vector<size_t>>;

static Sections make_sections(const std::vector<Entry> &entries, double width) {
	Sections sections;
	for (size_t i = 0; i < entries.size(); ++i) {
		const int64_t first = static_cast<int64_t>(std::floor(entries[i].left / width));
		const int64_t last = static_cast<int64_t>(std::floor(entries[i].right / width));
		for (int64_t section = first; section <= last; ++section) sections[section].push_back(i);
	}
	return sections;
}

static FrustumSectionRange view_range(double left, double right, double width) {
	if (right < left) std::swap(left, right);
	return {static_cast<int64_t>(std::floor(left / width)), static_cast<int64_t>(std::floor(right / width))};
}

static void scan(const Sections &sections, const std::vector<Entry> &entries,
		const FrustumTransitionRanges &ranges, double left, double right,
		std::vector<uint32_t> &visited, uint32_t generation,
		std::vector<uint8_t> &visible, size_t *visit_count = nullptr) {
	if (right < left) std::swap(left, right);
	for (size_t r = 0; r < ranges.count; ++r) {
		auto section = sections.lower_bound(ranges.ranges[r].first);
		while (section != sections.end() && section->first <= ranges.ranges[r].last) {
			for (size_t index : section->second) {
				if (visited[index] == generation) continue;
				visited[index] = generation;
				visible[index] = entries[index].right >= left && entries[index].left <= right;
				if (visit_count) ++*visit_count;
			}
			++section;
		}
	}
}

static FrustumTransitionRanges full_view_ranges(double old_left, double old_right,
		double new_left, double new_right, double width) {
	FrustumTransitionRanges ranges;
	ranges.ranges[0] = view_range(old_left, old_right, width);
	ranges.ranges[1] = view_range(new_left, new_right, width);
	ranges.count = 2;
	return ranges;
}

static bool overlaps(const Entry &entry, double left, double right) {
	return entry.right >= left && entry.left <= right;
}

static void parity() {
	constexpr double width = 32.0;
	std::vector<Entry> entries = {
		{-160.0, -130.0}, {-32.0, -32.0}, {-0.01, 0.01},
		{30.0, 41.0}, {65.0, 66.0}, {0.0, 480.0}, {400.0, 401.0},
		{-800.0, 900.0}, {1200.0, 1240.0},
	};
	const Sections sections = make_sections(entries, width);
	std::mt19937 random(20261015);
	std::uniform_int_distribution<int> coordinate(-3000, 3000);
	std::uniform_int_distribution<int> span(0, 900);
	for (int query = 0; query < 12000; ++query) {
		const double old_left = static_cast<double>(coordinate(random)) / 7.0;
		const double old_width = static_cast<double>(span(random)) / 5.0;
		const double new_left = query % 11 == 0
			? old_left + static_cast<double>(coordinate(random))
			: old_left + static_cast<double>(coordinate(random)) / 13.0;
		const double new_width = static_cast<double>(span(random)) / 5.0;
		const double old_right = old_left + old_width;
		const double new_right = new_left + new_width;
		std::vector<uint8_t> actual(entries.size(), 0);
		std::vector<uint32_t> visited(entries.size(), 0);
		for (size_t i = 0; i < entries.size(); ++i) actual[i] = overlaps(entries[i], old_left, old_right);
		const FrustumTransitionRanges ranges = frustum_transition_ranges(
			old_left, old_right, new_left, new_right, width);
		scan(sections, entries, ranges, new_left, new_right, visited, 1, actual);
		for (size_t i = 0; i < entries.size(); ++i) {
			require(actual[i] == overlaps(entries[i], new_left, new_right),
				"edge bands must update every changed static visibility state");
		}
	}
	const auto edge = frustum_transition_ranges(0, 100, 1, 101, width);
	require(edge.count == 2, "overlapping view uses two edge sweeps");
	const auto disjoint = frustum_transition_ranges(0, 100, 1000, 1100, width);
	require(disjoint.count == 2, "disjoint view uses old and new viewport ranges");
	const auto reversed = frustum_transition_ranges(100, 0, 101, 1, width);
	require(reversed.count == 2, "reversed endpoints normalize");
	require(frustum_transition_ranges(0, 1, 1, 2, 0).count == 0, "invalid width returns no ranges");
}

struct RunResult {
	double milliseconds = 0.0;
	size_t candidate_visits = 0;
	uint64_t checksum = 0;
};

static RunResult run_updates(const Sections &sections, const std::vector<Entry> &entries,
		double section_width, bool edge_bands, int updates) {
	std::vector<uint8_t> visible(entries.size(), 0);
	std::vector<uint32_t> visited(entries.size(), 0);
	uint32_t generation = 0;
	const double view_width = 1920.0;
	double left = -12000.0;
	double right = left + view_width;
	for (size_t i = 0; i < entries.size(); ++i) visible[i] = overlaps(entries[i], left, right);
	RunResult result;
	const auto start = std::chrono::steady_clock::now();
	for (int frame = 0; frame < updates; ++frame) {
		const double next_left = left + 5.0;
		const double next_right = right + 5.0;
		const FrustumTransitionRanges ranges = edge_bands
			? frustum_transition_ranges(left, right, next_left, next_right, section_width)
			: full_view_ranges(left, right, next_left, next_right, section_width);
		if (++generation == 0) {
			std::fill(visited.begin(), visited.end(), 0);
			generation = 1;
		}
		scan(sections, entries, ranges, next_left, next_right,
			visited, generation, visible, &result.candidate_visits);
		left = next_left;
		right = next_right;
	}
	result.milliseconds = std::chrono::duration<double, std::milli>(
			std::chrono::steady_clock::now() - start).count();
		for (size_t i = 0; i < visible.size(); ++i) result.checksum += visible[i] * (i + 1);
	sink = result.checksum;
	return result;
}

static void benchmark() {
	constexpr double width = 1024.0;
	std::mt19937 random(99017);
	std::uniform_int_distribution<int> center(-250000, 250000);
	std::uniform_int_distribution<int> kind(0, 19);
	std::vector<Entry> entries;
	entries.reserve(20000);
	for (int i = 0; i < 20000; ++i) {
		const int x = center(random);
		const int choice = kind(random);
		const int radius = choice == 0 ? 5000 : (choice < 5 ? 250 : 35);
		entries.push_back({static_cast<double>(x - radius), static_cast<double>(x + radius)});
	}
	const Sections sections = make_sections(entries, width);
	std::vector<double> full_times, edge_times;
	size_t full_visits = 0, edge_visits = 0;
	for (int trial = -1; trial < 5; ++trial) {
		RunResult full, edge;
		if (trial % 2 == 0) {
			full = run_updates(sections, entries, width, false, 2000);
			edge = run_updates(sections, entries, width, true, 2000);
		} else {
			edge = run_updates(sections, entries, width, true, 2000);
			full = run_updates(sections, entries, width, false, 2000);
		}
		require(full.checksum == edge.checksum, "benchmark checksums differ");
		if (trial >= 0) {
			full_times.push_back(full.milliseconds);
			edge_times.push_back(edge.milliseconds);
			full_visits = full.candidate_visits;
			edge_visits = edge.candidate_visits;
		}
	}
	std::sort(full_times.begin(), full_times.end());
	std::sort(edge_times.begin(), edge_times.end());
	std::cout << std::fixed << std::setprecision(3)
		<< "FRUSTUM_TRANSITION_BENCH objects=20000 updates=2000 full_ms=" << full_times[2]
		<< " edge_ms=" << edge_times[2] << " speedup=" << full_times[2] / edge_times[2]
		<< " full_candidate_visits=" << full_visits << " edge_candidate_visits=" << edge_visits << '\n';
}

int main(int argc, char **argv) {
	parity();
	if (argc > 1 && std::string(argv[1]) == "--benchmark") benchmark();
	std::cout << "FRUSTUM_TRANSITION_TEST checks=" << checks << " failed=0\n";
}
