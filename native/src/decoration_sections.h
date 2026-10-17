#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <map>
#include <vector>

namespace gdash {
using DecorationSections = std::map<int64_t, std::map<int64_t, std::vector<size_t>>>;

struct DecorationRange {
	int64_t first, last, top, bottom;
	bool operator==(const DecorationRange &other) const {
		return first == other.first && last == other.last && top == other.top && bottom == other.bottom;
	}
};

// Mutable construction representation, also retained as the test reference path.
template <typename Emit>
void for_each_decoration_candidate(const DecorationSections &sections, const DecorationRange &range, Emit emit) {
	auto column = sections.lower_bound(range.first);
	while (column != sections.end() && column->first <= range.last) {
		auto row = column->second.lower_bound(range.top);
		while (row != column->second.end() && row->first <= range.bottom) {
			for (size_t id : row->second) emit(id);
			++row;
		}
		++column;
	}
}

// Immutable runtime index. Flatten the sorted map traversal once, preserving
// EVERY per-cell record occurrence and its insertion order (including duplicates).
// The visibility cache still owns deduplication and first-occurrence draw order.
// No narrowed cell bounds, sorted record IDs, quantization or omitted sprites.
class CompactDecorationSections {
	struct Span {
		int64_t key;
		size_t begin, end;
	};
	struct Column {
		int64_t key;
		std::vector<Span> rows;
		std::vector<size_t> ids;
	};
	std::vector<Column> columns;

public:
	void clear() { std::vector<Column>().swap(columns); }

	void build(DecorationSections &&source) {
		clear();
		columns.reserve(source.size());
		// Consume one column at a time. Reserving one giant flattened ID array
		// before releasing the tree would spike Android level-open memory.
		while (!source.empty()) {
			auto first = source.begin();
			size_t row_count = 0, id_count = 0;
			for (const auto &row : first->second) {
				if (row.second.empty()) continue;
				++row_count;
				id_count += row.second.size();
			}
			if (row_count) {
				columns.push_back(Column{first->first, {}, {}});
				Column &column = columns.back();
				column.rows.reserve(row_count); column.ids.reserve(id_count);
				for (const auto &row : first->second) {
					if (row.second.empty()) continue;
					const size_t begin = column.ids.size();
					column.ids.insert(column.ids.end(), row.second.begin(), row.second.end());
					column.rows.push_back({row.first, begin, column.ids.size()});
				}
			}
			source.erase(first);
		}
	}

	bool has_records(const DecorationRange &range) const {
		if (range.first > range.last || range.top > range.bottom) return false;
		auto column = std::lower_bound(columns.begin(), columns.end(), range.first,
			[](const Column &entry, int64_t key) { return entry.key < key; });
		for (; column != columns.end() && column->key <= range.last; ++column) {
			auto row = std::lower_bound(column->rows.begin(), column->rows.end(), range.top,
				[](const Span &entry, int64_t key) { return entry.key < key; });
			if (row != column->rows.end() && row->key <= range.bottom) return true;
		}
		return false;
	}

	template <typename Emit>
	void for_each(const DecorationRange &range, Emit emit) const {
		if (range.first > range.last || range.top > range.bottom) return;
		auto column = std::lower_bound(columns.begin(), columns.end(), range.first,
			[](const Column &entry, int64_t key) { return entry.key < key; });
		for (; column != columns.end() && column->key <= range.last; ++column) {
			auto row = std::lower_bound(column->rows.begin(), column->rows.end(), range.top,
				[](const Span &entry, int64_t key) { return entry.key < key; });
			for (; row != column->rows.end() && row->key <= range.bottom; ++row) {
				for (size_t i = row->begin; i < row->end; ++i) emit(column->ids[i]);
			}
		}
	}

	size_t retained_bytes() const {
		size_t bytes = columns.capacity() * sizeof(Column);
		for (const auto &column : columns) bytes += column.rows.capacity() * sizeof(Span) + column.ids.capacity() * sizeof(size_t);
		return bytes;
	}
};

template <typename Emit>
void for_each_decoration_candidate(const CompactDecorationSections &sections, const DecorationRange &range, Emit emit) {
	sections.for_each(range, emit);
}
} // namespace gdash
