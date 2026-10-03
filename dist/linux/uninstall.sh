#!/bin/bash
rm "$HOME/.local/share/mime/packages/x-godot-dash.xml"
rm "$HOME/.local/share/icons/hicolor/512x512/apps/godot-dash.png"
rm "$HOME/.local/share/icons/hicolor/512x512/mimetypes/application-x-godot-dash-level.png"
update-mime-database "$HOME/.local/share/mime"
rm "$HOME/.local/share/applications/godot-dash.desktop"
update-desktop-database "$HOME/.local/share/applications"
