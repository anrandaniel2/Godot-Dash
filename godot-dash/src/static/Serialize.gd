@abstract
class_name Serialize
## Serialization functions for builtin types.

@abstract class Reason:
	static var SAVE: Save = Save.new()
	static var PRACTICE: Practice = Practice.new()


	@abstract func is_saved_to_file() -> bool


	class Save:
		extends Reason
		func is_saved_to_file() -> bool:
			return true


	class Practice:
		extends Reason
		func is_saved_to_file() -> bool:
			return false


## Serialize a [Transform2D].
## [codeblock]
## {
## 	"x": [
## 		transform.x.x,
## 		transform.x.y
## 	],
## 	"y": [
## 		transform.y.x,
## 		transform.y.y
## 	],
## 	"origin": [
## 		transform.origin.x,
## 		transform.origin.y
## 	]
## }
## [/codeblock]
static func Transform2D(transform: Transform2D) -> Dictionary:
	return {
		"x": Serialize.Vector2(transform.x),
		"y": Serialize.Vector2(transform.y),
		"origin": Serialize.Vector2(transform.origin),
	}


## Serialize a [Vector2].
## [codeblock]
## [
## 	vector.x,
## 	vector.y
## ]
## [/codeblock]
static func Vector2(vector2: Vector2) -> Array:
	return [
		vector2.x,
		vector2.y,
	]


static func Node(node: Node) -> NodePath:
	return LevelManager.current_level.get_path_to(node)
