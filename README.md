`//undo` undo the latest worldedit command<br/>
`//redo` redo what was just undone<br/>
`//show_journal` view what can be undone and redone

The changes of nodes after invoking /set are compressed to improve memory usage.

Related issues:
* https://github.com/Uberi/Minetest-WorldEdit/issues/43
* https://forum.minetest.net/viewtopic.php?p=296543#p296543

Supported chatcommands:
* /pos1 and /1
* /pos2 and /2
* /p
* /set and /s
* /replace and /r
* /replaceinverse and /ri
* /sphere and /spr
* /hollowsphere and /hspr
* /load
* /y
* /n

Ignored chatcommands:
* /lua
* /luatransform
* /clearobjects
* /fixlight
* /save
* /mtschemcreate
* /mtschemprob
* /inspect /i
* /mark /mk
* /unmark /umk
* /volume and /v
* /about

Not yet implemented:
* /fixedpos /fp
* /reset /rst
* /shift
* /expand
* /contract
* /outset
* /inset
* /mix
* /hollowdome /hdo
* /dome /do
* /hollowcylinder /hcyl
* /cylinder /cyl
* /hollowpyramid /hpyr
* /pyramid /pyr
* /spiral
* /copy
* /move
* /stack
* /stack2
* /scale
* /transpose
* /flip
* /rotate
* /orient
* /drain
* /hide
* /suppress
* /highlight
* /restore
* /allocate
* /mtschemplace
* /deleteblocks



TODO:
* Add parameters to undo and redo: undo the last n
* Allow undoing changes which happened before other changes (considered unsafe)
	e.g. //undo ~1 to undo the change before the latest one
* Add times to the changes, show in //show_journal
* Implement more commands
