class_name HideParticlesAttribute
extends HideAttribute

@onready var parent := get_parent()


func _ready() -> void:
	var particles_emitter := parent.get_node_or_null(^"ParticleEmitter")
	if particles_emitter:
		particles_emitter.hide()


func _exit_tree() -> void:
	var particles_emitter := parent.get_node_or_null(^"ParticleEmitter")
	if particles_emitter:
		particles_emitter.show()
