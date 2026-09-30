# The app's asset catalog: its icon (light, dark and tinted, as iOS 18 draws Home Screen icons), the launch screen's island
# and colours. Drawn as the Android and web apps' icons are.
import json, os, sys
from PIL import Image, ImageDraw, ImageOps
here = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, here)
from art_base import background, island, icon  # noqa: E402

root = os.path.dirname(here)
cat = os.path.join(root, 'App', 'Assets.xcassets')
def put(path, obj): os.makedirs(os.path.dirname(path), exist_ok=True); json.dump(obj, open(path, 'w'), indent=2)
put(os.path.join(cat, 'Contents.json'), {'info': {'author': 'xcode', 'version': 1}})

# The icon: light (night glass), dark (the island on black), tinted (grey, iOS tints it).
ic = os.path.join(cat, 'AppIcon.appiconset'); os.makedirs(ic, exist_ok=True)
icon(1024, 1.34).convert('RGB').save(os.path.join(ic, 'icon.png'), optimize=True)
dark = Image.new('RGBA', (1024, 1024), (0, 0, 0, 255)); dark.alpha_composite(island(1024, 1.34)); dark.convert('RGB').save(os.path.join(ic, 'icon-dark.png'), optimize=True)
tint = ImageOps.grayscale(island(1024, 1.34).convert('RGBA')); bg = Image.new('L', (1024, 1024), 0)
bg.paste(tint, (0, 0), island(1024, 1.34).split()[3]); Image.merge('RGB', (bg, bg, bg)).save(os.path.join(ic, 'icon-tinted.png'), optimize=True)
put(os.path.join(ic, 'Contents.json'), {
    'images': [
        {'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
        {'appearances': [{'appearance': 'luminosity', 'value': 'dark'}], 'filename': 'icon-dark.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
        {'appearances': [{'appearance': 'luminosity', 'value': 'tinted'}], 'filename': 'icon-tinted.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
    ], 'info': {'author': 'xcode', 'version': 1}})

def color(name, hexv, dark_hex=None):
    def comp(h): return {'color-space': 'srgb', 'components': {'red': '0x' + h[0:2], 'green': '0x' + h[2:4], 'blue': '0x' + h[4:6], 'alpha': '1.000'}}
    colors = [{'idiom': 'universal', 'color': comp(hexv)}]
    if dark_hex: colors.append({'idiom': 'universal', 'appearances': [{'appearance': 'luminosity', 'value': 'dark'}], 'color': comp(dark_hex)})
    put(os.path.join(cat, name + '.colorset', 'Contents.json'), {'colors': colors, 'info': {'author': 'xcode', 'version': 1}})
color('AccentColor', '5E8C7B', 'A5D8C5')
color('LaunchBackground', '070B14')

# The launch screen's island, centred on the night background.
li = os.path.join(cat, 'LaunchIsland.imageset'); os.makedirs(li, exist_ok=True)
for scale in (2, 3):
    side = 260 * scale
    island(side, 1.0).crop((0, int(side * .3), side, int(side * .7))).save(os.path.join(li, f'island@{scale}x.png'), optimize=True)
put(os.path.join(li, 'Contents.json'), {'images': [{'idiom': 'universal', 'scale': '1x'}, {'filename': 'island@2x.png', 'idiom': 'universal', 'scale': '2x'}, {'filename': 'island@3x.png', 'idiom': 'universal', 'scale': '3x'}], 'info': {'author': 'xcode', 'version': 1}})

# The widgets share the accent.
wc = os.path.join(root, 'Widgets', 'Assets.xcassets'); put(os.path.join(wc, 'Contents.json'), {'info': {'author': 'xcode', 'version': 1}})
cat = wc; color('AccentColor', '5E8C7B', 'A5D8C5'); color('WidgetBackground', 'F3F5F9', '0B1220')
print('ok')
