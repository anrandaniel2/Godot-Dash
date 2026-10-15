#include "native_monster_timeline.h"
#include <godot_cpp/core/class_db.hpp>
#include <algorithm>

namespace godot {
void NativeMonsterTimeline::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "monsters", "definitions"), &NativeMonsterTimeline::configure);
	ClassDB::bind_method(D_METHOD("advance", "delta"), &NativeMonsterTimeline::advance);
	ClassDB::bind_method(D_METHOD("size"), &NativeMonsterTimeline::size);
}

void NativeMonsterTimeline::configure(const Array &monsters, const Dictionary &tables) {
	tracks.clear();
	definitions.clear();
	tracks.reserve(monsters.size());
	Dictionary definition_indices;
	std::vector<Dictionary> clip_indices;
	for (int64_t i = 0; i < monsters.size(); ++i) {
		Ref<RefCounted> mirror = monsters[i];
		if (mirror.is_null()) {
			tracks.push_back(Track()); // Preserve returned indices for sparse input.
			continue;
		}
		String name = mirror->get("name");
		if (!definition_indices.has(name)) {
			Dictionary table = tables.get(name, Dictionary());
			Dictionary animations = table.get("animations", Dictionary());
			String default_clip = table.get("default", "");
			Array names = animations.keys();
			// Missing/default/next clips also have slots: the old loop treats
			// them as one frame during a transition, then skips next tick.
			if (!names.has(default_clip)) names.append(default_clip);
			const int64_t original_count = names.size();
			for (int64_t j = 0; j < original_count; ++j) {
				Dictionary animation = animations.get(names[j], Dictionary());
				String next = animation.get("next", "");
				if (!next.is_empty() && !names.has(next)) names.append(next);
			}
			String initial_clip = mirror->get("animation");
			if (!names.has(initial_clip)) names.append(initial_clip);
			Dictionary indices;
			for (int64_t j = 0; j < names.size(); ++j) indices[names[j]] = j;
			Definition definition;
			for (int64_t j = 0; j < names.size(); ++j) {
				Dictionary animation = animations.get(names[j], Dictionary());
				Array frames = animation.get("frames", Array());
				String next = animation.get("next", "");
				if (next.is_empty()) next = default_clip;
				Clip clip;
				clip.name = names[j];
				clip.delay = std::max(static_cast<double>(animation.get("delay", 0.05)), 0.001);
				clip.frames = frames.size();
				clip.next = static_cast<int>(indices[next]);
				clip.loop = animation.get("loop", false);
				definition.clips.push_back(clip);
			}
			definition_indices[name] = static_cast<int64_t>(definitions.size());
			definitions.push_back(std::move(definition));
			clip_indices.push_back(indices);
		}
		Track track;
		track.mirror = mirror;
		track.definition = static_cast<int64_t>(definition_indices[name]);
		String animation = mirror->get("animation");
		Dictionary &indices = clip_indices[track.definition];
		if (!indices.has(animation)) {
			Clip missing;
			missing.name = animation;
			indices[animation] = static_cast<int64_t>(definitions[track.definition].clips.size());
			definitions[track.definition].clips.push_back(missing);
		}
		track.clip = static_cast<int>(indices[animation]);
		track.frame = mirror->get("frame");
		track.elapsed = mirror->get("elapsed");
		tracks.push_back(track);
	}
}

PackedInt32Array NativeMonsterTimeline::advance(double delta) {
	static const StringName elapsed_name("elapsed"), frame_name("frame"), animation_name("animation");
	PackedInt32Array changed;
	for (size_t i = 0; i < tracks.size(); ++i) {
		Track &track = tracks[i];
		if (track.mirror.is_null()) continue;
		const Definition &definition = definitions[track.definition];
		const Clip *clip = &definition.clips[track.clip];
		int64_t frame_count = clip->frames;
		if (frame_count == 0) continue;
		track.elapsed += delta;
		bool advanced = false;
		// Keep repeated subtraction, including leftover time across next/default
		// clips. Quotient/fmod shortcuts change boundary rounding and timing.
		while (track.elapsed >= clip->delay) {
			track.elapsed -= clip->delay;
			advanced = true;
			if (++track.frame < frame_count) continue;
			track.frame = 0;
			if (clip->loop) continue;
			track.clip = clip->next;
			clip = &definition.clips[track.clip];
			frame_count = std::max<int64_t>(clip->frames, 1);
		}
		track.mirror->set(elapsed_name, track.elapsed);
		if (advanced) {
			track.mirror->set(frame_name, track.frame);
			track.mirror->set(animation_name, clip->name);
			changed.push_back(static_cast<int32_t>(i));
		}
	}
	return changed;
}
}
