## Usage

`//undo` undo the latest worldedit command<br/>
`//redo` redo what was just undone<br/>
`//show_journal` view what can be undone and redone

The changes of nodes after invoking /set are compressed to improve memory usage.


## Related issues:

* https://github.com/Uberi/Minetest-WorldEdit/issues/43
* https://forum.minetest.net/viewtopic.php?p=296543#p296543


## Implemented and missing Worldedit commands

#### Supported chatcommands

* /pos1 and /1
* /pos2 and /2
* /p
* /set and /s
* /mix
* /replace and /r
* /replaceinverse and /ri
* /orient
* /cube and /hollowcube
* /sphere and /spr
* /hollowsphere and /hspr
* /dome and /do
* /hollowdome and /hdo
* /cylinder and /cyl
* /hollowcylinder and /hcyl
* /pyramid and /pyr
* /hollowpyramid and /hpyr
* /spiral
* /load
* /mtschemplace
* /y
* /n


#### Ignored chatcommands

* /lua
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


#### Not yet implemented

* /fixedpos /fp
* /reset /rst
* /shift
* /expand
* /contract
* /outset
* /inset
* /copy
* /move
* /stack
* /stack2
* /scale
* /transpose
* /rotate
* /drain
* /hide
* /suppress
* /highlight
* /restore
* /allocate
* /deleteblocks


#### Partly implemented

No medatada support:
* /luatransform (nodes and metadata changes inside the selected area)
* /flip



## TODO

* Add parameters to undo and redo: undo the last n
* Allow undoing changes which happened before other changes (considered unsafe)
	e.g. //undo ~1 to undo the change before the latest one
* Add times to the changes, show in //show_journal
* Implement more commands
* worldedit pyramid fix
* Fix the shown "nodes changed" count
* Fix metadata collecting in run_and_capture_changes
