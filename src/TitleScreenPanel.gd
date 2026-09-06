class_name TitleScreenPanel
extends PanelContainer

var tween: Tween
var target_visible: bool = false
var offset: float

@onready var initial_anchor_left = anchor_left
@onready var initial_anchor_right = anchor_right


func _ready() -> void:
	offset = 1.0 - anchor_left
	anchor_left += offset
	anchor_right += offset


func show_tween() -> void:
	target_visible = true
	top_level = true
	show()
	if tween:
		tween.stop()
	tween = create_tween().set_ignore_time_scale(true).set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	tween.tween_property(self, ^"anchor_left", initial_anchor_left, Config.transition_duration)
	tween.tween_property(self, ^"anchor_right", initial_anchor_right, Config.transition_duration)
	await tween.finished
	top_level = false


func hide_tween() -> void:
	target_visible = false
	top_level = false
	if tween:
		tween.stop()
	tween = create_tween().set_ignore_time_scale(true).set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	tween.tween_property(self, ^"anchor_left", initial_anchor_left + offset, Config.transition_duration)
	tween.tween_property(self, ^"anchor_right", initial_anchor_right + offset, Config.transition_duration)
	await tween.finished
	hide()
