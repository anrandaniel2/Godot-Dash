class_name InteractableParticles
extends GPUParticles2D

@export var type: String
@export_storage var saved_preprocess: float = -1.0

## A continuous emitter whose area is off screen stops emitting: nothing it
## makes can be seen from there. Particles already in flight finish their
## lifetime, and emission resumes as soon as the area is on screen again.
## The notifier reports the entry into view, so each emitter starts silent
## and the first visible frame turns it on. One-shot emitters are never paused.
var _screen_notifier: VisibleOnScreenNotifier2D


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

	if not Editor.in_editor and not one_shot:
		_screen_notifier = VisibleOnScreenNotifier2D.new()
		_screen_notifier.rect = visibility_rect
		_screen_notifier.screen_entered.connect(_set_emitting.bind(true))
		_screen_notifier.screen_exited.connect(_set_emitting.bind(false))
		add_child(_screen_notifier)
		emitting = false


func _set_emitting(on: bool) -> void:
	emitting = on
