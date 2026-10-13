class_name NativeDownloadPolicy
extends RefCounted
## Windows may receive ISP/CDN blocks while the same public download succeeds
## through the Web relay. Retry once, only for public endpoints that it serves.

const HOSTS: Array[String] = [
	"www.boomlings.com",
	"boomlings.com",
	"history.geometrydash.eu",
	"geometrydashcontent.b-cdn.net",
	"geometrydashfiles.b-cdn.net",
	"www.newgrounds.com",
	"newgrounds.com",
	"audio.ngfiles.com",
	"cvolton.eu",
	"www.cvolton.eu",
]


static func should_retry(
	url: String, relay: String, is_windows: bool, response: Dictionary, fields: Dictionary = {}
) -> bool:
	if not is_windows or not relay.begins_with("https://") or not url.begins_with("https://"):
		return false
	var host: String = url.trim_prefix("https://").get_slice("/", 0).to_lower().trim_suffix(":443")
	if not HOSTS.has(host):
		return false
	# This is a read-only public-level client. Never relay account credentials
	# if a future caller accidentally reuses its transport for authentication.
	for key: String in ["gjp", "gjp2", "password", "token", "session"]:
		if not str(fields.get(key, "")).is_empty():
			return false
	for key: String in ["accountID", "userID"]:
		if str(fields.get(key, "0")) not in ["", "0"]:
			return false
	if not bool(response.get("ok", false)):
		return (
			bool(response.get("retryable", false)) or int(response.get("status", 0)) in [401, 403]
		)
	if not response.has("text"):
		return false
	var text: String = str(response.get("text", "")).strip_edges().to_lower()
	return (
		text in ["", "-1", "-2"] or text.begins_with("<!doctype html") or text.begins_with("<html")
	)
