# Parser-clean failure fixture for recoverable Studio media diagnostics.

@fontsize=34
@color=#edf6ffff

@slide
@bg color=#07111fff
@box id=title x=96 y=64 w=1728 h=86 fontsize=56 text=Missing media remains repairable
@box id=image_label x=96 y=174 w=760 h=52 fontsize=26 color=#ff8072ff text=IMAGE · missing file
@box id=missing_image img=assets/does-not-exist.png x=96 y=240 w=760 h=520 fit=contain
@box id=video_label x=1064 y=174 w=760 h=52 fontsize=26 color=#ff8072ff text=VIDEO · missing file or decoder
@box id=missing_video vid=assets/does-not-exist.mp4 x=1064 y=240 w=760 h=428 fit=cover poster=2
@box id=footer x=96 y=930 w=1728 h=64 fontsize=24 color=#7892a8ff text=Studio must keep both boxes selectable and expose Replace.
