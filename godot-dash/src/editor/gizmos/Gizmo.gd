@abstract
class_name Gizmo
extends Control

@warning_ignore("unused_signal")
signal confirmed(final_value: Variant)

static var HANDLE_RADIUS: float = 8.0

enum State {
	DISABLED,
	ENABLED,
	FORCED,
}

var quick_gizmo_value_input: QuickGizmoValueInput
var gizmo_scale: float
var state: State
var is_quick: bool
var is_removing: bool


func _init() -> void:
	HANDLE_RADIUS = 8.0 if not Config.is_touch_screen else 24.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		remove_gizmo(true)
	if event.is_action_pressed(&"ui_accept"):
		remove_gizmo(false)


func quick(keychord_display: Label, prefix: String, suffix: String, disable_axis_constraint: bool) -> void:
	is_quick = true
	quick_gizmo_value_input = QuickGizmoValueInput.new(keychord_display, prefix, suffix, disable_axis_constraint)
	add_child(quick_gizmo_value_input) # Required for _unhandled_input
	state = State.FORCED
	_quick()


func get_gizmo_local_mouse_position() -> Vector2:
	return (get_global_mouse_position() - global_position).rotated(-rotation)


func has_quick_value() -> bool:
	return quick_gizmo_value_input and quick_gizmo_value_input.has_value()


@abstract func remove_gizmo(reset: bool = false) -> void


@abstract func is_enabled() -> bool


@abstract func any_handle_hovered() -> bool


## Runs after [method Gizmo.quick]
@abstract func _quick() -> void
