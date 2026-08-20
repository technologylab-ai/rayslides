@fontsize=34
@color=#dbe8f5ff

@push title x=120 y=90 w=1680 h=100 fontsize=58 color=#61dafbff

@bg color=#07111fff
@pop title text=Section
@pushslide content transition=slide-left duration=0.35

@popslide content
@set title text=Why plain text?
@anim(fade) by=bullet
@box x=120 y=260 w=1200 h=600
- Git can show each change.
- Studio can edit the same file.
- The presenter needs no cloud service.

@popslide content transition=fade
@set title text=The result
@box x=120 y=300 w=1680 h=220 fontsize=64 text=One file. Two ways to edit.
