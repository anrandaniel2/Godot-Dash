# Copied to the Godot source root as custom.py before the Android template
# build. SCons loads it automatically, including the Gradle re-invocation.
#
# Speed is not traded for size. Do not set optimize = "size" or "size_extra".
# Official Android release builds already force lto=auto to none, so this
# matches that policy: remaining code is compiled for speed, unused modules
# are simply not linked.
optimize = "speed"
debug_symbols = "no"
disable_3d = "no"

# XR and other modules this 2D project never references. Kept on purpose:
# gdscript, glslang (runtime shaders), freetype, text_server_adv (Inter),
# svg, mp3/ogg/vorbis, webp/jpg, zip (GMD), regex (search bar), mbedtls
# (HTTPS), godot_physics_2d, and godot_physics_3d (engine still starts a
# 3D physics server). FastNoiseLite is core, not module_noise. RayCast2D
# is not module_raycast (that module is Embree lightmap/occlusion).
_DISABLED = (
    "openxr",
    "webxr",
    "mobile_vr",
    "camera",
    "csg",
    "gridmap",
    "fbx",
    "gltf",
    "theora",
    "navigation_2d",
    "navigation_3d",
    "enet",
    "multiplayer",
    "webrtc",
    "websocket",
    "upnp",
    "jsonrpc",
    "interactive_music",
    "msdfgen",
    "meshoptimizer",
    "vhacd",
    "tinyexr",
    "hdr",
    "dds",
    "ktx",
    "bmp",
    "tga",
    "basis_universal",
    "astcenc",
    "bcdec",
    "cvtt",
    "betsy",
    "etcpak",
    "noise",
    "raycast",
    "lightmapper_rd",
    "xatlas_unwrap",
    "visual_shader",
    "jolt_physics",
    "objectdb_profiler",
    "text_server_fb",
    "mono",
)

for _name in _DISABLED:
    globals()[f"module_{_name}_enabled"] = "no"
