class_name QuickGizmoValueInput
extends Node

signal value_changed(value: float)
signal axis_constraint_changed(axis_constraint: AxisConstraint)

enum AxisConstraint {
	NONE,
	GLOBAL_X,
	LOCAL_X,
	GLOBAL_Y,
	LOCAL_Y,
	DISABLED,
}

const NUMBERS: String = "0123456789"

## The typed value as a float
var value: float:
	get():
		_expression_evaluator.parse(_make_expression_evaluate_to_float(_expression))
		var evaluated_expression: Variant = _expression_evaluator.execute()
		return evaluated_expression as float if evaluated_expression else NAN
## The value before it was overriden by the typed value
var original_value: float:
	set(new_value):
		original_value = new_value
		update_keychord_display(_expression)
## The action done by the gizmo, e.g. "Rotating", "Scaling" or "Moving"
var displayed_gizmo_action: String
## The unit of the action done by the gizmo, e.g. "°" (rotation), "×" (scale) or "cells" (movement)
var displayed_gizmo_unit: String
## The Label that will display the gizmo action and the expression. Required.
var keychord_display: Label
var axis_constraint: AxisConstraint:
	set(new_axis_constraint):
		previous_axis_constraint = axis_constraint
		axis_constraint = new_axis_constraint
		axis_constraint_changed.emit(new_axis_constraint)
		if is_finite(value):
			value_changed.emit(value)
var previous_axis_constraint: AxisConstraint
var is_snapped: bool = false
var snap_interval: float = 0.5

var _expression: String:
	set(new_expression):
		_expression = new_expression

		if new_expression.is_empty():
			value_changed.emit(original_value)
		elif is_finite(value):
			value_changed.emit(value)

		if keychord_display:
			update_keychord_display(new_expression)

var _expression_evaluator := Expression.new()


func _init(_keychord_display: Label, _displayed_gizmo_action: String, _displayed_gizmo_unit: String, disable_axis_constraint: bool = false) -> void:
	keychord_display = _keychord_display
	displayed_gizmo_action = _displayed_gizmo_action
	displayed_gizmo_unit = _displayed_gizmo_unit
	if disable_axis_constraint:
		axis_constraint = AxisConstraint.DISABLED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		match event.key_label:
			KEY_1, KEY_KP_1:
				_expression += "1"
			KEY_2, KEY_KP_2:
				_expression += "2"
			KEY_3, KEY_KP_3:
				_expression += "3"
			KEY_4, KEY_KP_4:
				_expression += "4"
			KEY_5, KEY_KP_5:
				_expression += "5"
			KEY_6, KEY_KP_6:
				_expression += "6"
			KEY_7, KEY_KP_7:
				_expression += "7"
			KEY_8, KEY_KP_8:
				_expression += "8"
			KEY_9, KEY_KP_9:
				_expression += "9"
			KEY_0, KEY_KP_0:
				_expression += "0"
			KEY_MINUS, KEY_KP_SUBTRACT, KEY_UNDERSCORE:
				_expression += "-"
			KEY_PLUS, KEY_KP_ADD, KEY_EQUAL:
				_expression += "+"
			KEY_ASTERISK, KEY_KP_MULTIPLY:
				_expression += "*"
			KEY_SLASH, KEY_KP_DIVIDE:
				_expression += "/"
			KEY_PARENLEFT:
				_expression += "("
			KEY_PARENRIGHT:
				_expression += ")"
			KEY_PERIOD, KEY_KP_PERIOD:
				if not _expression.contains("."):
					_expression += "."
				else:
					var can_add_period := true
					var has_number := false
					for character: String in _expression.reverse():
						if character == "." and has_number:
							# Period before number, invalid
							can_add_period = false
							break
						# Not a period and not a number. If a number was found before, allow adding a period.
						elif not NUMBERS.contains(character):
							can_add_period = has_number
							break
						else:
							has_number = true
					if can_add_period:
						_expression += "."
			KEY_X:
				match axis_constraint:
					AxisConstraint.NONE:
						axis_constraint = AxisConstraint.GLOBAL_X
					AxisConstraint.GLOBAL_X:
						axis_constraint = AxisConstraint.LOCAL_X
					AxisConstraint.LOCAL_X:
						axis_constraint = AxisConstraint.NONE
				update_keychord_display(_expression)
			KEY_Y:
				match axis_constraint:
					AxisConstraint.NONE:
						axis_constraint = AxisConstraint.GLOBAL_Y
					AxisConstraint.GLOBAL_Y:
						axis_constraint = AxisConstraint.LOCAL_Y
					AxisConstraint.LOCAL_Y:
						axis_constraint = AxisConstraint.NONE
				update_keychord_display(_expression)
			KEY_BACKSPACE:
				_expression = _expression.left(-1)


func update_keychord_display(new_expression: String) -> void:
	if new_expression.is_empty():
		keychord_display.text = "%s: %.2f%s" % [displayed_gizmo_action, original_value if not is_snapped else snappedf(original_value, snap_interval), displayed_gizmo_unit]
	else:
		keychord_display.text = "%s: [%s] = %.2f%s" % [displayed_gizmo_action, _expression, value, displayed_gizmo_unit]
	match axis_constraint:
		AxisConstraint.GLOBAL_X:
			keychord_display.text += " along global X"
		AxisConstraint.LOCAL_X:
			keychord_display.text += " along local X"
		AxisConstraint.GLOBAL_Y:
			keychord_display.text += " along global Y"
		AxisConstraint.LOCAL_Y:
			keychord_display.text += " along local Y"
	# FIX: the text it too close to the edge of the screen when the inspector is hidden
	keychord_display.text += " "


func has_value() -> bool:
	return not _expression.is_empty()


func get_axis_constraint() -> AxisConstraint:
	return axis_constraint


func is_global_axis() -> bool:
	return axis_constraint == AxisConstraint.GLOBAL_X or axis_constraint == AxisConstraint.GLOBAL_Y


func _make_expression_evaluate_to_float(expression: String) -> String:
	# We need at least one float in the expression for it to evaluate to a float.
	if "." in expression:
		return expression
	var float_expression := expression
	var insert_decimal_at := float_expression.length()
	for character: String in float_expression.reverse():
		if NUMBERS.contains(character):
			float_expression = float_expression.insert(insert_decimal_at, ".0")
			break
		else:
			insert_decimal_at -= 1
	return float_expression
