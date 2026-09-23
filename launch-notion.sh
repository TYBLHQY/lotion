#!/usr/bin/env sh
set -eu

# Avoid loading the GTK3 Fcitx module in Electron while keeping the normal
# desktop configuration, default browser association, and system theme.
NOTION_USER_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME:?HOME must be set}/.config}"
NOTION_USER_CONFIG_HOME="${NOTION_USER_CONFIG_HOME%/}"
export GTK_IM_MODULE=xim
export GSETTINGS_BACKEND=memory
export GIO_USE_PORTALS=0
export GTK_USE_PORTAL=0

exec /opt/Notion/notion \
  --user-data-dir="$NOTION_USER_CONFIG_HOME/Notion" \
  "$@"
