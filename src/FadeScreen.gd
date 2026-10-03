class_name FadeScreen
extends CanvasLayer

signal fade_finished

var is_fading: bool

enum FadeType {
	FADE_IN,
	FADE_OUT,
}

var fade_tween: Tween


func _ready() -> void:
	$ColorRect.color = Color.BLACK
	hide()


func fade_in() -> void:
	is_fading = true
	show()
	if fade_tween:
		fade_tween.kill()
	fade_tween = create_tween().set_ignore_time_scale(true)
	fade_tween \
			.tween_property($ColorRect, ^"color", Color.BLACK, Config.transition_duration) \
			.set_ease(Tween.EASE_IN) \
			.set_trans(Tween.TRANS_SINE) \
			.from(Color.hex(0x00000000)) # transparent black
	await fade_tween.finished
	fade_finished.emit(FadeType.FADE_IN)
	is_fading = false


func fade_out() -> void:
	is_fading = true
	show()
	if fade_tween:
		fade_tween.kill()
	fade_tween = create_tween().set_ignore_time_scale(true)
	fade_tween \
			.tween_property($ColorRect, ^"color", Color.hex(0x00000000), Config.transition_duration) \
			.set_ease(Tween.EASE_OUT) \
			.set_trans(Tween.TRANS_SINE) \
			.from(Color.BLACK)
	await fade_tween.finished
	fade_finished.emit(FadeType.FADE_OUT)
	hide()
	is_fading = false


func anticipate_fade_out() -> void:
	$ColorRect.color = Color.BLACK
	show()
