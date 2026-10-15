#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <vector>

namespace godot {
// Animation metadata is immutable between configure calls. Sprite placement
// remains on its original frame boundary in DecorationBatch (not a new clock).
class NativeMonsterTimeline : public RefCounted {
	GDCLASS(NativeMonsterTimeline, RefCounted);
	struct Clip {
		String name;
		double delay = 0.05;
		int64_t frames = 0;
		int next = 0;
		bool loop = false;
	};
	struct Definition { std::vector<Clip> clips; };
	struct Track {
		Ref<RefCounted> mirror;
		size_t definition = 0;
		int clip = 0;
		int64_t frame = 0;
		double elapsed = 0.0;
	};
	std::vector<Definition> definitions;
	std::vector<Track> tracks;
protected:
	static void _bind_methods();
public:
	void configure(const Array &monsters, const Dictionary &tables);
	PackedInt32Array advance(double delta);
	int64_t size() const { return static_cast<int64_t>(tracks.size()); }
};
}
