# #############################################################
# ##   T  E  M  P  L  A  T  E  S
# #############################################################

# -- global setup
@fontsize=36
@font=./assets/fonts/GeorgiaPro-Light.ttf
@font_bold=./assets/fonts/GeorgiaPro-Bold.ttf
@font_italic=./assets/fonts/GeorgiaPro-Italic.ttf
@font_bold_italic=./assets/fonts/GeorgiaPro-BoldItalic.ttf
@underline_width=2
@color=#000000ff
@bullet_color=#cd0f2dff
# Override bullet symbol default of > with the bullet point
@bullet_symbol=•
@line_height=1.1

@let ZIGCOLOR = #F7A41DFF

# -------------------------------------------------------------
# -- definitions for later
# -------------------------------------------------------------

@push slide_title  x=110  y=71   w=1712 h=73  fontsize=52 color=#000000ff

@push slide_number x=1803 y=1027 w=40   h=40  fontsize=20 color=#404040ff text=$slide_number

@push sources_info x=110  y=960  w=1758 h=129 fontsize=20 color=#bfbfbfff text=Sources:

@push bigbox       x=110  y=181  w=1700 h=971 fontsize=45 color=#000000ff
@push leftbox      x=110  y=181  w=850  h=861 fontsize=45 color=#000000ff
@push rightbox     x=1080 y=181  w=850  h=879 fontsize=45 color=#000000ff

# -------------------------------------------------------------
# -- intro slide template
# -------------------------------------------------------------
@bg img=assets/bgwater.jpg
@push intro_title    x=150 y=400 w=1700 h=223 fontsize=96 color=#7A7A7AFF shadow=#000000FF
@push intro_subtitle x=219 y=728 w=1400 h=246 fontsize=45 color=#cd0f2dff
@push intro_authors  x=219 y=818 w=836 h=246 fontsize=45 color=#993366ff
# the following pushslide will the slide cause to be pushed, not rendered
@pushslide intro


# -------------------------------------------------------------
# -- chapter slide template
# -------------------------------------------------------------
# Note: with each new @slide, the current item context will be cleared.
#       That means, you will not inherit attributes from previous slides.

@bg img=assets/bgwater.jpg
@push chapter_number x=201 y=509 w=260 h=362 fontsize=300 color=#cd0f2dff
@push chapter_title  x=757 y=673 w=949 h=114 fontsize=72  color=#000000ff
@push chapter_subtitle x=757 y=794 w=887 h=141 fontsize=45 color=#993366ff
@pushslide chapter

# -------------------------------------------------------------
# -- content slide template
# -------------------------------------------------------------
@bg img=assets/bglb.jpg
@pop slide_number
@pushslide content transition=slide-left duration=0.35

# -------------------------------------------------------------
# -- thankyou slide template
# -------------------------------------------------------------
@bg img=assets/bgwater.jpg
@box                    x=219  y=250  w=1750  h=223 fontsize=144 color=#cd0f2dff shadow=#000000FF shadow_offset=2 text=**THANK YOU FOR YOUR ATTENTION**
#@box                    x=219  y=250  w=1750  h=223 fontsize=144 color=#606060FF text=**THANK YOU FOR YOUR ATTENTION**
@push thankyou_title    x=219  y=655  w=918  h=223 fontsize=52 color=#000000ff shadow=#000000ff shadow_offset=2
@push thankyou_subtitle x=219  y=749  w=836  h=246 fontsize=45 color=#000000ff
@push thankyou_authors  x=219  y=836  w=836  h=243 fontsize=45 color=#993366ff
@pushslide thankyou



# #############################################################
# ##   S  L  I  D  E  S
# #############################################################

# -------------------------------------------------------------
@popslide intro
@notes
Welcome everyone. This deck exercises transitions, staged reveals, and semantic morphs.
Use the phone to advance, then switch to Pointer to call out the Rayslides logo.
@endnotes
@pop intro_title text=!Slideshows in <$ZIGCOLOR$>ZIG</>!
@pop intro_subtitle text=_**Easy, text-based slideshows for Hackers, now with**_
@pop intro_authors text=_@renerocksai_

@box img=assets/raylib_96x96.png x=1280 y=680 scale=2.5 ratio=1.5

@pop rightbox x=1200 y=75
<#0000ffff>_~~https://github.com/renerocksai/slides~~_</>
@box img=assets/GitHub-Mark-64px.png x=1120 y=65 w=64 h=64

# -------------------------------------------------------------
@popslide content
@notes
Set the premise: source-native slides, live editing, and presenter tools in one executable.
Advance slowly—the overview bullets are revealed one at a time.
@endnotes
@pop slide_title text=~~**Overview**~~
@anim(fade) by=bullet duration=0.25
@pop bigbox bullet_symbol=- color=#202020FF
- **Presentations are created in a simple, markdown-based text format**
        - <#808080FF>_makes your slides totally GitHub-friendly_</>
_
- **One single (mostly static) executable** _- no install required._
        - <#808080FF>_for Windows, Linux (and Mac, if you build it yourself)_</>
_
_
- **Built-in editor:** _create, edit, present, ..., make changes while presenting_
        - <#808080FF>_press [E] key to try it out_</>
_
- **Support for clickers**
_
_
- **Virtual laser pointer in different sizes**
        - <#808080FF>_press [L] key and [SHIFT] + [L] to try it out_</>



# -------------------------------------------------------------
@popslide content
@notes
Demonstrate Markdown formatting and nested bullets.
The right column animates automatically after each reveal; watch the phone preview keep up.
@endnotes
@pop slide_title text=~~**Formatting Text**~~

@pop  sources_info
here come the sources

@pop leftbox
This is Markdown _**ta-dah**_, **tah**, _dah_!
_
empty lines are marked with just an _ underscore
_
- here comes the text
    - even more
        - and let's wrap one more time into a nicely aligned textbox
_
- and so on
_
- now let us create a text that is very likely to need to be wrapped since it is too long to be rendered on a single line of text in the left box
_
- **and so on**, _and on_

@anim(slide-left) by=bullet after=0.45 duration=0.2
@pop rightbox bullet_symbol=*
_
_
_
- here is text in the right box
_
- we changed the **~~bullet symbol~~**!
_
- and so on
_
- here comes more text
_
- and so on
_
- here comes more text
_
- and ~~**so on**~~

# -------------------------------------------------------------
@popslide content
@notes
This image enters with a slide-up animation.
Use Pointer mode to indicate details in the editor screenshot.
@endnotes
@pop slide_title text=**Easier than Bullets**

@anim(slide-up) duration=0.4
@box img=assets/godotscr2.png x=400 y=150 w=1475 h=840

@pop leftbox w=260 h=800
- single executable for presenting and editing
_
- text based slide format.
_
- no need to drag, click, and find and edit properties
_
- compare ------->
_
- however, simpler:
    - no complex animationse
    - no scripting
    - ...

# -------------------------------------------------------------
@popslide content
@notes
Explain how text, images, and translucent color boxes compose freely.
This is also a useful high-contrast pointer and preview test.
@endnotes
@pop slide_title text=~~**Easier than Bullets**~~

@box x=1398 y=148 w=404 h=204 color=#606060FF
@box x=1400 y=150 w=400 h=200 img=./assets/bgwater.jpg
@box x=1400 y=450 w=400 h=200 color=#B00040B0
@box x=1430 y=760 w=340 h=180 img=./assets/bgwater.jpg
@box x=1600 y=800 w=240 h=100 color=#B00040B0

@pop rightbox x=1431 y=801 w=400 color=#B0B0B0FF
       **it works in combination, too**
@pop rightbox x=1430 y=800 w=400 color=#202020FF
       **it works in combination, too**

@pop leftbox w=1000 h=800
_
- with _@box img=..._ you place images
_
_
_
_
_
- with _@box color=..._ and no text, you place colored boxes
    > ... with ALPHA!

@box leftbox x=110 y=800 w=1000 h=800 color=#cd0f2dff
- with _@box color=... text=..._ you place text boxes with colored text

# -------------------------------------------------------------
# The three animation layers, shown with the syntax that enables each one.
@popslide content transition=slide-left duration=0.45
@notes
Three animation layers: reveal content, transition whole slides, then morph named objects.
Advance through each bullet before moving on.
@endnotes

@pop slide_title text=~~**Animation without choreography**~~
@box x=145 y=145 w=1550 h=70 fontsize=35 color=#606060ff text=Choose what advances. Rayslides handles frames, timing, and reverse playback.

@box x=100 y=240 w=820 h=560 color=#edf4f9ee
@box x=1000 y=240 w=820 h=560 color=#f7eef4ee

@box x=145 y=275 w=730 h=55 fontsize=31 color=#182f49ff text=**BUILD CONTENT INSIDE A SLIDE**
@box x=145 y=345 w=730 h=65 fontsize=27 color=#303030ff text=`@anim(fade) by=bullet duration=0.35`

# This is not only an explanation: these bullets actually use the directive
# printed immediately above them.
@anim(fade) by=bullet duration=0.35
@box x=155 y=445 w=700 h=265 fontsize=31 line_height=1.55 color=#303030ff bullet_symbol=•
- Each bullet becomes one step automatically
- → reveals; ← hides the same step
- Add `after=1.0` when no click should be needed

@box x=1045 y=275 w=730 h=55 fontsize=31 color=#56203fff text=**MOVE BETWEEN WHOLE SLIDES**
@box x=1045 y=345 w=730 h=65 fontsize=27 color=#303030ff text=`@slide transition=slide-left duration=0.45`
@box x=1055 y=445 w=700 h=265 fontsize=31 line_height=1.55 color=#303030ff bullet_symbol=•
- The old and new slide animate together
- Going backward flips the direction
- The content timeline remains intact

@box x=180 y=865 w=1560 h=90 fontsize=32 color=#993366ff text=`@anim` reveals content   •   `transition=` moves slides   •   `@state(morph)` rearranges objects

# -------------------------------------------------------------
# Semantic morphing: first teach the tiny mental model.
@popslide content transition=fade duration=0.4
@notes
Introduce the morph mental model: identify an object once, then describe its destination.
The lines on the right reveal automatically.
@endnotes

@pop slide_title text=~~**Semantic morphs: the entire idea**~~

@box x=110 y=205 w=770 h=625 color=#edf4f9ee
@box x=1040 y=205 w=770 h=625 color=#f7eef4ee
@box x=150 y=240 w=680 h=70 fontsize=36 color=#182f49ff text=**You describe two snapshots**
@box x=1080 y=240 w=680 h=70 fontsize=36 color=#56203fff text=**Rayslides creates the journey**

@box x=155 y=335 w=665 h=54 fontsize=25 color=#606060ff text=1. Name the object once
@box x=155 y=395 w=665 h=75 fontsize=28 color=#303030ff text=`@box id=photo x=1210 y=250 w=610 h=347`
@box x=155 y=515 w=665 h=54 fontsize=25 color=#606060ff text=2. Describe only its destination
@box x=155 y=575 w=665 h=54 fontsize=28 color=#303030ff text=`@state(morph)`
@box x=155 y=640 w=665 h=105 fontsize=28 color=#303030ff text=`@set photo x=0 y=0 w=1920 h=1080`

@box x=915 y=475 w=90 h=110 fontsize=76 color=#f7a41dff text=→

# This list builds itself line by line. It doubles as a quiet reminder that
# ordinary reveal animation and semantic states share one presentation.
@anim(fade) by=line duration=0.3 after=0.25
@box x=1090 y=345 w=650 h=390 fontsize=31 line_height=1.7 color=#303030ff bullet_symbol=•
- Matches both snapshots by `id=photo`
- Interpolates position and size
- Fades objects entering or leaving
- Reverses the exact same path with ←

@box x=200 y=880 w=1520 h=75 fontsize=34 color=#993366ff text=You author the destination — not timelines, copied slides, or hand-written keyframes.

# -------------------------------------------------------------
# Now let the audience watch that model operate: one logical slide, four
# reversible states. One click starts it; the later states schedule themselves.
@popslide content transition=fade duration=0.4
@notes
Now let the semantic morph sequence play. The phone preview should track every animated state.
Try moving the phone laser across the changing objects while the animation runs.
@endnotes

# These flowchart elements start hidden, but already have stable identities
# and sit behind the labels they will receive later.
@box id=flow_card_source visible=false x=80 y=390 w=520 h=220 color=#182f49ee
@box id=flow_card_state visible=false x=685 y=390 w=550 h=220 color=#56203fee
@box id=flow_card_story visible=false x=1320 y=390 w=520 h=220 color=#214b35ee
@box id=flow_arrow_one visible=false x=605 y=445 w=75 h=100 fontsize=76 color=#f7a41dff text=→
@box id=flow_arrow_two visible=false x=1240 y=445 w=75 h=100 fontsize=76 color=#f7a41dff text=→

@box id=hero_image img=assets/godotscr2.png x=1210 y=250 w=610 h=347
@pop slide_title id=morph_title x=110 y=135 w=1080 h=150 fontsize=66 color=#202020ff shadow=#ffffffff shadow_offset=3 text=**One click. Then the states run themselves.**
@box id=morph_tagline x=150 y=340 w=900 h=180 fontsize=39 color=#606060ff text=The image already has `id=hero_image`. We only describe where it should go next.
@box id=morph_prompt x=150 y=800 w=900 h=100 fontsize=30 color=#993366ff text=Press → once. No keyframes are defined.

# First click: the thumbnail becomes the entire stage while the same title
# changes position, size, color, and shadow.
@state(morph) duration=1.0 ease=spring
@set hero_image x=0 y=0 w=1920 h=1080
@set morph_title x=85 y=55 w=1700 fontsize=78 color=#f7a41dff shadow=#000000e0 shadow_offset=8
@hide morph_tagline x=2050
@hide morph_prompt y=1180
@box id=fullscreen_panel x=70 y=845 w=1780 h=180 color=#080d18d8
@box id=fullscreen_code x=120 y=875 w=1680 h=60 fontsize=31 color=#f7a41dff text=`@set hero_image x=0 y=0 w=1920 h=1080`
@box id=fullscreen_caption x=120 y=945 w=1680 h=55 fontsize=29 color=#ffffffff text=One destination line. Rayslides generates every in-between frame automatically.

# Pull back automatically and introduce three independently addressable
# bullet items. New objects cross-fade into the next resolved state.
@state(morph) after=2.4 duration=0.8 ease=smooth
@set hero_image x=1460 y=805 w=330 h=188 opacity=0.24
@set morph_title x=110 y=70 w=1500 fontsize=58 color=#202020ff shadow=#ffffffff shadow_offset=3 text=**The next state started itself.**
@hide fullscreen_panel y=1180
@hide fullscreen_code y=1180
@hide fullscreen_caption x=-1800
@box id=auto_badge x=1320 y=190 w=500 h=105 fontsize=28 color=#993366ff text=`after=2.4` scheduled this scene — no click.
@box id=point_source x=170 y=330 w=1100 h=100 fontsize=43 color=#202020ff bullet_symbol=• text=- Name an object once with `id=`
@box id=point_state x=170 y=500 w=1100 h=100 fontsize=43 color=#202020ff bullet_symbol=• text=- Put only changed values in `@set`
@box id=point_story x=170 y=670 w=1100 h=100 fontsize=43 color=#202020ff bullet_symbol=• text=- Rayslides fills in every frame
@box id=patch_note x=170 y=825 w=1130 h=70 fontsize=28 color=#606060ff text=Everything you do not mention simply carries forward.

# The bullets are not recreated: the exact same logical objects rearrange
# themselves into a flowchart as the hidden furniture comes alive.
@state(morph) after=2.6 duration=1.8 ease=spring
@show flow_card_source
@show flow_card_state
@show flow_card_story
@show flow_arrow_one
@show flow_arrow_two
@set morph_title text=**Those same three bullets become this diagram.**
@hide auto_badge x=2050
@set point_source x=125 y=465 w=430 h=110 fontsize=32 color=#ffffffff shadow=#000000b0 shadow_offset=3
@set point_state x=725 y=465 w=470 h=110 fontsize=32 color=#ffffffff shadow=#000000b0 shadow_offset=3
@set point_story x=1365 y=465 w=430 h=110 fontsize=32 color=#ffffffff shadow=#000000b0 shadow_offset=3
@set patch_note x=400 y=720 w=1120 fontsize=29 color=#606060ff text=Same IDs. New coordinates. No copied slide.
@box id=flow_result x=390 y=805 w=1140 h=100 fontsize=46 color=#f7a41dff shadow=#000000b0 shadow_offset=5 text=**Name it → Patch it → Rayslides animates it**

# Finally, map every tiny author instruction to the automatic behavior it
# unlocks. Changed text cross-fades; exiting objects move and fade.
@state(morph) after=3.2 duration=0.9 ease=spring
@hide hero_image x=2050 y=900
@hide flow_card_source y=1180
@hide flow_card_state y=1180
@hide flow_card_story y=1180
@hide flow_arrow_one y=1180
@hide flow_arrow_two y=1180
@hide point_source y=1180
@hide point_state y=1180
@hide point_story y=1180
@hide patch_note y=1180
@hide flow_result y=1180
@set morph_title x=150 y=95 w=1650 fontsize=62 color=#f7a41dff shadow=#000000d0 shadow_offset=5 text=**You describe intent. Rayslides supplies motion.**

@box id=summary_left_heading x=155 y=220 w=680 h=65 fontsize=31 color=#182f49ff text=**YOU WRITE**
@box id=summary_right_heading x=980 y=220 w=760 h=65 fontsize=31 color=#56203fff text=**RAYSLIDES DOES AUTOMATICALLY**

@box id=summary_row_one x=120 y=300 w=1680 h=90 color=#edf4f9dd
@box id=summary_row_two x=120 y=410 w=1680 h=90 color=#f7eef4dd
@box id=summary_row_three x=120 y=520 w=1680 h=90 color=#edf4f9dd
@box id=summary_row_four x=120 y=630 w=1680 h=90 color=#f7eef4dd
@box id=summary_row_five x=120 y=740 w=1680 h=90 color=#edf4f9dd

@box id=summary_code_one x=155 y=325 w=670 h=45 fontsize=28 color=#303030ff text=`id=hero_image`
@box id=summary_code_two x=155 y=435 w=670 h=45 fontsize=28 color=#303030ff text=`@set hero_image x=0 w=1920`
@box id=summary_code_three x=155 y=545 w=670 h=45 fontsize=28 color=#303030ff text=`@show card` / `@hide caption`
@box id=summary_code_four x=155 y=655 w=670 h=45 fontsize=28 color=#303030ff text=`@state(morph) after=2.4`
@box id=summary_code_five x=155 y=765 w=670 h=45 fontsize=28 color=#303030ff text=Press ←

@box id=summary_auto_one x=980 y=325 w=760 h=45 fontsize=28 color=#303030ff text=Matches the same object across states
@box id=summary_auto_two x=980 y=435 w=760 h=45 fontsize=28 color=#303030ff text=Interpolates every changed property
@box id=summary_auto_three x=980 y=545 w=760 h=45 fontsize=28 color=#303030ff text=Fades objects in or out
@box id=summary_auto_four x=980 y=655 w=760 h=45 fontsize=28 color=#303030ff text=Waits, eases, and starts without a click
@box id=summary_auto_five x=980 y=765 w=760 h=45 fontsize=28 color=#303030ff text=Reconstructs every previous frame in reverse

@box id=summary_footer x=210 y=880 w=1500 h=70 fontsize=32 color=#993366ff text=No timeline editor. No duplicate slides. No hand-authored keyframes.


# -------------------------------------------------------------
@popslide thankyou
@notes
Close on the source-native workflow and invite questions.
This final cue also verifies that private notes never appear on the projected slide.
@endnotes
@pop thankyou_title color=#7A7A7AFF text=!Slideshows in ZIG!
@pop thankyou_subtitle color=#202020FF text=_Slideshows for Hackers_
@pop thankyou_authors text=_@renerocksai_

@pop rightbox x=1200 y=50
<#0000ffff>_~~https://github.com/renerocksai/slides~~_</>
@box img=assets/GitHub-Mark-64px.png x=1120 y=45 w=64 h=64
# -------------------------------------------------------------
# eof commits the slide
