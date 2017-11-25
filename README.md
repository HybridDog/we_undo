`//undo` undo the latest worldedit command<br/>
`//redo` redo what was just undone<br/>
`//show_journal` view what can be undone and redone

The changes of nodes after invoking /set are compressed to improve memory usage.

Related issues:
* https://github.com/Uberi/Minetest-WorldEdit/issues/43
* https://forum.minetest.net/viewtopic.php?p=296543#p296543

Supported chatcommands:
* /pos1
* /pos2
* /p
* /set
* /load
* /y
* /n

Ignored chatcommands:
* /fixlight
* /volume
* /save


TODO:
* Add parameters to undo and redo: undo the last n
* Allow undoing changes which happened before other changes (considered unsafe)
	e.g. //undo ~1 to undo the change before the latest one
* Implement more commands
