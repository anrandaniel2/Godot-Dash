class_name PulseWhite
extends Node

@export var pulse_target: Node2D
@onready var parent := get_parent() as Interactable
var _factor: float


func _ready() -> void:
	# Most portals are idle for the entire level. Keep this callback dormant
	# until an interaction actually starts the visual pulse.
	set_process(false)
	parent.interacted.connect(pulse)
	_factor = 0.0
	pulse_target.set_instance_shader_parameter(&"factor", _factor)
	pulse_target.set_instance_shader_parameter(&"pulse_color", Color.WHITE)
	if pulse_target.get_child_count() > 0:
		for child: Node2D in pulse_target.get_children():
			child.use_parent_material = false
			child.material = pulse_target.material
			child.set_instance_shader_parameter(&"factor", _factor)
			child.set_instance_shader_parameter(&"pulse_color", Color.WHITE)


func _process(delta: float) -> void:
	if is_zero_approx(_factor):
		set_process(false)
		return
	_factor = move_toward(_factor, 0.0, delta * 6)
	pulse_target.set_instance_shader_parameter(&"factor", _factor)
	if pulse_target.get_child_count() > 0:
		for child: Node2D in pulse_target.get_children():
			child.set_instance_shader_parameter(&"factor", _factor)
	if is_zero_approx(_factor):
		set_process(false)


func pulse(_player: Player) -> void:
	if parent.has(NoEffectsComponent):
		return
	_factor = 1.0
	set_process(true)
