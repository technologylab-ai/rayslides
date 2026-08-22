# Rayslides Studio capabilities showcase
# A source-native deck for README, documentation, and deterministic Studio captures.

@font=./assets/Calibri Light.ttf
@font_bold=./assets/Calibri Bold.TTF
@font_italic=./assets/Calibri Italic.ttf
@font_bold_italic=./assets/Calibri Bold Italic.ttf
@fontsize=32
@color=#dbe8f5ff

# The Library should tell the same story as the canvas.
@push capability_pill w=270 h=64 radius=32 fontsize=22 align=center valign=middle color=#f7fbffff bg=#172d43ff text=SOURCE-NATIVE

@pushgroup feature_panel
@box id=panel x=230 y=270 w=1460 h=540 radius=56 color=#10283cff
@box id=kicker x=300 y=330 w=520 h=42 fontsize=23 color=#61dafbff text=REUSABLE GROUP
@box id=title x=294 y=410 w=1120 h=110 fontsize=70 color=#f7fbffff text=One composed capability
@box id=body x=300 y=548 w=1060 h=126 fontsize=33 color=#a9bdd0ff text=Every member stays selectable, editable, reusable, and readable in source.
@box id=accent x=1465 y=330 w=132 h=340 radius=48 color=#ffb547ff
@endgroup

@bg color=#07111fff
@box id=template_kicker x=120 y=100 w=900 h=42 fontsize=24 color=#61dafbff text=REUSABLE SLIDE TEMPLATE
@box id=template_title x=112 y=210 w=1560 h=154 fontsize=96 color=#f7fbffff text=Structure without lock-in.
@box id=template_rule x=120 y=748 w=1680 h=10 color=#ffb547ff
@pushslide studio_chapter transition=fade duration=0.4

@slide transition=fade duration=0.45
@bg color=#07111fff
@box id=eyebrow x=112 y=76 w=1050 h=40 fontsize=22 color=#61dafbff text=RAYSLIDES STUDIO  ·  THE SOURCE IS THE PROJECT
@box id=headline x=104 y=158 w=1040 h=144 fontsize=96 color=#f8fbffff text=**Design the talk.**
@box id=headline_accent x=104 y=286 w=1040 h=144 fontsize=96 color=#ffb547ff text=**Own every detail.**
@box id=story x=112 y=462 w=1000 h=170 fontsize=34 color=#a9bdd0ff text=Visual authoring, crisp presentation pixels, and readable .sld source stay in one loop.
@line id=flow_one x=382 y=696 w=42 h=0 stroke_width=7 direction=down arrow=end color=#61dafbff
@line id=flow_two x=694 y=696 w=42 h=0 stroke_width=7 direction=down arrow=end color=#ffb547ff
@pop capability_pill id=source_pill x=112 y=664 w=270 text=SOURCE
@pop capability_pill id=studio_pill x=424 y=664 w=270 bg=#24455fff text=STUDIO
@pop capability_pill id=showtime_pill x=736 y=664 w=310 bg=#6b4c1fff color=#fff0d5ff text=SHOWTIME
@box id=art_frame x=1194 y=92 w=612 h=760 radius=54 color=#10283cff rotation=3
@box id=art_image img=assets/studio-light-sculpture.png x=1244 y=142 w=512 h=512 fit=contain rotation=3
@box id=art_caption x=1246 y=700 w=508 h=82 fontsize=26 align=center valign=middle color=#8fb0c8ff text=IMAGE · SVG · VIDEO · TYPE
@box id=footer x=112 y=944 w=1694 h=38 fontsize=21 color=#607f98ff text=Eight slides · reusable content · media · geometry · morphs · Presenter · Showtime

@state(morph) label=COMPOSE after=0.15 duration=0.7 ease=smooth
@set art_frame rotation=-3 radius=116 color=#173c51ff
@set art_image rotation=-3 x=1274 y=168 w=452 h=452
@set source_pill y=770
@set studio_pill y=770 bg=#2a5670ff
@set showtime_pill y=770 bg=#825e28ff
@set flow_one y=802
@set flow_two y=802

@state(morph) label=READY after=0.1 duration=0.65 ease=spring
@set headline fontsize=58 text=**Author with confidence.**
@set headline_accent fontsize=58 text=**Present without surprises.**
@set art_frame rotation=0 radius=54 color=#0e2940ff
@set art_image rotation=0 x=1244 y=142 w=512 h=512

@slide transition=slide-left duration=0.45
@bg color=#081321ff
@box id=type_title x=104 y=64 w=1710 h=72 fontsize=52 color=#f8fbffff text=**Typography that survives the room.**
@box id=type_subtitle x=110 y=146 w=1698 h=42 fontsize=23 color=#7896afff text=One signed-distance atlas is reconstructed cleanly from fine print to display type.
@box id=type_panel x=108 y=232 w=1010 h=706 radius=48 color=#10283cff
@box id=type_18 x=154 y=278 w=860 h=28 fontsize=18 color=#6f8ca5ff text=18 PX  ·  SMALL LABELS STAY LEGIBLE
@box id=type_24 x=154 y=330 w=860 h=38 fontsize=24 color=#89a4bcff text=24 PX  ·  CAPTIONS HOLD THEIR EDGES
@box id=type_34 x=154 y=394 w=860 h=48 fontsize=34 color=#b0c6d9ff text=34 px · calm body text
@box id=type_52 x=154 y=472 w=860 h=68 fontsize=52 color=#d6e5f3ff text=52 px · room-ready
@box id=type_76 x=150 y=574 w=880 h=102 fontsize=76 color=#61dafbff text=76 px · vivid
@box id=type_118 x=142 y=714 w=900 h=142 fontsize=118 color=#f8fbffff text=**118 px**
@box id=type_sample_panel x=1178 y=232 w=630 h=706 radius=48 color=#ffb547ff
@box id=type_sample x=1200 y=238 w=586 h=500 fontsize=286 align=center valign=middle color=#07111fff text=**Aa**
@box id=type_note x=1220 y=760 w=546 h=86 fontsize=28 align=center valign=middle color=#07111fff text=Curves · counters · diagonals
@box id=type_footer x=1220 y=858 w=546 h=34 fontsize=20 align=center color=#4a3515ff text=LEFT · CENTER · RIGHT / TOP · MIDDLE · BOTTOM

@slide transition=fade duration=0.4
@bg color=#07111fff
@box id=geometry_title x=104 y=64 w=1710 h=72 fontsize=52 color=#f8fbffff text=**Geometry with intent.**
@box id=geometry_subtitle x=110 y=146 w=1698 h=42 fontsize=23 color=#7896afff text=Rounded rectangles, true lines, arrowheads, exact rotation, painted hit testing, and smart guides.
@box id=geometry_center x=704 y=350 w=512 h=330 radius=74 color=#153a50ff
@box id=geometry_center_title x=754 y=402 w=412 h=122 fontsize=48 align=center valign=middle color=#f8fbffff text=**One model**
@box id=geometry_center_body x=764 y=542 w=392 h=72 fontsize=25 align=center valign=middle color=#8fb0c8ff text=source → Studio → renderer
@box id=geometry_left_top x=110 y=278 w=380 h=176 rotation=-8 radius=38 color=#244f68ff
@box id=geometry_left_top_label x=138 y=298 w=324 h=120 rotation=-8 fontsize=30 align=center valign=middle color=#eaf3ffff text=Rounded cards
@box id=geometry_right_top x=1430 y=278 w=380 h=176 rotation=8 radius=38 color=#6b365fff
@box id=geometry_right_top_label x=1458 y=298 w=324 h=120 rotation=8 fontsize=30 align=center valign=middle color=#ffe4f8ff text=Rotated objects
@box id=geometry_left_bottom x=110 y=744 w=380 h=176 rotation=7 radius=38 color=#684d24ff
@box id=geometry_left_bottom_label x=138 y=764 w=324 h=120 rotation=7 fontsize=30 align=center valign=middle color=#fff0d5ff text=Exact Properties
@box id=geometry_right_bottom x=1430 y=744 w=380 h=176 rotation=-7 radius=38 color=#24584fff
@box id=geometry_right_bottom_label x=1458 y=764 w=324 h=120 rotation=-7 fontsize=30 align=center valign=middle color=#e1fff8ff text=Morph-safe
@line id=geometry_arrow_one x=474 y=362 w=272 h=116 stroke_width=9 direction=down arrow=end color=#61dafbff
@line id=geometry_arrow_two x=1174 y=362 w=272 h=116 stroke_width=9 direction=up arrow=start color=#ff70caff
@line id=geometry_arrow_three x=474 y=606 w=272 h=184 stroke_width=9 direction=up arrow=end color=#ffb547ff
@line id=geometry_arrow_four x=1174 y=606 w=272 h=184 stroke_width=9 direction=down arrow=start color=#65e6c4ff

@slide transition=slide-left duration=0.45
@bg color=#07111fff
@box id=media_title x=104 y=64 w=1710 h=72 fontsize=52 color=#f8fbffff text=**Media without detours.**
@box id=media_subtitle x=110 y=146 w=1698 h=42 fontsize=23 color=#7896afff text=Pick, place, replace, fit, focus, reuse, morph, diagnose, export, and package images and video.
@box id=image_panel x=108 y=230 w=520 h=588 radius=46 color=#10283cff
@box id=svg_panel x=700 y=230 w=520 h=588 radius=46 color=#10283cff
@box id=video_panel x=1292 y=230 w=520 h=588 radius=46 color=#10283cff
@box id=media_image img=assets/studio-light-sculpture.png x=142 y=264 w=452 h=452 fit=contain rotation=-3
@box id=media_svg img=assets/studio-vector.svg x=734 y=264 w=452 h=452 fit=contain rotation=3
@box id=media_video vid=assets/big_buck_bunny_trailer.mp4 x=1326 y=264 w=452 h=452 fit=cover focus_y=0.66 poster=6.2 rotation=-3 loop muted
@box id=image_label x=142 y=742 w=452 h=42 fontsize=28 align=center color=#61dafbff text=RASTER IMAGE
@box id=svg_label x=734 y=742 w=452 h=42 fontsize=28 align=center color=#ffb547ff text=SVG VECTOR
@box id=video_label x=1326 y=742 w=452 h=42 fontsize=28 align=center color=#ff70caff text=VIDEO + POSTER + AUDIO
@box id=media_footer_panel x=334 y=890 w=1252 h=76 radius=38 color=#172d43ff
@box id=media_footer x=334 y=890 w=1252 h=76 fontsize=27 align=center valign=middle color=#d8e7f6ff text=The filename is visible. Replace is a separate, source-preserving action.

@slide transition=fade duration=0.4
@bg color=#081321ff
@box id=reuse_title x=104 y=64 w=1710 h=72 fontsize=52 color=#f8fbffff text=**Reuse without losing the source.**
@box id=reuse_subtitle x=110 y=146 w=1698 h=42 fontsize=23 color=#7896afff text=Items, groups, and slide templates remain normal .sld definitions with explicit local and shared ownership.
@popgroup feature_panel id=showcase_feature
@box id=reuse_local x=252 y=858 w=400 h=66 radius=33 color=#173b54ff
@box id=reuse_local_label x=252 y=858 w=400 h=66 fontsize=23 align=center valign=middle color=#eaf3ffff text=LOCAL · ONE USE
@box id=reuse_shared x=760 y=858 w=400 h=66 radius=33 color=#6b365fff
@box id=reuse_shared_label x=760 y=858 w=400 h=66 fontsize=23 align=center valign=middle color=#ffe4f8ff text=SHARED · EVERY USE
@box id=reuse_detach x=1268 y=858 w=400 h=66 radius=33 color=#684d24ff
@box id=reuse_detach_label x=1268 y=858 w=400 h=66 fontsize=23 align=center valign=middle color=#fff0d5ff text=DETACH · ORDINARY ITEMS

@slide transition=slide-left duration=0.45
@bg color=#07111fff
@box id=motion_title x=104 y=64 w=1710 h=72 fontsize=52 color=#f8fbffff text=**Motion describes meaning.**
@box id=motion_subtitle x=110 y=146 w=1698 h=42 fontsize=23 color=#7896afff text=Semantic states interpolate the same authored objects instead of replacing the slide with opaque frames.
@box id=motion_left x=180 y=328 w=420 h=330 radius=34 color=#173b54ff
@box id=motion_left_label x=224 y=395 w=332 h=150 fontsize=42 align=center valign=middle color=#eaf3ffff text=**Author**
@box id=motion_right x=1320 y=328 w=420 h=330 radius=34 color=#63375aff
@box id=motion_right_label x=1364 y=395 w=332 h=150 fontsize=42 align=center valign=middle color=#ffe7f9ff text=**Present**
@line id=motion_flow x=610 y=492 w=700 h=0 stroke_width=11 direction=down arrow=end color=#61dafbff
@box id=motion_flow_label x=750 y=390 w=420 h=64 fontsize=24 align=center valign=middle color=#8faec5ff text=the same render graph
@box id=motion_statement_panel x=590 y=820 w=740 h=82 radius=41 color=#12283bff
@box id=motion_statement x=590 y=820 w=740 h=82 fontsize=25 align=center valign=middle color=#c7d9e9ff text=Name the objects. Change only what moves.

@state(morph) label=SHAPE after=0.15 duration=0.85 ease=smooth
@set motion_left x=520 y=310 w=430 h=360 radius=104 rotation=8 color=#1d5a6fff
@set motion_left_label x=570 y=405 w=330 h=150 rotation=8 text=**Shape**
@set motion_right x=970 y=310 w=430 h=360 radius=104 rotation=-8 color=#7a425fff
@set motion_right_label x=1020 y=405 w=330 h=150 rotation=-8 text=**Meaning**
@set motion_flow x=860 y=736 w=200 h=0 rotation=-90 stroke_width=14 arrow=both color=#ffb547ff
@set motion_flow_label x=750 y=742 w=420 h=64 text=one source-native transition

@state(morph) label=FLOW after=0.1 duration=0.75 ease=spring
@set motion_left x=310 y=360 w=500 h=270 radius=64 rotation=0
@set motion_left_label x=365 y=422 w=390 h=120 rotation=0 text=**Edit visually**
@set motion_right x=1110 y=360 w=500 h=270 radius=64 rotation=0
@set motion_right_label x=1165 y=422 w=390 h=120 rotation=0 text=**Diff as text**
@set motion_flow x=830 y=494 w=260 h=0 rotation=0 arrow=both color=#65e6c4ff
@set motion_flow_label x=750 y=690 w=420 h=64 text=two views · one deck

@slide transition=fade duration=0.4
@bg color=#07111fff
@box id=showtime_title x=104 y=64 w=1710 h=72 fontsize=52 color=#f8fbffff text=**Know before you walk on stage.**
@box id=showtime_subtitle x=110 y=146 w=1698 h=42 fontsize=23 color=#7896afff text=Showtime exercises the exact deck, assets, media runtime, display, and local services without mutating playback.
@box id=showtime_status_panel x=112 y=252 w=600 h=594 radius=52 color=#10283cff
@box id=showtime_status x=164 y=306 w=496 h=92 fontsize=64 align=center valign=middle color=#65e6c4ff text=**READY**
@box id=showtime_status_copy x=164 y=426 w=496 h=214 fontsize=30 align=center valign=middle color=#d8e7f6ff
8 slides
12 scenes
4 assets
0 blockers
@box id=showtime_ci x=174 y=710 w=476 h=74 radius=37 color=#173b54ff
@box id=showtime_ci_label x=174 y=710 w=476 h=74 fontsize=25 align=center valign=middle color=#eaf3ffff text=CI JSON REPORT
@box id=showtime_checks_panel x=786 y=252 w=1022 h=594 radius=52 color=#0e2134ff
@box id=showtime_check_one x=850 y=314 w=850 h=68 radius=34 color=#163e43ff
@box id=showtime_check_one_label x=850 y=314 w=850 h=68 fontsize=26 align=center valign=middle color=#dffff7ff text=OK · Parser and complete render graph
@box id=showtime_check_two x=850 y=408 w=850 h=68 radius=34 color=#163e43ff
@box id=showtime_check_two_label x=850 y=408 w=850 h=68 fontsize=26 align=center valign=middle color=#dffff7ff text=OK · Images, SVG, video, fonts, glyphs
@box id=showtime_check_three x=850 y=502 w=850 h=68 radius=34 color=#163e43ff
@box id=showtime_check_three_label x=850 y=502 w=850 h=68 fontsize=26 align=center valign=middle color=#dffff7ff text=OK · Presenter, Crowdplay, and selected display
@box id=showtime_check_four x=850 y=596 w=850 h=68 radius=34 color=#163e43ff
@box id=showtime_check_four_label x=850 y=596 w=850 h=68 fontsize=26 align=center valign=middle color=#dffff7ff text=OK · Text bounds, IDs, definitions, export pixels
@box id=showtime_portable x=850 y=710 w=850 h=74 radius=37 color=#6b4c1fff
@box id=showtime_portable_label x=850 y=710 w=850 h=74 fontsize=25 align=center valign=middle color=#fff0d5ff text=CREATE + REOPEN + PREFLIGHT PORTABLE SHOW
@box id=showtime_footer x=112 y=922 w=1696 h=38 fontsize=22 align=center color=#7896afff text=One calm checklist · actionable source targets · no second project format

@slide transition=slide-left duration=0.45
@bg color=#07111fff
@box id=presenter_title x=104 y=64 w=1710 h=72 fontsize=52 color=#f8fbffff text=**A private companion for the room.**
@box id=presenter_subtitle x=110 y=146 w=1698 h=42 fontsize=23 color=#7896afff text=Notes, current and next previews, navigation, pointer, drawing, reconnect safety, and bounded latency evidence.
@box id=phone_shell x=182 y=246 w=490 h=686 radius=76 color=#10283cff
@box id=phone_screen x=218 y=286 w=418 h=602 radius=48 color=#07111fff
@box id=phone_status x=258 y=326 w=338 h=46 fontsize=21 align=center color=#65e6c4ff text=CONNECTED  ·  18:42
@box id=phone_notes x=258 y=408 w=338 h=180 fontsize=29 align=center valign=middle color=#eaf3ffff text=Your private notes stay on your device.
@box id=phone_nav_prev x=258 y=764 w=148 h=74 radius=37 color=#172d43ff
@box id=phone_nav_prev_label x=258 y=764 w=148 h=74 fontsize=24 align=center valign=middle color=#eaf3ffff text=← PREV
@box id=phone_nav_next x=448 y=764 w=148 h=74 radius=37 color=#61dafbff
@box id=phone_nav_next_label x=448 y=764 w=148 h=74 fontsize=24 align=center valign=middle color=#07111fff text=NEXT →
@box id=presenter_features x=802 y=246 w=1006 h=686 radius=56 color=#0e2134ff
@box id=presenter_feature_title x=876 y=306 w=860 h=68 fontsize=40 color=#f8fbffff text=**Venue resilience is part of presenting.**
@box id=presenter_feature_one x=878 y=430 w=820 h=62 fontsize=27 color=#61dafbff text=01  Discover and explain usable local addresses
@box id=presenter_feature_two x=878 y=522 w=820 h=62 fontsize=27 color=#ffb547ff text=02  Rotate private capabilities when networks change
@box id=presenter_feature_three x=878 y=614 w=820 h=62 fontsize=27 color=#65e6c4ff text=03  Recover safely after suspend, wake, and reconnect
@box id=presenter_feature_four x=878 y=706 w=820 h=62 fontsize=27 color=#ff70caff text=04  Use the same responsive client on a laptop
@box id=presenter_footer x=878 y=814 w=820 h=48 fontsize=22 color=#7896afff text=No cloud account · no notes in the public URL · local control remains available
