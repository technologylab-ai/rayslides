@slide bg=#08111fff
@box id=title x=90 y=66 w=1500 h=92 fontsize=54 color=#eff8ffff text=Studio rotation
@box id=subtitle x=92 y=154 w=1500 h=46 fontsize=24 color=#8fa9c4ff text=Canvas handle · exact Properties · reusable + morph-safe
@box id=card x=180 y=300 w=520 h=280 rotation=-12 radius=42 color=#245f78ff
@box id=card-label x=245 y=380 w=390 h=90 rotation=-12 fontsize=34 align=center valign=middle color=#ffffffff text=Rotated shape
@line id=connector x=780 y=320 w=500 h=180 rotation=18 stroke_width=9 direction=down arrow=end color=#ff5cc6ff
@box id=image-frame x=1390 y=280 w=300 h=300 rotation=10 radius=26 color=#e6b95dff
@box id=caption x=170 y=720 w=1540 h=90 fontsize=28 align=center valign=middle color=#a9bdd0ff text=Select any object: drag the rotation handle above it; hold Shift for 15° snaps
@state(morph) duration=0.8
@set card rotation=16
@set card-label rotation=16
@set connector rotation=-20
@set image-frame rotation=-8
