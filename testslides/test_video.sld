@fontsize=36
@color=#ffffffff

@slide
@bg color=#101418ff
@box x=110 y=60 w=1700 h=80 fontsize=52
**Video demo** — `m` play/pause, `Shift+M` stop
@box vid=assets/video_demo.mp4 x=320 y=200 w=1280 autoplay

@slide
@bg color=#101418ff
@box x=110 y=60 w=1700 h=80 fontsize=52
Looping video at natural size, no autoplay
@box vid=assets/video_demo.mp4 x=640 y=300 loop poster=3
@box x=110 y=760 w=1700 h=80 fontsize=32 color=#9fb2c8ff
Press `m` to start it. The still is the frame at 3s (`poster=3`).

@slide
@bg color=#000000ff
@box x=110 y=30 w=1700 h=70 fontsize=48
**Big Buck Bunny** — 1080p with sound
@box vid=assets/big_buck_bunny_trailer.mp4 x=160 y=120 w=1600 autoplay
@box x=160 y=1020 w=1600 h=50 fontsize=22 color=#8a8a8aff
(c) 2008 Blender Foundation | www.bigbuckbunny.org | CC-BY 3.0

@slide
@bg color=#000000ff
@box x=110 y=30 w=1700 h=70 fontsize=48
**poster=6.2** — the still is the tree scene, not the white first frame
@box vid=assets/big_buck_bunny_trailer.mp4 x=320 y=160 w=1280 poster=6.2
@box x=160 y=920 w=1600 h=60 fontsize=26 color=#9fb2c8ff
This video is not playing. Without `poster=`, the still would be plain white.
@box x=160 y=1020 w=1600 h=50 fontsize=22 color=#8a8a8aff
(c) 2008 Blender Foundation | www.bigbuckbunny.org | CC-BY 3.0
