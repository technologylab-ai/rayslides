# Motion authoring QA fixture. Exercises click and automatic bullet builds
# with distinct start/inter-step delays, an eased image reveal, inherited,
# overridden, and deck-default transitions, and a three-state morph with
# born, hidden, and shown objects. Keep this file parser-clean.

@fontsize=32
@color=#dbe8f5ff
@transition=fade
@transition_duration=0.35

@push slide_title x=120 y=90 w=1680 h=110 fontsize=64 color=#f7fbffff

@pushslide content transition=slide-left duration=0.45
@bg color=#07111fff
@box id=footer x=120 y=990 w=1680 h=40 fontsize=20 color=#5f7391ff text=Motion QA · $slide_number

# --- Slide 1: click-triggered bullet build ---------------------------------
@popslide content
@pop slide_title text=Bullets on click
@anim(fade) by=bullet duration=0.25
@box id=click_bullets x=120 y=260 w=1000 h=600 fontsize=40 bullet_color=#61dafbff
Intro text stays visible.
- First click reveals this bullet
- The next click reveals this one
    - Nested bullets are steps too

# --- Slide 2: automatic bullet build with start and inter-step delay -------
@popslide content transition=fade duration=0.5 ease=spring
@pop slide_title text=Bullets automatically
@anim(slide-left) by=bullet delay=0.5 after=0.8 duration=0.25 ease=spring
@box id=auto_bullets x=120 y=260 w=1000 h=600 fontsize=40 bullet_color=#ffb547ff
- Appears half a second after the slide settles
- Then this one 0.8 seconds later
- And the last one after another 0.8 seconds
@anim(slide-up) delay=0.2 duration=0.4 ease=linear
@box id=auto_image img=assets/studio-light-sculpture.png x=1240 y=260 w=560 h=560

# --- Slide 3: deck default transition and a three-state morph ---------------
@slide
@bg color=#0b1a2cff
@box id=hero img=assets/studio-light-sculpture.png x=1250 y=180 w=520 h=520
@box id=title x=120 y=180 w=1000 h=120 fontsize=72 color=#f7fbffff text=One object, many states
@box id=caption x=120 y=900 w=1600 h=60 fontsize=28 color=#a9bdd0ff visible=false text=Initially hidden

@state(morph) label=TAKEOVER duration=0.8 ease=spring
@set hero x=0 y=0 w=1920 h=1080
@set title x=80 y=55 fontsize=48 color=#f7a41dff
@show caption y=800

@state(morph) label=EXPLAIN after=1.2 duration=0.5
@hide caption x=-1600
@set hero x=1420 y=735 w=380 h=214 opacity=0.25
@box id=born_here x=120 y=800 w=1600 h=90 fontsize=36 color=#61dafbff text=Born in this state

@state(morph) label=FLOW after=0.6 duration=0.7 ease=linear
@hide hero x=2050
@set born_here y=500 fontsize=48
@set title text=The same objects form the next view.

# --- Slide 4: explicit no transition --------------------------------------
@slide transition=none
@bg color=#07111fff
@box id=plain x=120 y=460 w=1680 h=120 fontsize=56 color=#f7fbffff text=No transition on this slide
