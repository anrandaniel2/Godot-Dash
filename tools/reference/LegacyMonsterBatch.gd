extends DecorationBatch
## Frozen d15e8de scheduler, used only by parity/CPU tests.


func _advance_monsters(delta: float) -> void:
	for monster: Monster in monsters:
		var animation: Dictionary = MonsterAnimations.monster(monster.name).get("animations", {}).get(monster.animation, {})
		var delay: float = maxf(float(animation.get("delay", 0.05)), 0.001)
		var frame_count: int = animation.get("frames", []).size()
		if frame_count == 0:
			continue
		monster.elapsed += delta
		var advanced: bool = false
		while monster.elapsed >= delay:
			monster.elapsed -= delay
			advanced = true
			monster.frame += 1
			if monster.frame < frame_count:
				continue
			if bool(animation.get("loop", false)):
				monster.frame = 0
				continue
			var following: String = str(animation.get("next", ""))
			if following.is_empty():
				following = str(MonsterAnimations.monster(monster.name).get("default", ""))
			monster.animation = following
			monster.frame = 0
			animation = MonsterAnimations.monster(monster.name).get("animations", {}).get(following, {})
			delay = maxf(float(animation.get("delay", 0.05)), 0.001)
			frame_count = maxi(animation.get("frames", []).size(), 1)
		if advanced:
			_place_monster(monster)
