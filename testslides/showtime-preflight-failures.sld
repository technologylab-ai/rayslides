# Parser-clean failure fixture for Showtime's actionable readiness report.

@fontsize=34
@color=#edf6ffff

# Deliberately unused: Showtime must still materialize Library definitions.
@push unused_art img=assets/showtime-definition-missing.png x=80 y=80 w=640 h=360

@slide
@bg color=#07111fff
@box id=title x=96 y=64 w=1728 h=86 fontsize=56 text=Showtime failure fixture
@box id=missing_video vid=assets/showtime-missing.mp4 x=96 y=220 w=760 h=428 poster=2
@box id=overflow x=1064 y=220 w=260 h=60 fontsize=42 text=This text is intentionally much too wide
@box id=outside x=1750 y=760 w=420 h=180 color=#ffb547ff
@box id=glyph x=1064 y=520 w=700 h=90 fontsize=48 text=Unsupported glyph: 界

@state(morph) label=review
@set outside x=1820

@slide
@bg img=assets/showtime-background-missing.png
@box id=second_title x=96 y=64 w=1728 h=86 fontsize=56 text=Missing background image
