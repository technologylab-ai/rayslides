# Documentation fixture for the motion guide.

@font=./assets/Calibri Light.ttf
@font_bold=./assets/Calibri Bold.TTF
@font_italic=./assets/Calibri Italic.ttf
@font_bold_italic=./assets/Calibri Bold Italic.ttf
@fontsize=32
@color=#dbe8f5ff

@slide transition=fade duration=0.35
@bg color=#07111fff

@box id=eyebrow x=120 y=95 w=920 h=42 fontsize=24 color=#61dafbff text=ONE LOGICAL SLIDE  /  THREE SEMANTIC STATES
@box id=title x=112 y=176 w=1080 h=130 fontsize=86 color=#f7fbffff text=Describe the destination.
@box id=body x=120 y=350 w=760 h=150 fontsize=34 color=#a9bdd0ff line_height=1.15
Give each object an ID.
Then change only what must move.
@box id=art_frame x=1080 y=150 w=700 h=700 bg=#0d2033ff
@box id=art img=assets/studio-light-sculpture.png x=1104 y=174 w=652 h=652
@box id=prompt x=120 y=790 w=760 h=60 fontsize=24 color=#ffb547ff text=The timeline below shows the resolved states.

@state(morph) label=TAKEOVER after=0.2 duration=0.8 ease=spring
@set art x=0 y=0 w=1920 h=1080
@set art_frame x=0 y=0 w=1920 h=1080 bg=#07111fff
@set title x=90 y=58 w=1720 fontsize=72 color=#ffb547ff shadow=#000000d0 shadow_offset=7
@hide eyebrow x=-1200
@hide body x=-1200
@hide prompt y=1180
@box id=takeover_panel x=70 y=845 w=1780 h=155 bg=#07111fe0
@box id=takeover_copy x=120 y=885 w=1680 h=70 fontsize=30 color=#f7fbffff text=One @set line expands the same image. Rayslides draws the path.

@state(morph) label=EXPLAIN after=0.2 duration=0.7 ease=smooth
@set art x=1420 y=735 w=380 h=214 opacity=0.25
@set art_frame x=1388 y=703 w=444 h=278 bg=#0d2033ff
@set title x=112 y=95 w=1500 fontsize=66 color=#f7fbffff shadow=none text=Three steps are enough.
@hide takeover_panel y=1180
@hide takeover_copy y=1180
@box id=card_one x=120 y=300 w=500 h=300 bg=#10253aff
@box id=card_two x=710 y=300 w=500 h=300 bg=#17243bff
@box id=card_three x=1300 y=300 w=500 h=300 bg=#20233bff
@box id=step_one x=170 y=350 w=400 h=170 fontsize=34 color=#61dafbff text=1  Name the object
@box id=step_two x=760 y=350 w=400 h=170 fontsize=34 color=#ffb547ff text=2  Add a state
@box id=step_three x=1350 y=350 w=400 h=170 fontsize=34 color=#d58cffFF text=3  Set new values
@box id=carry x=120 y=675 w=1120 h=70 fontsize=29 color=#a9bdd0ff text=Values that you do not set carry forward.

@state(morph) label=FLOW after=0.2 duration=0.9 ease=spring
@set title text=The same objects form the next view.
@hide art x=2050
@hide art_frame x=2050
@set card_one x=90 y=390 w=500 h=220
@set card_two x=710 y=390 w=500 h=220
@set card_three x=1330 y=390 w=500 h=220
@set step_one x=140 y=455 w=400 h=100 fontsize=30 color=#f7fbffff
@set step_two x=760 y=455 w=400 h=100 fontsize=30 color=#f7fbffff
@set step_three x=1380 y=455 w=400 h=100 fontsize=30 color=#f7fbffff
@set carry x=440 y=740 w=1040 fontsize=32 color=#ffb547ff text=IDs connect the states. Rayslides supplies the frames.
@box id=arrow_one x=610 y=445 w=80 h=100 fontsize=72 color=#ffb547ff text=→
@box id=arrow_two x=1230 y=445 w=80 h=100 fontsize=72 color=#ffb547ff text=→
