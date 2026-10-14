#pragma once
#include <cstdint>

namespace gdash {
struct UIPoint { double x, y; };

// GD UI trigger 3613: 3:2 reference, only the expanded axis aligns.
// Relative overrides EVERY alignment, including Center and Default.
// https://github.com/UHDanke/gd_docs/blob/main/docs/triggers/visual/ui.md
inline UIPoint ui_anchor(UIPoint offset, int32_t xref, int32_t yref,
        bool relative_x, bool relative_y, UIPoint viewport, double zoom = 0.8) {
    if (viewport.x <= 0.0 || viewport.y <= 0.0) return offset;
    const double aspect = viewport.x / viewport.y;
    const double safe_zoom = zoom > 0.0 ? zoom : 0.8;
    if (aspect >= 1.5) {
        if (relative_x) offset.x *= aspect / 1.5;
        else {
            if (xref == 1) xref = offset.x < 0.0 ? 3 : 4;
            const double extra = (viewport.x - viewport.y * 1.5) / (2.0 * safe_zoom);
            if (xref == 3) offset.x -= extra;
            else if (xref == 4) offset.x += extra;
        }
    } else {
        if (relative_y) offset.y *= 1.5 / aspect;
        else {
            if (yref == 5) yref = offset.y < 0.0 ? 8 : 7;
            const double extra = (viewport.y - viewport.x / 1.5) / (2.0 * safe_zoom);
            if (yref == 8) offset.y -= extra;
            else if (yref == 7) offset.y += extra;
        }
    }
    return offset;
}
} // namespace gdash
