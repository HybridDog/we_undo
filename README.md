## Usage

`//undo` undo the latest worldedit command<br/>
`//redo` redo what was just undone<br/>
`//show_journal` view what can be undone and redone

Undoing reverts changes of nodes (name, param1 and param2) and metadata.
Node timers are not yet supported.
The undo functionality should help against accidents;
however, it should not be considered reliable since there is no guarantee that
undoing always is possible or works correctly.

The changes of nodes after invoking a command such as /set are compressed to
improve memory usage.


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
* /hide
* /suppress
* /highlight
* /restore
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
* /drain
* /allocate
* /deleteblocks


#### Partly implemented

No metadata support:
* /luatransform (nodes and metadata changes inside the selected area)
* /flip
* /transpose (the marker position change is not saved)
* /rotate (the marker position change is not saved)
* /stretch (the marker position change is not saved)



## TODO

* Add parameters to undo and redo: undo the last n
* Allow undoing changes which happened before other changes (considered unsafe)
	e.g. //undo ~1 to undo the change before the latest one
* Add times to the changes, show in //show_journal
* Implement more commands
* worldedit pyramid fix
* Fix the shown "nodes changed" count
* Fix metadata collecting in run_and_capture_changes
