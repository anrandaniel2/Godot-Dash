extends TriggerSprite

@export var toggle_component: ToggleComponent

const TEXTURE_ON: Texture2D = preload("res://assets/textures/triggers/ToggleOn.svg")
const TEXTURE_OFF: Texture2D = preload("res://assets/textures/triggers/ToggleOff.svg")
const TEXTURE_FLIP: Texture2D = preload("res://assets/textures/triggers/ToggleFlip.svg")
const TEXTURE_MULTIPLE: Texture2D = preload("res://assets/textures/triggers/ToggleMultipleGroups.svg")

## Cache key of the texture currently assigned (0 = none yet). Assigning the
## same texture again every frame, for every placed toggle trigger, was pure
## property-set churn with no visible change.
var _texture_key: int = 0


func _process(_delta: float) -> void:
	if not visible:
		return
	var key: int
	var target_texture: Texture2D
	if toggle_component.toggled_groups.size() == 1 and toggle_component.toggled_groups[0] != null:
		match toggle_component.toggled_groups[0].state:
			ToggledGroup.ToggleState.ON:
				key = 1
				target_texture = TEXTURE_ON
			ToggledGroup.ToggleState.OFF:
				key = 2
				target_texture = TEXTURE_OFF
			ToggledGroup.ToggleState.FLIP:
				key = 3
				target_texture = TEXTURE_FLIP
	else:
		key = 4
		target_texture = TEXTURE_MULTIPLE
	if key != _texture_key and target_texture != null:
		_texture_key = key
		self.texture = target_texture
