extends Node

enum Scene {
	TITLE_SCREEN,
	EDITOR,
	LEVEL,
}

var is_transitioning: bool

var _current: Scene
var _previous: Scene


func set_current_scene(scene: Scene) -> void:
	_previous = _current
	_current = scene


func get_current_scene() -> Scene:
	return _current


func in_title_screen() -> bool:
	return _current == Scene.TITLE_SCREEN


func in_editor() -> bool:
	return _current == Scene.EDITOR


func in_level() -> bool:
	return _current == Scene.LEVEL


func from_title_screen() -> bool:
	return _previous == Scene.TITLE_SCREEN


func from_editor() -> bool:
	return _previous == Scene.EDITOR


func from_level() -> bool:
	return _previous == Scene.LEVEL
