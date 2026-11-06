"""Finder layout for Voiz's drag-to-Applications disk image (dmgbuild)."""
import os
import plistlib

application = defines['app']
appname = os.path.basename(application)
with open(os.path.join(application, 'Contents/Info.plist'), 'rb') as stream:
    info = plistlib.load(stream)
icon_name = info['CFBundleIconFile']
if not icon_name.endswith('.icns'):
    icon_name += '.icns'
icon = os.path.join(application, 'Contents/Resources', icon_name)
files = [application]
symlinks = {'Applications': '/Applications'}
format = 'UDZO'
filesystem = 'HFS+'
background = 'builtin-arrow'
window_rect = ((180, 160), (640, 280))
icon_locations = {appname: (140, 120), 'Applications': (500, 120)}
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 100
text_size = 14
label_pos = 'bottom'
