# Signal starter · created in Rayslides Studio
# A bright graphic system with an acid frame and editorial punch.
@fontsize=36
@color=#101515ff

@pushgroup signal_footer
@box id=label x=112 y=1002 w=760 h=28 fontsize=18 color=#414943ff text=SIGNAL / MAKE IT LAND
@box id=page_panel x=1708 y=988 w=100 h=56 radius=28 color=#101515ff
@endgroup

@bg color=#e7f45cff
@box id=page x=64 y=64 w=1792 h=928 radius=30 color=#fffdf2ff
@box id=rail x=1398 y=64 w=458 h=928 radius=30 color=#3f46e8ff
@box id=eyebrow x=126 y=118 w=740 h=38 fontsize=21 color=#3f46e8ff text=LOUD, CLEAR, UNMISSABLE
@box id=title x=116 y=240 w=1150 h=318 fontsize=118 color=#101515ff line_height=0.88
@box id=subtitle x=126 y=642 w=1020 h=104 fontsize=31 color=#535b56ff line_height=1.28
@box id=pink_bar x=1230 y=164 w=330 h=96 radius=18 color=#ff4f9aff rotation=-8
@box id=rail_number x=1452 y=306 w=348 h=210 fontsize=158 align=center valign=middle color=#fffdf2ff text=**01**
@box id=rail_label x=1450 y=574 w=352 h=110 fontsize=26 align=center valign=middle color=#dfe1ffff text=START WITH
THE SIGNAL
@box id=rail_chip x=1488 y=786 w=274 h=72 radius=36 fontsize=20 align=center valign=middle color=#101515ff bg=#e7f45cff text=NO VISUAL SHRUGS
@popgroup signal_footer id=footer
@box id=page_number x=1730 y=1002 w=56 h=28 fontsize=18 align=center color=#fffdf2ff text=$slide_number
@pushslide signal_cover

@bg color=#e7f45cff
@box id=page x=64 y=64 w=1792 h=928 radius=30 color=#fffdf2ff
@box id=section x=126 y=116 w=580 h=38 fontsize=21 color=#3f46e8ff text=THE ONE-SLIDE TEST
@box id=title x=116 y=174 w=1540 h=100 fontsize=68 color=#101515ff
@box id=statement x=118 y=330 w=1030 h=420 radius=28 color=#3f46e8ff
@box id=statement_text x=180 y=396 w=906 h=270 fontsize=54 color=#fffdf2ff line_height=1.12
@box id=prompt x=1220 y=330 w=520 h=128 radius=24 color=#ff4f9aff rotation=3
@box id=prompt_text x=1254 y=354 w=452 h=72 fontsize=25 align=center valign=middle color=#101515ff rotation=3 text=WHAT SHOULD THEY
REMEMBER TOMORROW?
@box id=answer x=1220 y=520 w=520 h=230 radius=24 color=#101515ff
@box id=answer_label x=1260 y=556 w=440 h=40 fontsize=20 color=#e7f45cff text=THE ANSWER
@box id=answer_text x=1260 y=620 w=420 h=84 fontsize=31 color=#fffdf2ff
@box id=caption x=118 y=806 w=1490 h=42 fontsize=24 color=#535b56ff
@popgroup signal_footer id=footer
@box id=page_number x=1730 y=1002 w=56 h=28 fontsize=18 align=center color=#fffdf2ff text=$slide_number
@pushslide signal_content

@popslide signal_cover transition=fade duration=0.35
@set title text=**MAKE IT**
**LAND.**
@set subtitle text=A high-energy system for launches, manifestos, campaigns, and ideas that cannot fade into the background.

@popslide signal_content transition=slide-left duration=0.35
@set title text=**If they remember one thing…**
@set statement_text text=**Put the sharpest version of the idea right here.**
@set answer_text text=One sentence. No hedging.
@set caption text=Everything else on the slide should make that sentence easier to believe.
