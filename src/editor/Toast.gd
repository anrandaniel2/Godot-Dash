class_name Toast
extends VBoxContainer

var lifetime: float
var persistent: bool
var fade_tween: Tween
var timer_bar_tween: Tween
var text: String:
	set(value):
		$Button.text = value
	get():
		return $Button.text
var pausable: bool

@export var timer_bar: ColorRect


func _ready() -> void:
	var pause_mode: Tween.TweenPauseMode = Tween.TWEEN_PAUSE_STOP if pausable else Tween.TWEEN_PAUSE_PROCESS
	fade_tween = create_tween().set_pause_mode(pause_mode)
	fade_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	fade_tween.tween_property(self, ^"modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT).from(0.0)
	if not persistent:
		timer_bar_tween = create_tween().set_pause_mode(pause_mode)
		timer_bar_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		timer_bar_tween.tween_property(timer_bar, ^"offset_transform_scale:x", 0.0, lifetime)
		$Timer.start(lifetime)
		$Timer.timeout.connect(dismiss)
		return
	timer_bar.queue_free()


func update_text(new_text: String) -> void:
	$Button.text = new_text


func dismiss() -> void:
	if $Button.mouse_entered.is_connected(_on_mouse_entered):
		$Button.mouse_entered.disconnect(_on_mouse_entered)
	if $Button.mouse_exited.is_connected(_on_mouse_exited):
		$Button.mouse_exited.disconnect(_on_mouse_exited)
	if fade_tween:
		fade_tween.kill()
	fade_tween = create_tween().set_parallel()
	fade_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	fade_tween.tween_property(self, ^"modulate:a", 0.0, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	fade_tween.tween_property(self, ^"theme_override_constants/separation", get_theme_constant(&"separation") - size.y, 0.5) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	fade_tween.chain().tween_callback(queue_free)


func _on_mouse_entered() -> void:
	if not persistent:
		$Timer.stop()
		timer_bar_tween.kill()
		timer_bar.offset_transform_scale.x = 1.0


func _on_mouse_exited() -> void:
	if not persistent:
		$Timer.start(lifetime)
		timer_bar_tween = create_tween()
		timer_bar_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		timer_bar_tween.tween_property(timer_bar, ^"offset_transform_scale:x", 0.0, lifetime)
