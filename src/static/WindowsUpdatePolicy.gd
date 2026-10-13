class_name WindowsUpdatePolicy
extends RefCounted
## Accept only the installer for this build's branch-specific release channel.
## Replay/application version is deliberately independent of CI build numbers.


static func evaluate(release: Dictionary, channel: String, installed: int) -> Dictionary:
	if str(release.get("tag_name", "")) != channel or bool(release.get("draft", false)):
		return {"ok": false}
	var build: int = 0
	for line: String in str(release.get("body", "")).split("\n"):
		if line.begins_with("Build: "):
			var number: String = line.trim_prefix("Build: ").strip_edges()
			if number.is_valid_int():
				build = int(number)
	if build <= 0:
		return {"ok": false}
	var expected: String = (
		"https://github.com/anrandaniel2/Godot-Dash/releases/download/%s/GodotDashSetup-x86_64.exe"
		% channel
	)
	var assets: Variant = release.get("assets", [])
	if not assets is Array:
		return {"ok": false}
	for asset: Variant in assets:
		if asset is Dictionary and str(asset.get("browser_download_url", "")) == expected:
			if (
				str(asset.get("name", "")) == "GodotDashSetup-x86_64.exe"
				and int(asset.get("size", 0)) > 0
			):
				return {"ok": true, "url": expected, "newer": build > installed}
	return {"ok": false}
