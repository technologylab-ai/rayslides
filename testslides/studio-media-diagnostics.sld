# Parser-clean fixture for non-blocking Studio media warnings.

@fontsize=34
@color=#edf6ffff

@slide
@bg color=#07111fff
@box id=title x=96 y=64 w=1728 h=86 fontsize=56 text=Media warnings retain real pixels
@box id=video_label x=580 y=174 w=760 h=52 fontsize=26 color=#ffb547ff text=VIDEO · poster beyond duration
@box id=poster_warning vid=assets/video_demo.mp4 x=580 y=240 w=760 h=428 fit=cover poster=999
@box id=footer x=96 y=930 w=1728 h=64 fontsize=24 color=#7892a8ff text=Studio should clamp to the last frame, show an amber warning, and keep the video selectable.
