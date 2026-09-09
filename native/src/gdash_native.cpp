// gdash_native - first slice of the native (C++) runtime for Godot Dash.
//
// Scope (see GD_UNIFICATION_PLAN.md / the level-open work): the play build
// used to give every level placement its own scene node, and a decorated
// level's ~170,000 decoration sprites (plus gameplay placements) cost enough
// RAM per node that large levels force-closed on Android. GDScript already
// collapsed decoration into shared DecorationBatch canvas items; this library
// is the substrate for the next step - native level records and
// RenderingServer-driven rendering/physics that replace per-object nodes
// entirely, plus the native 240 Hz player core. Gameplay logic and the editor
// stay in GDScript.
//
// This first slice only proves the toolchain end to end: the library is
// compiled by CI with godot-cpp v10 against the Godot 4.7 API, bundled into
// the Android APK through native/gdash_native.gdextension, and loaded by the
// engine at startup. GdashNative::build_string() reports the exact binaries
// inside the library so a device can confirm the load without logcat.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <algorithm>
#include <climits>
#include <cstdint>
#include <numeric>
#include <vector>

namespace godot {

class GdashNative : public RefCounted {
	GDCLASS(GdashNative, RefCounted)

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("build_string"), &GdashNative::build_string);
		ClassDB::bind_method(D_METHOD("version"), &GdashNative::version);
		ClassDB::bind_method(D_METHOD("add", "a", "b"), &GdashNative::add);
		ClassDB::bind_method(
				D_METHOD("sort_indices", "primary", "secondary", "tertiary"),
				&GdashNative::sort_indices);
	}

public:
	/// Human-readable description of exactly what is compiled into this .so:
	/// library version, godot-cpp pin and targeted Godot API. Printed once at
	/// startup when Config.use_native_core is enabled, so a device test can
	/// confirm the bundled native build loaded without needing logcat.
	String build_string() const {
		return String("gdash_native 0.2.0 / godot-cpp 6cceaf6a5f8b / api 4.7");
	}

	/// Library version, for feature gating from GDScript.
	int64_t version() const { return 2; }

	/// Returns a stable lexicographic ordering for three integer key arrays.
	/// DecorationBatch uses this for its largest open-time CPU task. Keeping the
	/// sort in C++ avoids hundreds of thousands of GDScript comparator calls and
	/// the old five-Variant tuple allocated for every atlas sprite.
	PackedInt32Array sort_indices(
			const PackedInt64Array &primary,
			const PackedInt64Array &secondary,
			const PackedInt64Array &tertiary) const {
		const int64_t count = primary.size();
		PackedInt32Array result;
		if (secondary.size() != count || tertiary.size() != count || count > INT32_MAX) {
			return result;
		}
		std::vector<int32_t> indices(static_cast<size_t>(count));
		std::iota(indices.begin(), indices.end(), 0);
		std::stable_sort(indices.begin(), indices.end(), [&](int32_t a, int32_t b) {
			if (primary[a] != primary[b]) return primary[a] < primary[b];
			if (secondary[a] != secondary[b]) return secondary[a] < secondary[b];
			return tertiary[a] < tertiary[b];
		});
		result.resize(count);
		for (int64_t i = 0; i < count; ++i) {
			result.set(i, indices[static_cast<size_t>(i)]);
		}
		return result;
	}

	/// Trivial arithmetic sanity check used by the startup probe.
	int64_t add(int64_t a, int64_t b) const { return a + b; }
};

} // namespace godot

namespace {

void gdash_native_initialize(godot::ModuleInitializationLevel p_level) {
	if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	using namespace godot;
	GDREGISTER_CLASS(GdashNative);
}

void gdash_native_terminate(godot::ModuleInitializationLevel p_level) {
	if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

} // namespace

extern "C" {
// Initialization.

GDExtensionBool GDE_EXPORT gdash_native_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(gdash_native_initialize);
	init_obj.register_terminator(gdash_native_terminate);
	init_obj.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
