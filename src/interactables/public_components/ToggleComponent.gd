class_name ToggleComponent
extends Component

signal send_to_group_display(group_name: String)

@export var toggled_groups: Array[ToggledGroup]:
	set(value):
		toggled_groups = value
		update_group_display()

@export_storage var used_times: int = 0

## GD 2.1 item triggers share this component (twin of the native PICKUP /
## COUNT / INSTANT_COUNT arms). NONE is the plain Toggle trigger.
enum ItemMode { NONE, PICKUP, COUNT, INSTANT_COUNT }

## Key 88 of Instant Count.
enum CompareMode { EQUALS, LARGER, SMALLER }

@export var item_mode: ItemMode = ItemMode.NONE
@export var item_id: int = 0
## Pickup: amount added. Count / Instant Count: target value (key 77).
@export var item_count: int = 0
@export var compare_mode: CompareMode = CompareMode.EQUALS
@export var multi_activate: bool = false
## Key 56 checked: spawn the target groups instead of toggling them off.
@export var spawn_group: bool = false

## Level-wide item counters, cleared on restart by reset_items().
static var item_counts: Dictionary[int, int] = {}
static var _armed_counts: Array[ToggleComponent] = []


static var _persistent_items: Dictionary[int, bool] = {}
static var _persistent_timers: Dictionary[int, bool] = {}
static var _persist_all_items: bool = false
static var _persist_all_timers: bool = false


## A restart keeps persistent items and timers (3641), clears the rest. Twin
## of the native reset_gameplay_state.
static func reset_items() -> void:
	var kept: Dictionary[int, int] = {}
	for id: int in item_counts:
		if _persist_all_items or _persistent_items.has(id):
			kept[id] = item_counts[id]
	item_counts = kept
	_armed_counts.clear()
	var kept_timers: Dictionary[int, Dictionary] = {}
	for id: int in GameplayTriggerComponent.timers:
		if _persist_all_timers or _persistent_timers.has(id):
			kept_timers[id] = GameplayTriggerComponent.timers[id]
	GameplayTriggerComponent.reset_state()
	GameplayTriggerComponent.timers = kept_timers


## Persistent Item Setup (3641): keys 80 id, 491 set, 492 all, 493 reset, 494 timer.
static func set_persistent(id: int, persistent: bool, all: bool, reset: bool, timer: bool) -> void:
	var ids: Dictionary[int, bool] = _persistent_timers if timer else _persistent_items
	if reset:
		# Reset zeroes the value(s); persistence is left as is.
		var all_flag: bool = _persist_all_timers if timer else _persist_all_items
		var targets: Array[int] = [id]
		if all:
			targets.clear()
			var source: Dictionary = GameplayTriggerComponent.timers if timer else item_counts
			for key: int in source:
				if all_flag or ids.has(key):
					targets.append(key)
		for target: int in targets:
			if timer:
				if GameplayTriggerComponent.timers.has(target):
					GameplayTriggerComponent.timers[target]["value"] = 0.0
			elif int(item_counts.get(target, 0)) != 0:
				change_item(target, -int(item_counts[target]), null)
	elif all:
		if timer:
			_persist_all_timers = persistent
		else:
			_persist_all_items = persistent
	elif persistent:
		ids[id] = true
	else:
		ids.erase(id)


static func change_item(changed_id: int, delta: int, player: Player) -> void:
	var previous: int = item_counts.get(changed_id, 0)
	var current: int = previous + delta
	item_counts[changed_id] = current
	for counter: ToggleComponent in _armed_counts.duplicate():
		if not is_instance_valid(counter):
			_armed_counts.erase(counter)
			continue
		if counter.item_id != changed_id or current != counter.item_count or previous == counter.item_count:
			continue
		if not counter.multi_activate:
			_armed_counts.erase(counter)
		counter.fire_item_action(player)


func _ready() -> void:
	parent.interacted.connect(_on_interacted)


func _on_interacted(player: Player = null) -> void:
	match item_mode:
		ItemMode.NONE:
			toggle(player)
		ItemMode.PICKUP:
			change_item(item_id, item_count, player)
		ItemMode.COUNT:
			if not _armed_counts.has(self):
				_armed_counts.append(self)
		ItemMode.INSTANT_COUNT:
			if _compare(item_counts.get(item_id, 0)):
				fire_item_action(player)


func _compare(value: int) -> bool:
	match compare_mode:
		CompareMode.LARGER:
			return value > item_count
		CompareMode.SMALLER:
			return value < item_count
		_:
			return value == item_count


func fire_item_action(player: Player) -> void:
	if not spawn_group:
		toggle(player)
		return
	for toggled_group: ToggledGroup in toggled_groups:
		for node: Node in get_tree().get_nodes_in_group(Constants.GROUP_PREFIX + toggled_group.group):
			if node.has_signal(&"interacted"):
				node.interacted.emit(player)


func toggle(_player: Player = null) -> void:
	for toggled_group in toggled_groups:
		var group = Constants.GROUP_PREFIX + toggled_group.group
		var state = toggled_group.state
		var enable := func(object):
			object.show()
			object.process_mode = PROCESS_MODE_INHERIT
		var disable := func(object):
			object.hide()
			object.process_mode = PROCESS_MODE_DISABLED
		var objects_in_group := get_tree().get_nodes_in_group(group)
		if state == ToggledGroup.ToggleState.ON:
			objects_in_group.map(enable)
		elif state == ToggledGroup.ToggleState.OFF:
			objects_in_group.map(disable)
		elif state == ToggledGroup.ToggleState.FLIP:
			for object in objects_in_group:
				if object.process_mode == PROCESS_MODE_INHERIT: # If it is toggled on
					object.set_deferred(&"process_mode", PROCESS_MODE_DISABLED)
					object.hide()
				elif object.process_mode == PROCESS_MODE_DISABLED: # If it is toggled off
					object.set_deferred(&"process_mode", PROCESS_MODE_INHERIT)
					object.show()
	used_times += 1


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"toggled_groups":
			return toggled_groups.map(func(toggled_group: ToggledGroup): return toggled_group.to_data())
		"used_times":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return used_times
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"toggled_groups":
			toggled_groups.assign(field_data.map(func(toggled_group_data: Dictionary): return ToggledGroup.from_data(toggled_group_data)))
			update_group_display()
		"used_times":
			used_times = field_data
			if used_times % 2 == 1:
				toggle.call_deferred()
		_:
			set(field_name, field_data)


func update_group_display() -> void:
	if toggled_groups.size() == 1:
		send_to_group_display.emit(toggled_groups[0].group)
	else:
		send_to_group_display.emit("")
