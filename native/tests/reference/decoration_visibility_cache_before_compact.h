// Frozen pre-compaction cache, independent benchmark baseline.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <map>
#include <type_traits>
#include <vector>

namespace before_compact {

using DecorationSections = std::map<int64_t, std::map<int64_t, std::vector<size_t>>>;

struct DecorationRange {
	int64_t first, last, top, bottom;
	bool operator==(const DecorationRange &other) const {
		return first == other.first && last == other.last && top == other.top && bottom == other.bottom;
	}
};

// Cache ONLY the ordered record IDs, never their mutable drawing data. A color,
// pulse, blend or spin update can redraw the same visible cells hundreds of
// times before the camera crosses a bucket boundary. Those redraws need not
// traverse the cell maps and deduplicate all their overlapping entries again.
//
// Call invalidate() whenever the section index is rebuilt, even at the same
// record count. Preserve the existing column/row/first-occurrence order exactly;
// sorting this list by record ID would change translucent sprite compositing.
// Like the renderer, this is owned/used on the main thread, not the cull worker.
// Stamp is parameterized so tests exercise wraparound cheaply with uint8_t.
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

	template <typename Emit>
	void for_each(const DecorationSections &sections, size_t record_count, const DecorationRange &range, Emit emit) {
		if (valid && marks.size() == record_count && range == last_range) {
			for (size_t index : selected) emit(index);
			return;
		}
		valid = false;
		selected.clear();
		if (marks.size() != record_count) marks.assign(record_count, 0);
		if (++generation == 0) {
			std::fill(marks.begin(), marks.end(), 0);
			generation = 1;
		}
		++builds;
		auto column = sections.lower_bound(range.first);
		while (column != sections.end() && column->first <= range.last) {
			auto row = column->second.lower_bound(range.top);
			while (row != column->second.end() && row->first <= range.bottom) {
				for (size_t index : row->second) {
					if (marks[index] == generation) continue;
					marks[index] = generation;
					selected.push_back(index);
					// Fuse building and emission on a miss: no second draw pass.
					emit(index);
				}
				++row;
			}
			++column;
		}
		last_range = range;
		valid = true;
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

} // namespace before_compact
