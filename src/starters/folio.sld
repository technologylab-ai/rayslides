# Folio starter · created in Rayslides Studio
# A light editorial system with an asymmetric publishing grid.
@fontsize=36
@color=#17213aff

@pushgroup folio_footer
@line id=rule x=110 y=984 w=1700 h=0 stroke_width=3 color=#17213aff
@box id=label x=112 y=1006 w=820 h=28 fontsize=17 color=#626762ff text=FIELD NOTES / WORKING EDITION
@endgroup

@bg color=#f7f3eaff
@box id=spine x=0 y=0 w=34 h=1080 color=#2352d6ff
@box id=issue x=112 y=82 w=420 h=38 fontsize=20 color=#b63a2dff text=ISSUE 01 · A POINT OF VIEW
@box id=title x=104 y=188 w=1130 h=300 fontsize=108 color=#17213aff line_height=0.96
@box id=subtitle x=112 y=560 w=1010 h=136 fontsize=34 color=#59616aff line_height=1.3
@box id=edition_panel x=1370 y=112 w=378 h=690 radius=26 color=#2352d6ff
@box id=edition_number x=1414 y=154 w=290 h=240 fontsize=178 align=center valign=middle color=#f7f3eaff text=**01**
@box id=edition_rule x=1422 y=438 w=272 h=5 color=#93b4ffff
@box id=edition_copy x=1424 y=492 w=268 h=160 fontsize=27 color=#f7f3eaff line_height=1.25 text=OBSERVE
CONNECT
PUBLISH
@box id=edition_accent x=1266 y=734 w=246 h=92 radius=18 color=#ef654bff rotation=-7
@popgroup folio_footer id=footer
@box id=page x=1748 y=1006 w=60 h=28 fontsize=17 align=right color=#626762ff text=$slide_number
@pushslide folio_cover

@bg color=#f7f3eaff
@box id=spine x=0 y=0 w=34 h=1080 color=#2352d6ff
@box id=section x=112 y=78 w=520 h=38 fontsize=20 color=#b63a2dff text=FIELD NOTE / 02
@box id=title x=104 y=146 w=1510 h=104 fontsize=68 color=#17213aff
@box id=intro x=112 y=260 w=1420 h=76 fontsize=28 color=#656a70ff
@box id=number_one x=112 y=402 w=126 h=126 radius=63 fontsize=46 align=center valign=middle color=#f7f3eaff bg=#2352d6ff text=**01**
@box id=item_one x=276 y=398 w=1390 h=142 fontsize=34 color=#17213aff
@line id=item_one_rule x=276 y=550 w=1390 h=0 stroke_width=2 color=#c4beb3ff
@box id=number_two x=112 y=584 w=126 h=126 radius=63 fontsize=46 align=center valign=middle color=#17213aff bg=#d8e4ffff text=**02**
@box id=item_two x=276 y=580 w=1390 h=142 fontsize=34 color=#17213aff
@line id=item_two_rule x=276 y=732 w=1390 h=0 stroke_width=2 color=#c4beb3ff
@box id=number_three x=112 y=766 w=126 h=126 radius=63 fontsize=46 align=center valign=middle color=#17213aff bg=#ef654bff text=**03**
@box id=item_three x=276 y=762 w=1390 h=142 fontsize=34 color=#17213aff
@popgroup folio_footer id=footer
@box id=page x=1748 y=1006 w=60 h=28 fontsize=17 align=right color=#626762ff text=$slide_number
@pushslide folio_content

@popslide folio_cover transition=fade duration=0.4
@set title text=**A clear point**
**of view.**
@set subtitle text=An editorial canvas for research, arguments, and stories that deserve room to breathe.

@popslide folio_content transition=slide-left duration=0.4
@set title text=**Evidence, arranged with intent.**
@set intro text=Use a visible sequence so the audience always knows where the argument is going.
@set item_one text=**Frame the question**
Name the tension before you introduce the detail.
@set item_two text=**Show the evidence**
Let each fact earn its place in the story.
@set item_three text=**Land the implication**
Finish with the decision the room can make.
