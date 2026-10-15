#pragma once

namespace gdash {
// Exact native neutral-state rule, computed when immutable per-object HSV
// snapshots are built, not on every color-pulse update. All-zero GD HSV is a
// special no-op even in multiply mode. No epsilon or RGB reassociation.
inline bool neutral_hsv(float h, float s, float v, bool multiply_s, bool multiply_v) {
	return (h == 0.0f && s == 0.0f && v == 0.0f) ||
		(h == 0.0f && s == (multiply_s ? 1.0f : 0.0f) && v == (multiply_v ? 1.0f : 0.0f));
}
} // namespace gdash
