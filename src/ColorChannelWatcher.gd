class_name ColorChannelWatcher
extends Node

const WATCHER_GROUP_PREFIX := "watcher_"

## How many copy links a colour resolution may follow before giving up and
## returning white - GDRweb's CopyColor iteration budget, which is what keeps
## copy cycles (A copies B copies A) from recursing forever.
const COPY_ITERATIONS := 8

static var DEFAULT_DATA := ColorChannelData.new()

## Channels whose data changed while a refresh fan-out is already running. A
## copy chain refreshed from its source must not circle back and refresh the
## source again, so watcher ids on the stack are skipped.
static var _refresh_stack: Array[int] = []

## Lookup cache from channel id to its ColorChannelData, rebuilt whenever the
## current level changes. Copy resolution walks it on every refresh of a
## copying channel, so the O(channels) scan happens once per level instead.
## Both statics must stay untyped on purpose: static member type annotations
## are resolved eagerly at class load, and a `Level` or
## `Dictionary[int, ColorChannelData]` annotation here would close the
## Level -> ColorChannelData -> ColorChannelWatcher class-reference cycle and
## fail the whole script (and everything importing it) with a cyclic
## reference parse error.
static var _channel_cache: Dictionary = {}
static var _channel_cache_level = null

## Live-recolor counters for the BEAMDIAG heartbeat: every channel refresh
## after this watcher's first (import-time) one. A device logcat captured
## mid-level then shows whether the colour triggers are reaching the channel
## table at all. Reset by Level.setup_color_channel_watchers on each load.
static var live_recolor_count: int = 0
static var live_last_channel: String = ""



var data: ColorChannelData

## Watchers of the channels that copy this channel (directly, through
## copied_channel_id). When this channel recolours, they re-resolve and
## recolour their own members - the live behaviour a literal import-time
## colour could never provide.
var _dependents: Array[ColorChannelWatcher] = []
## The copied_channel_id this watcher is currently registered under on its
## source's watcher. -1 until the first refresh wires it.
var _wired_copy_source: int = -1

## Packed C++ index over this channel's HSVWatchers (see NativeColorChannelIndex).
## Null in the editor and on builds without the native extension; those keep the
## original GDScript loop below.
var _native_index: Object
## Group size and HSVWatcher.data_version at the time _native_index was
## configured. Either changing rebuilds the snapshot, so native recolouring can
## never go stale against watcher state mutated at runtime (a practice-snapshot
## restore re-applies per-object HSV data through HSVWatcher.use_data).
var _native_member_count: int = -1
var _native_watcher_version: int = -1
## Last blend state pushed to this channel's members: -1 unknown, 0 normal,
## 1 additive. Colour triggers refresh the channel every animation frame, so
## the blend flip is diffed instead of re-sent.
var _applied_blending: int = -1
## Whether the watcher's first (import-time) refresh already ran; everything
## after it is a live recolor and feeds the BEAMDIAG counters above.
var _had_first_refresh: bool = false


func _init(new_data: ColorChannelData) -> void:
	data = new_data
	data.watcher = self
	add_to_group(WATCHER_GROUP_PREFIX + data.associated_group)
	data.changed.connect(refresh_objects_color)


func _exit_tree() -> void:
	if is_queued_for_deletion():
		reset_objects_color()
	_unregister_copy_dependency()


func _ready() -> void:
	refresh_objects_color()


func refresh_objects_color(hsv_watchers: Array[HSVWatcher] = [], _data: ColorChannelData = data) -> void:
	var self_id := get_instance_id()
	var owns_fanout := _data == data
	if owns_fanout:
		_rewire_copy_dependency()
		if _refresh_stack.has(self_id):
			# A copy chain circled back here: this refresh was already started
			# further up the stack, so the cycle is broken by doing nothing.
			return
		_refresh_stack.append(self_id)
		if _had_first_refresh:
			live_recolor_count += 1
			live_last_channel = String(_data.associated_group).trim_prefix(
				Constants.COLOR_CHANNEL_GROUP_PREFIX
			)
		else:
			_had_first_refresh = true
	_apply_blending_if_changed(_data)
	if hsv_watchers.is_empty():
		if _refresh_native(_data):
			_refresh_decoration_batches(_data)
			_finish_fanout(owns_fanout, self_id)
			return
		hsv_watchers.assign(get_tree().get_nodes_in_group(_data.associated_group))
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.modulate = _channel_color(_data)
		hsv_watcher.modulate.s += _data.hsv_shift[1]
		hsv_watcher.modulate.v += _data.hsv_shift[2]
		hsv_watcher.modulate.h += _data.hsv_shift[0]
		hsv_watcher.base_intensity = _data.intensity
		hsv_watcher.base_alpha = _effective_alpha(_data)
		hsv_watcher.update_color()
	_refresh_decoration_batches(_data)
	_finish_fanout(owns_fanout, self_id)


## Ends a refresh's fan-out: pushes the fresh colour into every channel that
## copies this one, then pops the cycle-guard stack. Popping last is what
## breaks notification cycles: while A's fan-out refreshes B, A itself stays
## on the stack, so B's fan-out circling back to A is skipped instead of
## looping forever. Watchers whose level was freed without managing to
## unregister are dropped along the way.
func _finish_fanout(owns_fanout: bool, self_id: int) -> void:
	if not owns_fanout:
		return
	if not _dependents.is_empty():
		var alive: Array[ColorChannelWatcher] = []
		for dependent: ColorChannelWatcher in _dependents:
			if not is_instance_valid(dependent):
				continue
			alive.append(dependent)
			if dependent.is_inside_tree():
				dependent.refresh_objects_color()
		_dependents = alive
	_refresh_stack.erase(self_id)


## Moves this watcher between source watchers when its channel's copy link
## changes (a key 50 trigger re-points it at runtime). Runs on every refresh
## of the watcher's own channel but only touches the dependency lists when the
## link actually moved.
func _rewire_copy_dependency() -> void:
	var link := data.copied_channel_id
	if link == _wired_copy_source:
		return
	_unregister_copy_dependency()
	if link > 0:
		var source: ColorChannelData = channel_by_id(link)
		if source != null and source.watcher != null and source.watcher != self:
			source.watcher._dependents.append(self)
	_wired_copy_source = link


func _unregister_copy_dependency() -> void:
	if _wired_copy_source <= 0:
		return
	var old_source: ColorChannelData = channel_by_id(_wired_copy_source)
	if old_source != null and old_source.watcher != null:
		old_source.watcher._dependents.erase(self)
	_wired_copy_source = -1


## The ColorChannelData of a channel id in the current level, or null when the
## level has no such channel (the resolution then falls back to the channel's
## import-time colour).
static func channel_by_id(id: int) -> ColorChannelData:
	var level: Level = LevelManager.current_level
	if level == null:
		return null
	if _channel_cache_level != level:
		_channel_cache.clear()
		for channel: ColorChannelData in level.color_channels:
			_channel_cache[int(channel.associated_group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX))] = channel
		_channel_cache_level = level
	return _channel_cache.get(id)


## The live colour of a channel id, following special (level/player colour)
## ids just like a copy trigger does.
static func live_special_color(id: int) -> Color:
	var level: Level = LevelManager.current_level
	if level == null:
		return Color.WHITE
	match id:
		1000:
			return level.background_color
		1001, 1009:
			return level.ground_color
		1002:
			return level.line_color
		1005:
			return Config.primary_color
		1006:
			return Config.secondary_color
		_:
			return Color.WHITE


## A channel's fully resolved colour, ported from GDRweb's CopyColor
## evaluation: the source is read live (so it may itself be a copy, resolved
## recursively under the same iteration budget), then this channel's own copy
## HSV is applied on top. Channels without a link return their own colour.
## The alpha is deliberately NOT part of this colour: rendering alpha always
## flows through resolve_channel_alpha (the watcher's base_alpha), so a
## copy-opacity channel must never get both the source's alpha in the colour
## and its own in base_alpha.
static func resolve_channel_color(channel_data: ColorChannelData, iterations: int = COPY_ITERATIONS) -> Color:
	if iterations <= 0:
		return Color.WHITE
	if LevelManager.current_level == null:
		# Without a level there is nothing live to resolve: the import
		# snapshot is the best available answer.
		return channel_data.color
	if channel_data.copy:
		return _shift_copy_hsv(_special_color(channel_data.copied_channel), channel_data)
	if channel_data.copied_channel_id <= 0:
		return channel_data.color
	var source_id := channel_data.copied_channel_id
	if _is_special_id(source_id):
		return _shift_copy_hsv(live_special_color(source_id), channel_data)
	var source: ColorChannelData = channel_by_id(source_id)
	if source == null:
		# No runtime channel for the source (nothing uses it): the
		# import-time snapshot is the best available answer.
		return channel_data.color
	return _shift_copy_hsv(resolve_channel_color(source, iterations - 1), channel_data)


## The opacity a channel's members should use: its own, or the source's when
## it copies opacity (kS38 key 17 / trigger key 60). Copying a level/player
## colour without the opacity flag keeps the channel's own opacity.
static func resolve_channel_alpha(channel_data: ColorChannelData, iterations: int = COPY_ITERATIONS) -> float:
	if not channel_data.copy_opacity:
		return channel_data.alpha
	if channel_data.copy:
		return 1.0 # level and player colours are opaque
	if channel_data.copied_channel_id <= 0:
		return channel_data.alpha
	if iterations <= 0 or _is_special_id(channel_data.copied_channel_id):
		return 1.0
	var source: ColorChannelData = channel_by_id(channel_data.copied_channel_id)
	if source == null:
		return channel_data.alpha
	return resolve_channel_alpha(source, iterations - 1)


static func _is_special_id(id: int) -> bool:
	return id == 1000 or id == 1001 or id == 1002 or id == 1005 or id == 1006 or id == 1009


## Applies a channel's copy HSV adjustment (kS38 key 10 / trigger key 49) to a
## resolved source colour, in Geometry Dash's additive and multiplicative
## slider modes - GDRweb's HSVShift.shiftColor.
static func _shift_copy_hsv(base: Color, channel_data: ColorChannelData) -> Color:
	if is_zero_approx(channel_data.copy_hue) and is_zero_approx(channel_data.copy_saturation) \
			and is_zero_approx(channel_data.copy_value):
		return base
	return Color.from_hsv(
		fposmod(base.h + channel_data.copy_hue, 1.0),
		clampf(
			base.s + channel_data.copy_saturation if channel_data.copy_saturation_additive
			else base.s * channel_data.copy_saturation,
			0.0, 1.0),
		clampf(
			base.v + channel_data.copy_value if channel_data.copy_value_additive
			else base.v * channel_data.copy_value,
			0.0, 1.0),
		base.a,
	)


## The live colour of a special (level/player) channel enum.
static func _special_color(channel: Constants.SpecialColorChannel) -> Color:
	var level: Level = LevelManager.current_level
	if level == null:
		return Color.WHITE
	match channel:
		Constants.SpecialColorChannel.BACKGROUND:
			return level.background_color
		Constants.SpecialColorChannel.GROUND:
			return level.ground_color
		Constants.SpecialColorChannel.LINE:
			return level.line_color
		Constants.SpecialColorChannel.P1:
			return Config.primary_color
		Constants.SpecialColorChannel.P2:
			return Config.secondary_color
		Constants.SpecialColorChannel.GLOW:
			return Config.glow_color
	return Color.WHITE


## Recolours every watcher of this channel through the native index. One
## Variant call replaces a per-object GDScript method call plus roughly fifteen
## property accesses, which colour-pulse-heavy levels used to pay on every
## animation frame for every member of a channel. Returns false (and does
## nothing) whenever the portable path must run: the editor, explicit watcher
## subsets, resets, or builds without the extension.
func _refresh_native(_data: ColorChannelData) -> bool:
	if Editor.in_editor or _data != data or not NativeCore.available():
		return false
	if _native_index == null:
		if not ClassDB.class_exists(&"NativeColorChannelIndex"):
			return false
		_native_index = ClassDB.instantiate(&"NativeColorChannelIndex")
	var members: Array = get_tree().get_nodes_in_group(_data.associated_group)
	if _native_member_count != members.size() or _native_watcher_version != HSVWatcher.data_version:
		_native_index.call(&"configure", members)
		_native_member_count = members.size()
		_native_watcher_version = HSVWatcher.data_version
	var shift: Array[float] = _data.hsv_shift
	_native_index.call(
		&"apply", _channel_color(_data),
		shift[0] if shift.size() > 0 else 0.0,
		shift[1] if shift.size() > 1 else 0.0,
		shift[2] if shift.size() > 2 else 0.0,
		_data.intensity,
		_effective_alpha(_data),
	)
	return true


## This channel's own colour, with copies resolved live to their source colour
## (and that source's own copy chain, down to the iteration budget). Channel
## HSV shifts are applied on top of it, exactly like the GDScript loop (and
## the native index) do.
func _channel_color(channel_data: ColorChannelData) -> Color:
	return resolve_channel_color(channel_data)


## The opacity this channel's members should render with: the channel's own,
## or - for a copy channel with opacity copying enabled - its source's.
func _effective_alpha(channel_data: ColorChannelData) -> float:
	return resolve_channel_alpha(channel_data)


## Pushes a blending flip onto every decoration batch and object of this
## channel. Geometry Dash's colour triggers carry the channel's blend mode as
## part of their target state (the Blending checkbox, key 17); modern levels
## build their glow out of those mid-level flips.
func _apply_blending_if_changed(_data: ColorChannelData) -> void:
	var state: int = 1 if _data.blending else 0
	if state == _applied_blending:
		return
	_applied_blending = state
	if not is_inside_tree():
		return
	var channel := StringName(_data.associated_group)
	var additive := state == 1
	for node: Node in get_tree().get_nodes_in_group(DecorationBatch.CHANNEL_GROUP_PREFIX + channel):
		if node is DecorationBatch:
			node.apply_channel_blending(channel, additive)
	for watcher: Node in get_tree().get_nodes_in_group(_data.associated_group):
		var watched: Node2D = watcher.get("parent") if watcher is HSVWatcher else null
		if watched is GDObject:
			watched.set_channel_blending(additive)


## Pushes this channel's colour into every [DecorationBatch].
##
## Batched decoration has no [HSVWatcher] of its own - that is the point of
## batching - so it cannot be reached through the group above. Each batch
## recolours its own items in a single pass instead.
func _refresh_decoration_batches(_data: ColorChannelData) -> void:
	if not is_inside_tree() or LevelManager.current_level == null:
		return
	var channel := StringName(_data.associated_group)
	var color: Color = _channel_color(_data)
	color.s += _data.hsv_shift[1]
	color.v += _data.hsv_shift[2]
	color.h += _data.hsv_shift[0]
	# Intensity scales the colour, not the alpha, so multiply the RGB only.
	color = Color(color.r, color.g, color.b) * _data.intensity
	color.a = _effective_alpha(_data)

	# Batches register themselves in a group per channel, so only the ones that
	# actually use this channel are visited. Walking every layer's children for
	# each of a level's ~170 channels is otherwise a large, pointless cost at
	# load time.
	for node: Node in get_tree().get_nodes_in_group(DecorationBatch.CHANNEL_GROUP_PREFIX + channel):
		if node is DecorationBatch:
			node.apply_channel_color(channel, color)


func remove_objects_from_group(hsv_watchers: Array[HSVWatcher]) -> void:
	for hsv_watcher: HSVWatcher in hsv_watchers:
		hsv_watcher.remove_from_group(data.associated_group)


func reset_objects_color() -> void:
	# The native snapshot is only valid for the members it was configured with;
	# dropping it also drops the editor/reset paths onto the portable loop.
	_native_index = null
	_native_member_count = -1
	_native_watcher_version = -1
	var hsv_watchers: Array[HSVWatcher]
	hsv_watchers.assign(get_tree().get_nodes_in_group(data.associated_group))
	refresh_objects_color(hsv_watchers, DEFAULT_DATA)
	remove_objects_from_group(hsv_watchers)
