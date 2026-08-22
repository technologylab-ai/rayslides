# Parser-clean image/video authoring fixture for Studio and Showtime QA.

@fontsize=34
@color=#edf6ffff

@push qa_video vid=assets/big_buck_bunny_trailer.mp4 w=760 h=360 fit=contain focus_y=0.5 poster=6.2 volume=0.8

@slide
@bg color=#07111fff
@box id=title x=96 y=64 w=1728 h=86 fontsize=56 text=First-class media authoring
@box id=image_label x=96 y=174 w=760 h=52 fontsize=26 color=#61dafbff text=IMAGE · shared authoring affordances
@box id=hero_image img=assets/studio-light-sculpture.png x=96 y=240 w=760 h=520 fit=contain
@box id=video_label x=1064 y=174 w=760 h=52 fontsize=26 color=#ffb547ff text=VIDEO · temporal authoring affordances
@pop qa_video id=hero_video vid=assets/big_buck_bunny_trailer.mp4 x=1064 y=240 fit=cover focus_y=0.75 poster=6.2 volume=0.65 rotation=3 loop muted
@box id=video_note x=1064 y=704 w=760 h=150 fontsize=30 color=#a9bdd0ff
Poster at 6.2s · loop enabled
Playback remains presenter-controlled
@box id=footer x=1064 y=934 w=760 h=66 fontsize=23 color=#7892a8ff text=Select either object to verify Properties and Replace.
