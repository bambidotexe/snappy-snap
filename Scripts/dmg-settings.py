# The disk image's window: what it holds, where each icon sits, what is behind them. Read by `dmgbuild`,
# which writes the layout into the image's own .DS_Store — no Finder, no AppleScript, no Automation grant,
# and the same image whoever builds it.
#
# The caller passes `app`, `name`, `background` and optionally `volume_icon` with -D. The icon centres here
# and the ones in `Scripts/dmg-background.swift` are the same two points; change them together or the arrow
# painted on the backdrop stops meeting the icons.

import os.path

application = defines["app"]
app_name = os.path.basename(application)

# What lands on the image: the app itself, and the folder it is meant to be dragged to.
files = [application]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
# Left to dmgbuild: it sizes the image from what it holds.
size = None

# An icon view, with everything Finder would otherwise put around it taken away.
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128

# 660 × 480 at (200, 200): the canvas `dmg-background.swift` draws. Finder shows the backdrop at natural size
# from the top-left of the icon view and its chrome eats the bottom of it, so the backdrop keeps everything
# in the top 340 pt and the icons sit where their labels still end above that line.
window_rect = ((200, 200), (660, 480))
icon_locations = {app_name: (175, 244), "Applications": (485, 244)}

background = defines["background"]

if defines.get("volume_icon"):
    icon = defines["volume_icon"]
