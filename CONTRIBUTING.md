# Contribution guidelines

## Pull Requests

Give descriptive names to PR branches, e.g. `spawn-trigger-crash-fix` instead of `fix`.
This also goes for PR names.
Group PRs by topic, e.g. a single feature or a fix.

## Scripts

Format your GDScript code with [GDQuest's GDScript formatter](https://www.gdquest.com/library/gdscript_formatter/).
You can install it as an extension for Godot's text editor, VSCode, Zed, Helix, JetBrains Rider and [Neovim](https://github.com/GDQuest/GDScript-formatter/issues/26#issuecomment-3332838502).

### Style guide

Follow [Godot's GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html).
Unfortunately, Godot doesn't come with a formatter or a linter, so if you see code that isn't formatted correctly, feel free to open a PR.

**Make variable types explicit everywhere in your code.** If a variable's type needs to change (which should never happen except rare cases), set its type to `Variant`.

Give classes names (`class_name`) so you can refer to instances of that class in other parts of the code.

#### Node paths

Avoid node paths that go up in the hierarchy, e.g. `^"../../Node"` (the worst offender is a "grandparent" path like `^"../.."` which doesn't tell anything about what the referred node actually is).
Instead, use references stored in exported variables, e.g. `@export var side_panel: PanelContainer`.
If the script is only meant to be instantiated from code, use a public variable and initialize it in `_init`, e.g.

```gdscript
# from AddKeybindButton.gd
var keybind_loader: KeybindLoader


func _init(_keybind_loader: KeybindLoader) -> void:
	keybind_loader = _keybind_loader
```

If the class is only there to categorize subclasses, [mark it as `@abstract`](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html#abstract-classes-and-methods).

Connect signals from code using `signal.connect(function)` (`Signal.connect()`) instead of `connect("signal", function)` (`Node.connect()`).

#### Strings

Use [format strings](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_format_string.html) instead of concatenation (for readability), e.g.

<table><thead>
  <tr>
    <th>Good</th>
    <th>Bad</th>
  </tr></thead>
<tbody>
  <tr>
    <td>
    <pre><code>object_name.text = "%s objects" % selection.size()</code></pre>
    </td>
    <td>
    <pre><code>object_name.text = str(selection.size()) + " objects"</code></pre>
    </td>
  </tr>
</tbody>
</table>

### Commented-out code

Don't include code that's commented out in PRs.

### File naming conventions

Name folders in `snake_case` and files and scripts in `PascalCase`.

## New game settings

If your PR adds new settings to the game, ensure the following:

1. The setting is in the same order in the settings menu and in Config. **Don't forget to add saving and loading in `Config.save` and `Config._init` for your new setting.**
2. If the setting is a boolean, avoid inverted names like "Disabled". Prefer "Enabled" and setting the default to `true`.
3. If the setting is an enum, make the corresponding variable in Config an enum too. Create the enum in Config if it doesn't exist.
4. If you need to create an enum in Config, the "Disabled" variant should be the first, and the variants should go from "lowest" to "highest".
4. If there are multiple related boolean settings, consider grouping them into a bit flag.
5. If a setting requires an intermediate variable (e.g. `touch_screen_mode` and `is_touchscreen`), make the intermediate variable an `@export_storage` so it's clear that it *isn't* meant to be modified in the settings menu. If the intermediate variable is a boolean, start its name with `is_`
