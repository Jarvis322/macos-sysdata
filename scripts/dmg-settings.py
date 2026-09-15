# dmgbuild settings for the release disk image; scripts/make-dmg.sh passes the
# paths in with -D. Positions are icon centres in points from the window's
# top-left and must match scripts/make-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821 - provided by dmgbuild
legacy = defines["legacy"]  # noqa: F821
app_name = os.path.basename(app)

format = "ULFO"
files = [app, (legacy, "SysDataMenu.app")]
symlinks = {"Applications": "/Applications"}
# The Finder invisible flag. ditto does not carry `chflags hidden` into the
# image, and this flag is one URLResourceValues.isHidden reports and
# Updater.unhide clears.
hide = ["SysDataMenu.app"]
icon = defines["volume_icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (160, 180),
    "Applications": (480, 180),
    # Hidden, and outside the window as well, so a Finder set to show hidden
    # files does not put it between the two icons that matter.
    "SysDataMenu.app": (800, 180),
}
