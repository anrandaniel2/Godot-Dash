#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include "decoration_sections.h"
#include <type_traits>
#include <vector>

namespace gdash {

// Cache ONLY the ordered record IDs, never their mutable drawing data. A color,
// pulse, blend or spin update can redraw the same visible cells hundreds of
// times before the camera crosses a bucket boundary. Those redraws need not
// traverse the cell maps and deduplicate all their overlapping entries again.
//
// Call invalidate() whenever the section index is rebuilt, even at the same
// record count. Preserve the existing column/row/first-occurrence order exactly;
// sorting this list by record ID would change translucent sprite compositing.
// One worker prepares each cache; the main thread reads it only after its
// WorkerThreadPool group completes. Stamp is parameterized so tests exercise
// wraparound cheaply with uint8_t.
template <typename Stamp = uint32_t>
class DecorationVisibilityCache {
	static_assert(std::is_unsigned<Stamp>::value, "Generation stamps must be unsigned");
	std::vector<Stamp> marks;
	Stamp generation = 0;
	std::vector<size_t> selected;
	DecorationRange last_range = {};
	bool valid = false;
	uint64_t builds = 0;

public:
	void invalidate() { valid = false; }

	bool matches(size_t record_count, const DecorationRange &range) const {
		return valid && marks.size() == record_count && range == last_range;
	}

	template <typename Sections>
	void prepare(const Sections &sections, size_t record_count, const DecorationRange &range) {
		if (valid && marks.size() == record_count && range == last_range) return;
		valid = false;
		selected.clear();
		if (marks.size() != record_count) marks.assign(record_count, 0);
		if (++generation == 0) {
			std::fill(marks.begin(), marks.end(), 0);
			generation = 1;
		}
		++builds;
		for_each_decoration_candidate(sections, range, [&](size_t index) {
			if (index >= record_count || marks[index] == generation) return;
			marks[index] = generation;
			selected.push_back(index);
		});
		last_range = range;
		valid = true;
	}

	template <typename Emit>
	void for_each_selected(Emit emit) const {
		for (size_t index : selected) emit(index);
	}

	// Membership test for the *current* selection, O(1). Callers use it to skip
	// work whose result can never reach the screen: a spinning record outside
	// the selected cell range still advances its transform (rotation is
	// accumulated, never absolute), but it must not mark the renderer's
	// command stream dirty. A range change rebuilds every route anyway, so the
	// accumulated transform is emitted as soon as the record becomes visible.
	bool contains(size_t index) const {
		return valid && index < marks.size() && marks[index] == generation;
	}

	template <typename Sections, typename Emit>
	void for_each(const Sections &sections, size_t record_count, const DecorationRange &range, Emit emit) {
		if (!(valid && marks.size() == record_count && range == last_range)) {
			valid = false;
			selected.clear();
			if (marks.size() != record_count) marks.assign(record_count, 0);
			if (++generation == 0) {
				std::fill(marks.begin(), marks.end(), 0);
				generation = 1;
			}
			++builds;
			for_each_decoration_candidate(sections, range, [&](size_t index) {
				if (index >= record_count || marks[index] == generation) return;
				marks[index] = generation;
				selected.push_back(index);
				// Fuse building and emission on a miss: no second draw pass.
				emit(index);
			});
			last_range = range;
			valid = true;
			return;
		}
		for_each_selected(emit);
	}

	uint64_t build_count() const { return builds; }
	size_t retained_bytes() const { return marks.capacity() * sizeof(Stamp) + selected.capacity() * sizeof(size_t); }
	size_t index_bytes() const { return selected.capacity() * sizeof(size_t); }
};

// Exact equality, never approximate: even tiny changes in color or transform
// remain visible. Keep an already-dirty command list dirty on a no-op update.
template <typename T>
inline void assign_render_value(T &stored, const T &incoming, bool &commands_dirty) {
	if (stored != incoming) {
		stored = incoming;
		commands_dirty = true;
	}
}

} // namespace gdash
