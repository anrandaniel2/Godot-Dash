#pragma once

#include <algorithm>
#include <cmath>

namespace gdash {

// One incoming channel color per apply call. Decompose it lazily, only if a
// valid record actually has a non-neutral HSV shift. Never retain this across
// calls: triggers, reconfiguration and direct item-color writes stay live.
// ColorT is Godot Color in production; templating also permits call-count tests.
template <typename ColorT>
class DecorationChannelTint {
	const ColorT &channel;
	float h = 0.0f, s = 0.0f, v = 0.0f;
	bool ready = false;

public:
	explicit DecorationChannelTint(const ColorT &p_channel) : channel(p_channel) {}

	ColorT shifted(const float *hsv) {
		if (!ready) {
			h = channel.get_h(); s = channel.get_s(); v = channel.get_v();
			ready = true;
		}
		float hue = std::fmod(h + hsv[0], 1.0f);
		if (hue < 0) hue += 1.0f;
		const float saturation = std::clamp(hsv[3] > 0.5f ? s + hsv[1] : s * hsv[1], 0.0f, 1.0f);
		const float value = std::clamp(hsv[4] > 0.5f ? v + hsv[2] : v * hsv[2], 0.0f, 1.0f);
		return ColorT::from_hsv(hue, saturation, value, channel.a);
	}
};

} // namespace gdash
