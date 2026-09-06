class_name RemoveMaterial
extends Node

@onready var parent := get_parent() as Node2D


func _ready() -> void:
	parent.material = null
