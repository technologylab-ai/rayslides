# Deterministic Studio Library visual-QA fixture.

@fontsize=32
@color=#eaf2fbff

@push stat_card x=110 y=130 w=620 h=210 fontsize=46 color=#081522ff bg=#61dafbff text=Reusable item · 42% clearer

@pushgroup feature_panel
@box id=panel x=170 y=170 w=1560 h=650 bg=#132a40ff
@box id=kicker x=250 y=245 w=520 h=42 fontsize=24 color=#61dafbff text=REUSABLE GROUP
@box id=title x=245 y=330 w=1180 h=120 fontsize=72 color=#ffffffff text=One composed idea
@box id=body x=250 y=505 w=1140 h=180 fontsize=34 color=#abc3d8ff text=Multiple authored objects remain editable together.
@box id=accent x=1480 y=245 w=120 h=360 bg=#ffb547ff
@endgroup

@bg color=#07111fff
@box id=eyebrow x=120 y=145 w=900 h=44 fontsize=24 color=#61dafbff text=SLIDE TEMPLATE
@box id=title x=112 y=260 w=1500 h=220 fontsize=96 color=#ffffffff text=Reusable structure
@box id=subtitle x=120 y=570 w=1300 h=110 fontsize=38 color=#a9bdd0ff text=Preview the whole composition before creating a slide.
@box id=rule x=120 y=795 w=1680 h=10 bg=#ffb547ff
@pushslide chapter_template

@slide transition=fade duration=0.35
@bg color=#081522ff
@box id=deck_title x=120 y=85 w=1520 h=90 fontsize=58 color=#ffffffff text=Library visual QA
@box id=deck_subtitle x=120 y=190 w=1520 h=56 fontsize=28 color=#8da9c0ff text=Select a card to preview it; choose Edit or double-click for Definition mode.
@pop stat_card id=stat x=120 y=330
@popgroup feature_panel id=feature
