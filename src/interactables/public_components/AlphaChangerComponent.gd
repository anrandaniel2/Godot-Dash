class_name AlphaChangerComponent
extends Component

enum Mode {
	SET,
	MULTIPLY,
	COPY,
}

@export var mode: Mode = Mode.SET:
	set(value):
		mode = value
		notify_property_list_changed()
@export_range(0.0, 1.0, 0.01, "slider", "percentage") var alpha: float = 1.0
@export var copy_target: NodePath
@export_range(0.0, 1.0, 0.01, "or_greater") var copy_multiplier: float = 1.0

@export_storage var initial_alphas: Dictionary[HSVWatcher, float]
@export_storage var group_hsv_watchers: Array[HSVWatcher]

## Batched decoration in the target group, faded as a whole rather than through
## a per-object watcher.
var _group_batches: Array[DecorationBatch] = []
var _initial_batch_alphas: Dictionary[DecorationBatch, float] = { }
@export_storage var copy_target_hsv_watcher: HSVWatcher


func _ready() -> void:
	await require([TargetGroupComponent, EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _validate_property(property: Dictionary) -> void:
	if property.name == "alpha" and mode == Mode.COPY:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name in ["copy_target", "copy_multiplier"] and mode != Mode.COPY:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"mode": Mode.SET,
		"alpha": 1.0,
		"copy_target": NodePath(),
		"copy_multiplier": 1.0,
	}
	return DEFAULT_VALUES.get(property)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_alphas":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return DictUtils.map_keys(initial_alphas, Serialize.Node)
		"group_hsv_watchers":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return group_hsv_watchers.map(Serialize.Node)
		"copy_target_hsv_watcher":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return Serialize.Node(copy_target_hsv_watcher)
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"initial_alphas":
			# A saved NodePath can fail to resolve - decoration is drawn in
			# batches now, so paths recorded into individual decoration nodes no
			# longer point at anything. Dropping those entries keeps the typed
			# collections free of nulls.
			initial_alphas.assign(Deserialize.NodeKeyedDict(field_data))
		"group_hsv_watchers":
			group_hsv_watchers.assign(Deserialize.Nodes(field_data))
		"copy_target_hsv_watcher":
			copy_target_hsv_watcher = Deserialize.Node(field_data)
		_:
			set(field_name, field_data)


func start(_player: Player) -> void:
	# Not every node in a group owns an HSVWatcher - a DecorationBatch draws its
	# sprites directly and has none - so the nulls are filtered out before use.
	var targets: Array = get_tree() \
			.get_nodes_in_group(parent.query(TargetGroupComponent).target_group) \
			.filter(func(object): return object is Node2D)
	group_hsv_watchers.assign(
		targets \
				.map(BaseDetailHandler.use_hsv_watcher) \
				.filter(func(hsv_watcher): return hsv_watcher != null),
	)
	group_hsv_watchers.map(func(hsv_watcher: HSVWatcher): initial_alphas.set(hsv_watcher, hsv_watcher.alpha))

	# Batched decoration is faded through its own alpha instead.
	#
	# The loop variable is narrowed to DecorationBatch before it touches the
	# typed dictionary: `target` is statically a Node2D, and GDScript will not
	# accept that as a key for Dictionary[DecorationBatch, float] even inside an
	# `is` check.
	_group_batches.clear()
	_initial_batch_alphas.clear()
	for target: Node2D in targets:
		if target is not DecorationBatch:
			continue
		var batch: DecorationBatch = target
		_group_batches.append(batch)
		_initial_batch_alphas[batch] = batch.modulate.a
	if group_hsv_watchers.is_empty():
		Toasts.warning("In %s: target group doesn't contain any objects" % parent.name)
	if mode == Mode.COPY and copy_target == null and Editor.in_editor:
		Toasts.error("In %s: copy target is unset" % parent.name)
		if not copy_target.is_empty():
			var copy_target_ref: Node = LevelManager.current_level.get_node_or_null(copy_target)
			if not copy_target_ref:
				Toasts.error("In %s: invalid copy target" % parent.name)
				return
			copy_target_hsv_watcher = BaseDetailHandler.use_hsv_watcher(copy_target_ref)


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	for hsv_watcher: HSVWatcher in group_hsv_watchers:
		# Defensive: an entry can still be missing if the object was freed after
		# start() ran, and reading .alpha off nothing would take down the frame.
		if hsv_watcher == null or not is_instance_valid(hsv_watcher):
			continue
		var initial_alpha: float = initial_alphas.get(hsv_watcher, hsv_watcher.alpha)
		match mode:
			Mode.SET:
				hsv_watcher.alpha += (alpha - initial_alpha) * weight_delta
			Mode.MULTIPLY:
				hsv_watcher.alpha += (alpha * initial_alpha - initial_alpha) * weight_delta
			Mode.COPY:
				if copy_target_hsv_watcher:
					hsv_watcher.alpha += (copy_target_hsv_watcher.alpha * copy_multiplier - initial_alpha) * weight_delta
		hsv_watcher.update_color()

	for batch: DecorationBatch in _group_batches:
		var initial_batch_alpha: float = _initial_batch_alphas.get(batch, 1.0)
		var target_alpha: float = initial_batch_alpha
		match mode:
			Mode.SET:
				target_alpha = alpha
			Mode.MULTIPLY:
				target_alpha = alpha * initial_batch_alpha
			Mode.COPY:
				if copy_target_hsv_watcher:
					target_alpha = copy_target_hsv_watcher.alpha * copy_multiplier
		batch.modulate.a += (target_alpha - initial_batch_alpha) * weight_delta
