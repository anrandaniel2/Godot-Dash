# Copied to the Godot source root as custom.py before the Android template
# build. SCons reads these as option defaults, including the values below.
#
# Speed is not traded for size. Do not set optimize to "size" or "size_extra".
# Official Android release builds force lto=auto to none, so remaining code
# is compiled for speed and unused modules are simply not linked.
optimize = "speed"
debug_symbols = "no"
disable_3d = "no"

# XR and other modules this 2D project never references.
# Kept: gdscript, glslang (runtime shaders), freetype, text_server_adv
# (Inter), svg, mp3/ogg/vorbis, webp/jpg, zip (GMD), regex (search bar),
# mbedtls (HTTPS), godot_physics_2d, and godot_physics_3d. FastNoiseLite is
# core, not module_noise. RayCast2D is not module_raycast (Embree).
module_openxr_enabled = "no"
module_webxr_enabled = "no"
module_mobile_vr_enabled = "no"
module_camera_enabled = "no"
module_csg_enabled = "no"
module_gridmap_enabled = "no"
module_fbx_enabled = "no"
module_gltf_enabled = "no"
module_theora_enabled = "no"
module_navigation_2d_enabled = "no"
module_navigation_3d_enabled = "no"
module_enet_enabled = "no"
module_multiplayer_enabled = "no"
module_webrtc_enabled = "no"
module_websocket_enabled = "no"
module_upnp_enabled = "no"
module_jsonrpc_enabled = "no"
module_interactive_music_enabled = "no"
module_msdfgen_enabled = "no"
module_meshoptimizer_enabled = "no"
module_vhacd_enabled = "no"
module_tinyexr_enabled = "no"
module_hdr_enabled = "no"
module_dds_enabled = "no"
module_ktx_enabled = "no"
module_bmp_enabled = "no"
module_tga_enabled = "no"
module_basis_universal_enabled = "no"
module_astcenc_enabled = "no"
module_bcdec_enabled = "no"
module_cvtt_enabled = "no"
module_betsy_enabled = "no"
module_etcpak_enabled = "no"
module_noise_enabled = "no"
module_raycast_enabled = "no"
module_lightmapper_rd_enabled = "no"
module_xatlas_unwrap_enabled = "no"
module_visual_shader_enabled = "no"
module_jolt_physics_enabled = "no"
module_objectdb_profiler_enabled = "no"
module_text_server_fb_enabled = "no"
module_mono_enabled = "no"
