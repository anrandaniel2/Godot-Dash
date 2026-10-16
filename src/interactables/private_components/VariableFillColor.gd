@tool
class_name VariableFillColor
extends Node2D

@onready var _particle_emitter: CanvasItem = $"../ParticleEmitter"
@onready var _fill: CanvasItem = $"../Fill"


func _process(_delta: float) -> void:
	# These siblings only need updates when this node's channel color changes.
	# Retain the live check, but skip repeated property writes at steady color.
	if _particle_emitter.modulate != modulate:
		_particle_emitter.modulate = modulate
	if _fill.modulate != modulate:
		_fill.modulate = modulate
