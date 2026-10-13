class_name PerformanceOverlay
extends CanvasLayer

## Live performance numbers for the top-left corner, shown when the Gameplay
## setting "Show performance stats" is on. Read every quarter second; it costs
## one label update per quarter second and nothing while hidden.

const REFRESH_SECONDS: float = 0.25

var _label: Label
var _since_refresh: float = REFRESH_SECONDS


func _init() -> void:
	layer = 100
	follow_viewport_enabled = false


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(8, 8)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override(&"font_size", 14)
	_label.add_theme_color_override(&"font_shadow_color", Color.BLACK)
	_label.add_theme_constant_override(&"shadow_offset_x", 1)
	_label.add_theme_constant_override(&"shadow_offset_y", 1)
	add_child(_label)
	Config.performance_stats_changed.connect(_set_enabled)
	_set_enabled(Config.show_performance_stats)


func _set_enabled(enabled: bool) -> void:
	visible = enabled
	set_process(enabled)
	_since_refresh = REFRESH_SECONDS


func _process(delta: float) -> void:
	_since_refresh += delta
	if _since_refresh < REFRESH_SECONDS:
		return
	_since_refresh = 0.0
	_label.text = _build_text()


func _build_text() -> String:
	var process_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var lines: PackedStringArray = [
		"FPS %d   frame %.2f ms   process %.2f ms   physics %.2f ms" % [
			Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0), process_ms, physics_ms],
		"physics %d ticks/s   game speed %.2fx   time scale %.2f" % [
			Engine.physics_ticks_per_second, Config.game_speed, Engine.time_scale],
		"draw calls %d   objects drawn %d" % [
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))],
		"nodes %d   orphans %d   static memory %.1f MB" % [
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0],
		"2D physics: active bodies %d   pairs %d   islands %d" % [
			int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)),
			int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)),
			int(Performance.get_monitor(Performance.PHYSICS_2D_ISLAND_COUNT))],
	]
	return "\n".join(lines)
