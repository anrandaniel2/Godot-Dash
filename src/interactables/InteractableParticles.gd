class_name InteractableParticles
extends GPUParticles2D

@export var type: String
@export_storage var saved_preprocess: float = -1.0


func _ready() -> void:
	if saved_preprocess == -1.0:
		saved_preprocess = preprocess

	visible = (
			Config.particles_visibility & Config.ParticleVisibility[type]
			or (Editor.in_editor and not Config.show_particles_in_editor)
	)

	var music_scale: MusicScale = NodeUtils.get_child_of_type(self, MusicScale)
	if music_scale:
		music_scale.process_mode = Node.PROCESS_MODE_INHERIT if visible else Node.PROCESS_MODE_DISABLED

	var should_preprocess = (
			Config.particles_preprocessing & Config.ParticlePreprocessing[type]
			or (Editor.in_editor and not Config.preprocess_particles_in_editor)
	)
	preprocess = saved_preprocess if should_preprocess else 0.0
