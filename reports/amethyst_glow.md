# Amethyst glow analysis (level data)

```text
Traceback (most recent call last):
  File "/home/runner/work/Godot-Dash/Godot-Dash/tools/analyze_amethyst_glow.py", line 127, in <module>
    main()
  File "/home/runner/work/Godot-Dash/Godot-Dash/tools/analyze_amethyst_glow.py", line 30, in main
    level = fetch_level_string()
            ^^^^^^^^^^^^^^^^^^^^
  File "/home/runner/work/Godot-Dash/Godot-Dash/tools/validate_amethyst.py", line 173, in fetch_level_string
    raise RuntimeError("could not download the level:\n  " + "\n  ".join(errors))
RuntimeError: could not download the level:
  gdhistory download: HTTPError: HTTP Error 403: Forbidden
  boomlings download: HTTPError: HTTP Error 403: Forbidden
  gdbrowser download: HTTPError: HTTP Error 500: Internal Server Error
  snapshot download: FileNotFoundError: no level snapshot committed
```
