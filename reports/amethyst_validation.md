# Amethyst mapping validation

## Download failed

```
Traceback (most recent call last):
  File "/home/runner/work/Godot-Dash/Godot-Dash/tools/validate_amethyst.py", line 199, in main
    level = fetch_level_string()
            ^^^^^^^^^^^^^^^^^^^^
  File "/home/runner/work/Godot-Dash/Godot-Dash/tools/validate_amethyst.py", line 160, in fetch_level_string
    raise RuntimeError("could not download the level:\n  " + "\n  ".join(errors))
RuntimeError: could not download the level:
  gdhistory download: HTTPError: HTTP Error 403: Forbidden
  boomlings download: HTTPError: HTTP Error 403: Forbidden
  gdbrowser download: HTTPError: HTTP Error 500: Internal Server Error
```
