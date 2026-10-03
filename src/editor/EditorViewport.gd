class_name EditorViewport
extends Control

var _is_cursor_shape_overriden: bool
var _saved_cursor_shape: CursorShape


func override_cursor_shape(cursor_shape: CursorShape) -> void:
	if not _is_cursor_shape_overriden:
		_saved_cursor_shape = mouse_default_cursor_shape
	mouse_default_cursor_shape = cursor_shape
	_is_cursor_shape_overriden = true


func remove_cursor_shape_override() -> void:
	mouse_default_cursor_shape = _saved_cursor_shape
	_is_cursor_shape_overriden = false


func is_cursor_shape_overriden() -> bool:
	return _is_cursor_shape_overriden
