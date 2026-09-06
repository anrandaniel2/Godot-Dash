class_name ViewportSizeValue
extends Node

@export var property: StringName

var viewport_size: Vector2

@onready var parent := get_parent() as Node


func _ready() -> void:
	viewport_size = parent.get_viewport_rect().size
	if parent.get(property) == null or parent.get(property) == Vector2.ZERO: # Needs to run after SaveLoadConfigValue
		parent.set(property, viewport_size)
