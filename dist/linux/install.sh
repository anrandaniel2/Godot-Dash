#!/bin/bash
cd "$(dirname "$0")" || exit
mkdir -p "$HOME/.local/share/mime/application"
cp x-godot-dash.xml "$HOME/.local/share/mime/packages"
update-mime-database "$HOME/.local/share/mime"

mkdir -p "$HOME/.local/share/icons/hicolor/512x512/apps"
cp logo "$HOME/.local/share/icons/hicolor/512x512/apps/godot-dash.png"

mkdir -p "$HOME/.local/share/icons/hicolor/512x512/mimetypes"
cp logo "$HOME/.local/share/icons/hicolor/512x512/mimetypes/application-x-godot-dash-level.png"

mkdir -p "$HOME/.local/share/applications"
cp godot-dash.desktop "$HOME/.local/share/applications"
update-desktop-database "$HOME/.local/share/applications"
if [[ $# == 1 ]]; then
  game_path=$1
else
  read -rp "Enter your Godot Dash binary path: " game_path
fi
desktop-file-edit "$HOME/.local/share/applications/godot-dash.desktop" --set-key=Exec --set-value="${game_path//\~/$HOME} -- %u"
