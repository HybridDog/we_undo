

----------------- Settings -----------------------------------------------------

local max_commands = 256
local min_commands = 3
local max_memory_usage = 2^25 -- 32 MiB


----------------- Journal and chatcommands -------------------------------------

local command_invoker

local function override_chatcommand(cname, func_before, func_after)
	local command = minetest.registered_chatcommands[cname]
	-- save the name of the player and execute func_before if present
	if func_before then
		local func = command.func
		command.func = function(name, ...)
			command_invoker = name
			func_before(...)
			return func(name, ...)
		end
	else
		local func = command.func
		command.func = function(name, ...)
			command_invoker = name
			return func(name, ...)
		end
	end

	-- reset command_invoker and optionally execute func_after
	if func_after then
		local func = command.func
		command.func = function(name, ...)
			local rv = func(name, ...)
			local custom_rv = func_after(...)
			command_invoker = nil
			if custom_rv ~= nil then
				return custom_rv
			end
			return rv
		end
	else
		local func = command.func
		command.func = function(...)
			local rv = func(...)
			command_invoker = nil
			return rv
		end
	end
end


local journal = {}
local function add_to_history(data, name)
	name = name or command_invoker
	journal[name] = journal[name] or {
		ring = {},
		start = 0,
		off_start = -1,
		entry_count = 0,
		mem_usage = 0,
	}
	local j = journal[name]

	j.off_start = j.off_start+1
	if j.off_start == j.entry_count then
		j.entry_count = j.entry_count+1
	end
	if j.off_start == max_commands then
		-- max_commands are stored, replace the oldest one
		j.mem_usage = j.mem_usage - j.ring[j.start].mem_use
		j.start = (j.start+1) % max_commands
		j.off_start = j.off_start-1
		j.entry_count = j.entry_count-1
		assert(j.start == (j.start + j.off_start + 1) % max_commands
			and j.entry_count == j.off_start+1
			and j.entry_count == max_commands)
	end
	if j.entry_count-1 > j.off_start then
		print(j.off_start, j.entry_count)
		-- remove redo remnants
		for i = j.off_start+1, j.entry_count-1 do
			local im = (j.start + i) % max_commands
			j.mem_usage = j.mem_usage - j.ring[im].mem_use
			j.ring[im] = nil
		end
		j.entry_count = j.off_start+1
	end
	-- insert the new data
	j.ring[(j.start + j.off_start) % max_commands] = data
	j.mem_usage = j.mem_usage + data.mem_use

	-- remove old data if too much memory is used
	if j.mem_usage > max_memory_usage then
		while j.entry_count > min_commands do
			j.mem_usage = j.mem_usage - j.ring[j.start].mem_use
			j.ring[j.start] = nil
			j.start = (j.start+1) % max_commands
			j.off_start = j.off_start-1
			j.entry_count = j.entry_count-1
			if j.mem_usage <= max_memory_usage then
				break
			end
		end
	end
end

-- remove old undo history after un- or redoing
local function trim_undo_history(j)
	while j.entry_count > min_commands
	and j.off_start > 0 do
		j.mem_usage = j.mem_usage - j.ring[j.start].mem_use
		j.ring[j.start] = nil
		j.start = (j.start+1) % max_commands
		j.off_start = j.off_start-1
		j.entry_count = j.entry_count-1
		if j.mem_usage <= max_memory_usage then
			return
		end
	end
	-- never remove redo history
end

local undo_funcs = {}
local function apply_undo(name)
	local j = journal[name]
	local i = (j.start + j.off_start) % max_commands
	local data = j.ring[i]
	local old_memuse = data.mem_use
	undo_funcs[data.type](name, data)
	j.mem_usage = j.mem_usage + data.mem_use - old_memuse
	j.ring[i] = data
	j.off_start = j.off_start-1
	if j.mem_usage > max_memory_usage then
		trim_undo_history(j)
	end
end

local function apply_redo(name)
	local j = journal[name]
	j.off_start = j.off_start+1
	local i = (j.start + j.off_start) % max_commands
	local data = j.ring[i]
	local old_memuse = data.mem_use
	-- undoing an undone undo function is redoing
	undo_funcs[data.type](name, data)
	j.mem_usage = j.mem_usage + data.mem_use - old_memuse
	j.ring[i] = data
	if j.mem_usage > max_memory_usage then
		trim_undo_history(j)
	end
end

minetest.register_chatcommand("/undo", {
	params = "",
	description = "Worldedit undo",
	privs = {worldedit=true},
	func = function(name)
		local j = journal[name]
		if not j
		or j.off_start < 0 then
			return false, "Nothing to be undone, try //show_journal"
		end
		apply_undo(name)
	end,
})

minetest.register_chatcommand("/redo", {
	params = "",
	description = "Worldedit redo",
	privs = {worldedit=true},
	func = function(name)
		local j = journal[name]
		if not j
		or j.off_start == j.entry_count-1 then
			return false, "Nothing to be redone, try //show_journal"
		end
		apply_redo(name)
	end,
})

local undo_info_funcs = {}
minetest.register_chatcommand("/show_journal", {
	params = "",
	description = "List Worldedit undos and redos, the last one is the newest",
	privs = {worldedit=true},
	func = function(name)
		local j = journal[name]
		if not j then
			return false, "Empty journal"
		end
		local info = j.entry_count .. " entries, " ..
			j.off_start+1 .. " can be undone, " ..
			j.entry_count-1 - j.off_start .. " can be redone\n"
		for i = 0, j.entry_count-1 do
			if i <= j.off_start then
				-- undo entry
				info = info ..
					minetest.get_color_escape_sequence"#A47DFF" .. " "
			else
				-- redo entry
				info = info ..
					minetest.get_color_escape_sequence"#8ABDA9" .. "* "
			end
			local data = j.ring[(j.start + i) % max_commands]
			info = info .. data.type
			if undo_info_funcs[data.type] then
				info = info .. ": " .. undo_info_funcs[data.type](data)
			end
			if i < j.entry_count-1 then
				info = info .. "\n" ..
				minetest.get_color_escape_sequence"#ffffff"
			end
		end
		return true, info
	end,
})


----------------- The worldedit stuff ------------------------------------------

override_chatcommand("/pos1",
	function()
		add_to_history{
			type = "marker",
			mem_use = 9 * 7,
			id = 1,
			pos = worldedit.pos1[command_invoker]
		}
	end
)

override_chatcommand("/pos2",
	function()
		add_to_history{
			type = "marker",
			mem_use = 9 * 7,
			id = 2,
			pos = worldedit.pos2[command_invoker]
		}
	end
)

undo_funcs.marker = function(name, data)
	local pos = data.pos
	local i = "pos" .. data.id
	local current_pos = worldedit[i][name]
	worldedit[i][name] = pos
	worldedit["mark_pos" .. data.id](name)
	if pos then
		worldedit.player_notify(name, "position " .. data.id .. " set to " ..
			minetest.pos_to_string(pos))
	else
		worldedit.player_notify(name, "position " .. data.id .. " reset")
	end
	data.pos = current_pos
end
undo_info_funcs.marker = function(data)
	if not data.pos then
		return "Set pos" .. data.id
	end
	return "changed pos" .. data.id .. ", previous value: " ..
		minetest.pos_to_string(data.pos)
end


local we_data = false
local we_manip_end = worldedit.manip_helpers.finish
function worldedit.manip_helpers.finish(manip, data)
	if we_data == nil then
		we_data = data
	end
	return we_manip_end(manip, data)
end

local we_set = worldedit.set
local my_we_set = function(pos1, pos2, ...)
	assert(command_invoker, "Player not known")
	pos1, pos2 = worldedit.sort_pos(pos1, pos2)
	-- FIXME: Protection support isn't needed

	local manip = minetest.get_voxel_manip()
	local e1, e2 = manip:read_from_map(pos1, pos2)
	local area = VoxelArea:new{MinEdge=e1, MaxEdge=e2}
	local data_before = manip:get_data()

	we_data = nil
	local rv = we_set(pos1, pos2, ...)

	local ystride = pos2.x - pos1.x + 1
	local zstride = (pos2.y - pos1.y + 1) * ystride
	-- put indices separate because they don't correlate with nodeids
	local indices = {}
	local nodeids = {}
	for z = pos1.z, pos2.z do
		for y = pos1.y, pos2.y do
			for x = pos1.x, pos2.x do
				local i = area:index(x,y,z)
				if we_data[i] ~= data_before[i] then
					indices[#indices+1] =
						(z - pos1.z) * zstride
						+ (y - pos1.y) * ystride
						+ x - pos1.x
					nodeids[#nodeids+1] = data_before[i]
				end
			end
		end
	end
	we_data = false

	add_to_history({
		type = "nodeids",
		mem_use = 9 * (2 * 7 + 2 * #nodeids + 2),
		pos1 = pos1,
		pos2 = pos2,
		nodeids = nodeids,
		indices = indices,
	}, command_invoker)

	return rv
end
override_chatcommand("/set",
	function()
		worldedit.set = my_we_set
	end,
	function()
		worldedit.set = we_set
	end
)

undo_funcs.nodeids = function(name, data)
	local pos1 = data.pos1
	local pos2 = data.pos2
	local ylen = pos2.y - pos1.y + 1
	local ystride = pos2.x - pos1.x + 1

	local manip = minetest.get_voxel_manip()
	local e1, e2 = manip:read_from_map(pos1, pos2)
	local area = VoxelArea:new{MinEdge=e1, MaxEdge=e2}
	local mdata = manip:get_data()

	-- swap the nodes in the world and history data
	local new_nodeids = {}
	for k = 1,#data.indices do
		local i = data.indices[k]
		local x = i % ystride
		local y = math.floor(i / ystride) % ylen
		local z = math.floor(i / (ystride * ylen))
		local vi = area:index(pos1.x + x, pos1.y + y, pos1.z + z)
		new_nodeids[k] = mdata[vi]
		mdata[vi] = data.nodeids[k]
	end

	manip:set_data(mdata)
	manip:write_to_map()

	data.nodeids = new_nodeids

	worldedit.player_notify(name, #data.indices .. " nodes set")
end
undo_info_funcs.marker = function(data)
	if not data.pos then
		return "Set pos" .. data.id
	end
	return "changed pos" .. data.id .. ", previous value: " ..
		minetest.pos_to_string(data.pos)
end
