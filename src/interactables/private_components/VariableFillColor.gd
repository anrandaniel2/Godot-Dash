@tool
class_name VariableFillColor
extends Node2D

func _process(_delta: float) -> void:
	$"../ParticleEmitter".modulate = modulate
	$"../Fill".modulate = modulate
