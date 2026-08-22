@slide bg=#0d1322ff
@box id=title x=120 y=90 w=1500 h=90 fontsize=54 color=#f6f8ffff text=Rounded rectangles
@box id=sharp x=120 y=280 w=480 h=360 radius=0 color=#405a7aff
@box id=soft x=720 y=280 w=480 h=360 radius=44 color=#2f9c95ff
@box id=pill x=1320 y=360 w=420 h=200 radius=100 color=#ffb547ff
@box id=caption x=120 y=720 w=1620 h=120 fontsize=34 color=#a9bdd0ff align=center valign=middle text=radius=0 · radius=44 · radius=100
@state(morph) duration=0.8
@set sharp radius=80
@set soft radius=180
@set pill radius=16
