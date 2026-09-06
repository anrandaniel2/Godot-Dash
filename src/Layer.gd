@icon("res://addons/at-icons/node2d/layers.svg")
class_name Layer
extends Node2D
## Marker class to identify layers in the level.

var hidden_in_editor: bool = false:
	set(value):
		hidden_in_editor = value
		modulate.a = 1.0 if not value else Config.hidden_layers_alpha
var locked: bool = false
var selected_in_editor: bool = false


static func deselect(layer: Layer) -> void:
	layer.selected_in_editor = false


static func is_selected(layer: Layer) -> bool:
	return layer.selected_in_editor
