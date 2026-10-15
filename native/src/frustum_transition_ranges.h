#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace gdash {
struct FrustumSectionRange {
	int64_t first = 0;
	int64_t last = -1;
};

struct FrustumTransitionRanges {
	std::array<FrustumSectionRange, 4> ranges{};
	size_t count = 0;
};

// Static-object visibility can change only where either horizontal viewport
// edge sweeps across an object. When the old and new views are disjoint, visit
// both complete views instead: traversing the potentially huge travel gap
// would do more work. The caller still applies exact world-space bounds.
inline FrustumTransitionRanges frustum_transition_ranges(
		double old_left, double old_right, double new_left, double new_right, double section_width) {
	FrustumTransitionRanges result;
	if (!(section_width > 0.0)) return result;
	if (old_right < old_left) std::swap(old_left, old_right);
	if (new_right < new_left) std::swap(new_left, new_right);
	auto append = [&](double first, double last) {
		const int64_t first_section = static_cast<int64_t>(std::floor(first / section_width));
		const int64_t last_section = static_cast<int64_t>(std::floor(last / section_width));
		if (first_section <= last_section) result.ranges[result.count++] = {first_section, last_section};
	};
	const double overlap_left = std::max(old_left, new_left);
	const double overlap_right = std::min(old_right, new_right);
	if (overlap_left <= overlap_right) {
		append(std::min(old_left, new_left), std::max(old_left, new_left));
		append(std::min(old_right, new_right), std::max(old_right, new_right));
	} else {
		append(old_left, old_right);
		append(new_left, new_right);
	}
	return result;
}
} // namespace gdash
