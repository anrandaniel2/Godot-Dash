class_name OneShotAnimatedSprite
extends AnimatedSprite2D

func _ready() -> void:
	play()
	animation_finished.connect(queue_free)
