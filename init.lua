----------------- Settings -----------------------------------------------------

local remember_innocuous =
	minetest.settings:get_bool"we_undo.remember_innocuous" ~= false
local max_commands = tonumber(
	minetest.settings:get"we_undo.max_commands") or 256
local min_commands = tonumber(minetest.settings:get"we_undo.min_commands") or 3
local max_memory_usage = tonumber(
	minetest.settings:get"we_undo.max_memory_usage") or 2^25


----------------- Journal and we_undo chatcommands -----------------------------

local command_invoker

local function override_chatcommand(cname, func_before, func_after)
	local command = minetest.registered_chatcommands[cname]
	if not command then
		local cmds = {}
		for name in pairs(minetest.registered_chatcommands) do
			cmds[#cmds+1] = name
		end
		error("Chatcommand " .. cname .. " is not registered.\n" ..
			"Available commands: " .. table.concat(cmds, ", "))
	end
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
			local succ, msg = func(name, ...)
			local new_succ, new_msg = func_after(...)
			command_invoker = nil
			-- Both have to succeed for the return value
			succ = succ and new_succ
			msg = new_msg or msg or nil
			return succ, msg
		end
	else
		local func = command.func
		command.func = function(...)
			local succ, msg = func(...)
			command_invoker = nil
			return succ, msg
		end
	end
end


local journal = {}
local function add_to_history(data, name)
	name = name or command_invoker
	assert(name, "Player name isn't known")
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
		-- remove redo remnants
		for i = j.off_start+1, j.entry_count-1 do
			local im = (j.start + i) % max_commands
			j.mem_usage = j.mem_usage - j.ring[im].mem_use
			j.ring[im] = nil
		end
		j.entry_count = j.off_start+1
	end
	-- insert the new data
	-- make every entry supposedly have >= 16 bytes
	data.mem_use = (data.mem_use or 0) + 16
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
local function bare_apply_undo(j, name)
	local i = (j.start + j.off_start) % max_commands
	local data = j.ring[i]
	local old_memuse = data.mem_use
	undo_funcs[data.type](name, data)
	j.mem_usage = j.mem_usage + (data.mem_use or 0) + 16 - old_memuse
	j.ring[i] = data
end

local function apply_undo(name)
	local j = journal[name]
	bare_apply_undo(j, name)
	j.off_start = j.off_start-1
	if j.mem_usage > max_memory_usage then
		trim_undo_history(j)
	end
end

local function apply_redo(name)
	local j = journal[name]
	j.off_start = j.off_start+1
	-- undoing an undone undo function is redoing
	bare_apply_undo(j, name)
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


----------------- Harmless worldedit chatcommands ------------------------------

if remember_innocuous then

	-- short commands (/1 in this case) are automatically supported
	override_chatcommand("/pos1",
		function()
			add_to_history{
				type = "marker",
				id = 1,
				pos = worldedit.pos1[command_invoker]
			}
		end
	)

	override_chatcommand("/pos2",
		function()
			add_to_history{
				type = "marker",
				id = 2,
				pos = worldedit.pos2[command_invoker]
			}
		end
	)

	-- Punch before the /p command's punch
	table.insert(minetest.registered_on_punchnodes, 1, function(_,_, player)
		local name = player:get_player_name()
		local typ = worldedit.set_pos[name]
		if typ == "pos1"
		or typ == "pos1only" then
			add_to_history({
				type = "marker",
				id = 1,
				pos = worldedit.pos1[name]
			}, name)
		elseif typ == "pos2" then
			add_to_history({
				type = "marker",
				id = 2,
				pos = worldedit.pos2[name]
			}, name)
		end
	end)

	undo_funcs.marker = function(name, data)
		local pos = data.pos
		local i = "pos" .. data.id
		local current_pos = worldedit[i][name]
		worldedit[i][name] = pos
		worldedit["mark_pos" .. data.id](name)
		if pos then
			worldedit.player_notify(name, "position " .. data.id ..
				" set to " .. minetest.pos_to_string(pos))
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

end


----------------------- Functions common to other ones -------------------------

-- Catch confirmation requests (/y or /n follows)
local y_pending = {}
local we_notify = worldedit.player_notify
function worldedit.player_notify(name, msg)
	if msg:sub(1, 43) == "WARNING: this operation could affect up to " then
		y_pending[name] = true
	end
	return we_notify(name, msg)
end

override_chatcommand("/n",
	function()
		y_pending[command_invoker] = nil
	end
)

override_chatcommand("/y",
	function(...)
		local t = y_pending[command_invoker]
		if type(t) == "table"
		and t.before then
			t.before(...)
		end
	end,
	function(...)
		local t = y_pending[command_invoker]
		if type(t) == "table"
		and t.after then
			t.after(...)
		end
		y_pending[command_invoker] = nil
	end
)

local function override_cc_with_confirm(cname, func_before, actual_func_after)
	-- remember the functions for /y if needed
	local function func_after(...)
		if y_pending[command_invoker] then
			y_pending[command_invoker] = {before = func_before,
				after = func_after}
		end
		return actual_func_after(...)
	end
	return override_chatcommand(cname, func_before, func_after)
end


-- override the worldedit vmanip finish function to catch the data table
local we_data = false
local we_manip_end = worldedit.manip_helpers.finish
function worldedit.manip_helpers.finish(manip, data)
	if we_data == nil then
		we_data = data
	end
	return we_manip_end(manip, data)
end

local indic_names = {"indices_n", "indices_p1", "indices_p2", "indices_m"}
local function compress_nodedata(nodedata)
	local data, n = {}, 0
	-- put indices first
	for j = 1,#indic_names do
		local indices = nodedata[indic_names[j]]
		if indices then
			local prev_index = 0
			for i = 1,#indices do
				local index = indices[i]
				local off = index - prev_index -- always >= 0
				local v = ""
				for f = nodedata.index_bytes-1, 0, -1 do
					v = v .. string.char(math.floor(off * 2^(-8*f)) % 0x100)
				end
				n = n+1
				data[n] = v
				prev_index = index
			end
		end
	end
	-- nodeids contain 16 bit values (see mapnode.h)
	-- big endian here
	if nodedata.indices_n then
		for i = 1,#nodedata.nodeids do
			n = n+1
			data[n] = string.char(math.floor(nodedata.nodeids[i] * 2^-8)
				) .. string.char(nodedata.nodeids[i] % 0x100)
		end
	end
	-- param1 and param2 are 8 bit values
	for j = 1,2 do
		if nodedata["indices_p" .. j] then
			local vs = nodedata["param" .. j .. "s"]
			for i = 1,#vs do
				n = n+1
				data[n] = string.char(vs[i])
			end
		end
	end
	-- meta…
	if nodedata.indices_m then
		n = n+1
		data[n] = minetest.serialize(nodedata.metastrings)
	end
	return minetest.compress(table.concat(data))
end

local cnt_names = {"nodeids_cnt", "param1s_cnt", "param2s_cnt", "metaens_cnt"}
local function decompress_nodedata(ccontent)
	local result = {}
	local data = minetest.decompress(ccontent.compressed_data)
	local p = 1
	-- get indices
	for i = 1,#cnt_names do
		local cnt = ccontent[cnt_names[i]]
		if cnt then
			local indices = {}
			local prev_index = 0
			for k = 1,cnt do
				local v = prev_index
				for f = ccontent.index_bytes-1, 0, -1 do
					v = v + 2^(8*f) * data:byte(p)
					p = p+1
				end
				indices[k] = v
				prev_index = v
			end
			result[indic_names[i]] = indices
		end
	end
	-- get nodeids
	if ccontent.nodeids_cnt then
		local nodeids = {}
		for i = 1,ccontent.nodeids_cnt do
			nodeids[i] = data:byte(p) * 0x100 + data:byte(p+1)
			p = p + 2
		end
		result.nodeids = nodeids
	end
	-- get param1s and param2s
	for j = 1,2 do
		local cnt = ccontent["param" .. j .. "s_cnt"]
		if cnt then
			local vs = {}
			for i = 1,cnt do
				vs[i] = data:byte(p)
				p = p+1
			end
			result["param" .. j .. "s"] = vs
		end
	end
	-- get metaens strings
	if ccontent.metaens_cnt then
		result.metastrings = minetest.deserialize(data:sub(p))
	end
	return result
end

-- tells if the metadata is that dummy
local function is_meta_empty(metatabl)
	if metatabl.inventory
	and next(metatabl.inventory) ~= nil then
		return false
	end
	if metatabl.fields
	and next(metatabl.fields) ~= nil then
		return false
	end
	for k in pairs(metatabl) do
		if k ~= "inventory"
		and k ~= "fields" then
			return false
		end
	end
	return true
end

-- Gets information about meta if it is set, otherwise returns nil
-- the format of the information is the same as in WorldEdit
local function get_meta_serializable(pos)
	if not minetest.find_nodes_with_meta(pos, pos)[1] then
		return
	end
	local meta = minetest.get_meta(pos)
	local metat = meta:to_table()
	if is_meta_empty(metat) then
		-- FIXME: is this case covered by minetest.find_nodes_with_meta?
		minetest.log("error", "metadata should be inexistent")
		return
	end
	for _, inventory in pairs(metat.inventory) do
		for index = 1,#inventory do
			local itemstack = inventory[index]
			if itemstack.to_string then
				inventory[index] = itemstack:to_string()
			end
		end
	end
	return metat, meta
end

-- Collects all metadata in a serialized format inside the given area
-- This may be a slow function, thus should only be used when needed
local function get_metadatas_in_area(pos1, pos2)
	local meta_ps = minetest.find_nodes_with_meta(pos1, pos2)
	local meta_tables_list = {}
	local ystride = pos2.x - pos1.x + 1
	local zstride = (pos2.y - pos1.y + 1) * ystride
	for i = 1, #meta_ps do
		local pos = meta_ps[i]
		local meta = minetest.get_meta(pos)
		local metat = meta:to_table()
		if is_meta_empty(metat) then
			-- FIXME: is this case covered by minetest.find_nodes_with_meta?
			minetest.log("error", "metadata should be inexistent")
		else
			-- Make metat serializable
			for _, inventory in pairs(metat.inventory) do
				for index = 1,#inventory do
					local itemstack = inventory[index]
					if itemstack.to_string then
						inventory[index] = itemstack:to_string()
					end
				end
			end
			local rpos = vector.subtract(pos, pos1)
			meta_tables_list[#meta_tables_list+1] = {
				rpos.z * zstride + rpos.y * ystride + rpos.x,
				metat
			}
		end
	end
	table.sort(meta_tables_list, function(a, b)
		return a[1] < b[1]
	end)
	local indices_m = {}
	local metastrings = {}
	for i = 1, #meta_tables_list do
		indices_m[i] = meta_tables_list[i][1]
		metastrings[i] = minetest.serialize(meta_tables_list[i][2])
	end
	return indices_m, metastrings
end

-- A generic function to collect the changed nodes and metadata
-- (if collect_meta is true) between the times before and after executing func
local function run_and_capture_changes(func, pos1, pos2, collect_meta)
	-- Get the node ids, param1s and param2s (before)
	local manip = minetest.get_voxel_manip()
	local e1, e2 = manip:read_from_map(pos1, pos2)
	local area = VoxelArea:new{MinEdge=e1, MaxEdge=e2}
	local nodeids_before = manip:get_data()
	local param1s_before = manip:get_light_data()
	local param2s_before = manip:get_param2_data()

	local indices_m_before, metastrings_before
	if collect_meta then
		indices_m_before, metastrings_before = get_metadatas_in_area(pos1, pos2)
	end

	-- Run the actual function
	local rvs = {func()}

	-- Get the node ids, param1s and param2s (after)
	manip = minetest.get_voxel_manip()
	manip:read_from_map(pos1, pos2)
	local nodeids_after = manip:get_data()
	local param1s_after = manip:get_light_data()
	local param2s_after = manip:get_param2_data()

	local indices_m_after, metastrings_after
	if collect_meta then
		indices_m_after, metastrings_after = get_metadatas_in_area(pos1, pos2)
	end

	-- Collect the changed nodes
	local ystride = pos2.x - pos1.x + 1
	local zstride = (pos2.y - pos1.y + 1) * ystride
	local indices_n = {}
	local indices_p1 = {}
	local indices_p2 = {}
	local nodeids = {}
	local param1s = {}
	local param2s = {}
	for z = pos1.z, pos2.z do
		for y = pos1.y, pos2.y do
			for x = pos1.x, pos2.x do
				local vi_vm = area:index(x,y,z)
				local vi_my = (z - pos1.z) * zstride
					+ (y - pos1.y) * ystride
					+ x - pos1.x
				if nodeids_after[vi_vm] ~= nodeids_before[vi_vm] then
					indices_n[#indices_n+1] = vi_my
					nodeids[#nodeids+1] = nodeids_before[vi_vm]
				end
				if param1s_after[vi_vm] ~= param1s_before[vi_vm] then
					indices_p1[#indices_p1+1] = vi_my
					param1s[#param1s+1] = param1s_before[vi_vm]
				end
				if param2s_after[vi_vm] ~= param2s_before[vi_vm] then
					indices_p2[#indices_p2+1] = vi_my
					param2s[#param2s+1] = param2s_before[vi_vm]
				end
			end
		end
	end

	local indices_m = {}
	local metastrings = {}
	if collect_meta then
		-- Collect all metadata changes
		local i_after = 1
		for i_before = 1, #indices_m_before do
			local vi_before = indices_m_before[i_before]
			local vi_after = indices_m_after[i_after]
			if vi_before < vi_after then
				-- Metadata has been removed at vi_before
				indices_m[#indices_m+1] = vi_before
				metastrings[#metastrings+1] = metastrings_before[i_before]
			elseif vi_before == vi_after then
				-- Metadata exists before and after
				if metastrings_before[i_before]
						~= metastrings_after[i_after] then
					indices_m[#indices_m+1] = vi_before
					metastrings[#metastrings+1] = metastrings_before[i_before]
				end
				i_after = i_after + 1
				if i_after > #indices_m_after then
					break
				end
			else
				while vi_before > vi_after do
					-- Metadata has been added at vi_after
					indices_m[#indices_m+1] = vi_after
					metastrings[#metastrings+1] = "return nil"
					i_after = i_after + 1
					if i_after > #indices_m_after then
						break
					end
					vi_after = indices_m_after[i_after]
				end
			end
		end
		for i = i_after, #indices_m_after do
			-- Metadata has been added at i
			indices_m[#indices_m+1] = indices_m_after[i]
			metastrings[#metastrings+1] = "return nil"
		end
	end

	local changes = {
		indices_n = indices_n,
		indices_p1 = indices_p1,
		indices_p2 = indices_p2,
		indices_m = indices_m,
		nodeids = nodeids,
		param1s = param1s,
		param2s = param2s,
		metastrings = metastrings,
		-- index_bytes is needed later for compression
		index_bytes = math.ceil(math.log(worldedit.volume(pos1, pos2)) /
			math.log(0x100)),
	}
	return rvs, changes
end

undo_funcs.nodes = function(name, data)
	local pos1 = data.pos1
	local pos2 = data.pos2
	local ylen = pos2.y - pos1.y + 1
	local ystride = pos2.x - pos1.x + 1

	local decompressed_data = decompress_nodedata{
		compressed_data = data.compressed_data,
		nodeids_cnt = data.count_n,
		param1s_cnt = data.count_p1,
		param2s_cnt = data.count_p2,
		metaens_cnt = data.count_m,
		index_bytes = data.index_bytes
	}
	local indices_n = decompressed_data.indices_n
	local indices_p1 = decompressed_data.indices_p1
	local indices_p2 = decompressed_data.indices_p2
	local nodeids = decompressed_data.nodeids
	local param1s = decompressed_data.param1s
	local param2s = decompressed_data.param2s

	-- swap the nodes, param1s and param2s in the world and history data
	local manip = minetest.get_voxel_manip()
	local e1, e2 = manip:read_from_map(pos1, pos2)
	local area = VoxelArea:new{MinEdge=e1, MaxEdge=e2}
	local m_nodes = manip:get_data()
	local m_param1s = manip:get_light_data()
	local m_param2s = manip:get_param2_data()

	local mts = {m_nodes, m_param1s, m_param2s}
	local indiceses = {indices_n, indices_p1, indices_p2}
	local contentses = {nodeids, param1s, param2s}
	for mtsi = 1,3 do
		local mt = mts[mtsi]
		local indices = indiceses[mtsi]
		local contents = contentses[mtsi]
		for k = 1,#indices do
			local i = indices[k]
			local x = i % ystride
			local y = math.floor(i / ystride) % ylen
			local z = math.floor(i / (ystride * ylen))
			local vi = area:index(pos1.x + x, pos1.y + y, pos1.z + z)
			contents[k], mt[vi] = mt[vi], contents[k]
		end
	end

	manip:set_data(m_nodes)
	manip:set_light_data(m_param1s)
	manip:set_param2_data(m_param2s)
	manip:write_to_map()

	-- swap metaens strings
	local indices_m = decompressed_data.indices_m
	local metastrings = decompressed_data.metastrings
	for k = 1,#indices_m do
		local i = indices_m[k]
		local pos = vector.add(pos1, {
			x = i % ystride,
			y = math.floor(i / ystride) % ylen,
			z = math.floor(i / (ystride * ylen))
		})
		local metat, meta = get_meta_serializable(pos)
		meta = meta or minetest.get_meta(pos)
		meta:from_table(minetest.deserialize(metastrings[k]))
		metastrings[k] = minetest.serialize(metat)
	end

	-- update history entry
	data.compressed_data = compress_nodedata{
		indices_n = indices_n,
		indices_p1 = indices_p1,
		indices_p2 = indices_p2,
		indices_m = indices_m,
		nodeids = nodeids,
		param1s = param1s,
		param2s = param2s,
		metastrings = metastrings,
		index_bytes = data.index_bytes,
	}
	data.mem_usage = #data.compressed_data

	worldedit.player_notify(name, data.count_n .. " nodes set, " ..
		data.count_p1 .. " param1s set, " .. data.count_p2 ..
		" param2s set and " .. #indices_m .. " metaens changed")
end


----------------------- World changing commands --------------------------------

local function we_nodeset_wrapper(func, pos1, pos2, ...)
	assert(command_invoker, "Player not known")
	pos1, pos2 = worldedit.sort_pos(pos1, pos2)
	-- FIXME: Protection support isn't needed

	local manip = minetest.get_voxel_manip()
	local e1, e2 = manip:read_from_map(pos1, pos2)
	local area = VoxelArea:new{MinEdge=e1, MaxEdge=e2}
	local data_before = manip:get_data()

	we_data = nil
	local rv = func(pos1, pos2, ...)

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

	local index_bytes = math.ceil(math.log(worldedit.volume(pos1, pos2)) /
		math.log(0x100))
	local compressed_data = compress_nodedata{
		indices_n = indices,
		nodeids = nodeids,
		index_bytes = index_bytes,
	}
	add_to_history({
		type = "nodeids",
		mem_use = #compressed_data,
		pos1 = pos1,
		pos2 = pos2,
		count = #nodeids,
		index_bytes = index_bytes,
		compressed_data = compressed_data
	}, command_invoker)

	return rv
	-- Note: param1, param2 and metadata are not changed by worldedit.set and
	-- similar functions
end

undo_funcs.nodeids = function(name, data)
	local pos1 = data.pos1
	local pos2 = data.pos2
	local ylen = pos2.y - pos1.y + 1
	local ystride = pos2.x - pos1.x + 1

	local decompressed_data = decompress_nodedata{
		compressed_data = data.compressed_data,
		nodeids_cnt = data.count,
		index_bytes = data.index_bytes
	}
	local indices = decompressed_data.indices_n
	local nodeids = decompressed_data.nodeids

	local manip = minetest.get_voxel_manip()
	local e1, e2 = manip:read_from_map(pos1, pos2)
	local area = VoxelArea:new{MinEdge=e1, MaxEdge=e2}
	local mdata = manip:get_data()

	-- swap the nodes in the world and history data
	local new_nodeids = {}
	for k = 1,#indices do
		local i = indices[k]
		local x = i % ystride
		local y = math.floor(i / ystride) % ylen
		local z = math.floor(i / (ystride * ylen))
		local vi = area:index(pos1.x + x, pos1.y + y, pos1.z + z)
		new_nodeids[k] = mdata[vi]
		mdata[vi] = nodeids[k]
	end

	manip:set_data(mdata)
	manip:write_to_map()

	data.compressed_data = compress_nodedata{
		indices_n = indices,
		nodeids = new_nodeids,
		index_bytes = data.index_bytes
	}
	data.mem_usage = #data.compressed_data

	worldedit.player_notify(name, data.count .. " nodes set")
end
undo_info_funcs.nodeids = function(data)
	return "pos1: " .. minetest.pos_to_string(data.pos1) .. ", pos2: " ..
		minetest.pos_to_string(data.pos2) .. ", " .. data.count ..
		" nodes changed"
end

local we_set = worldedit.set
local function my_we_set(pos1, pos2, ...)
	return we_nodeset_wrapper(we_set, pos1, pos2, ...)
end
local set_cmds = {"/set", "/mix"}
for i = 1,2 do
	override_cc_with_confirm(set_cmds[i],
		function()
			worldedit.set = my_we_set
		end,
		function()
			worldedit.set = we_set
		end
	)
end

local we_replace = worldedit.replace
local function my_we_replace(pos1, pos2, ...)
	return we_nodeset_wrapper(we_replace, pos1, pos2, ...)
end
-- both commands share the same function
local replace_cmds = {"/replace", "/replaceinverse"}
for i = 1,2 do
	override_cc_with_confirm(replace_cmds[i],
		function()
			worldedit.replace = my_we_replace
		end,
		function()
			worldedit.replace = we_replace
		end
	)
end

local we_cube = worldedit.cube
local function cube_func(_,_, ...)
	return we_cube(...)
end
local function my_we_cube(pos, w, h, l, ...)
	local cw, ch, cl = math.ceil(w), math.ceil(h), math.ceil(l)
	local ox = math.ceil((cw-1)/2)
	local oz = math.ceil((cl-1)/2)
	local pos1 = {x = pos.x - ox, y = pos.y, z = pos.z - oz}
	local pos2 = {x = pos.x + ox, y = pos.y + ch - 1, z = pos.z + oz}
	return we_nodeset_wrapper(cube_func, pos1, pos2, pos, w, h, l, ...)
end
local cube_cmds = {"/cube", "/hollowcube"}
for i = 1,2 do
	override_cc_with_confirm(cube_cmds[i],
		function()
			worldedit.cube = my_we_cube
		end,
		function()
			worldedit.cube = we_cube
		end
	)
end

local we_sphere = worldedit.sphere
local function sph_func(_,_, ...)
	return we_sphere(...)
end
local function my_we_sphere(pos, radius, ...)
	local r = math.ceil(radius)
	local pos1 = vector.subtract(pos, r)
	local pos2 = vector.add(pos, r)

	return we_nodeset_wrapper(sph_func, pos1, pos2, pos, radius, ...)
end
local sphere_cmds = {"/sphere", "/hollowsphere"}
for i = 1,2 do
	override_cc_with_confirm(sphere_cmds[i],
		function()
			worldedit.sphere = my_we_sphere
		end,
		function()
			worldedit.sphere = we_sphere
		end
	)
end

local we_dome = worldedit.dome
local function dome_func(_,_, ...)
	return we_dome(...)
end
local function my_we_dome(pos, radius, ...)
	local r = math.ceil(radius)
	local pos1 = vector.subtract(pos, r)
	local pos2 = vector.add(pos, r)

	-- dome with negative radius looks different, I couldn't test it because
	-- //dome does not accept negative radii. FIXME
	assert(radius >= 0)

	-- a dome is a semi shpere, thus it's almost the same as sphere:
	-- below pos.y no nodes are set.
	pos1.y = pos.y

	return we_nodeset_wrapper(dome_func, pos1, pos2, pos, radius, ...)
end
local dome_cmds = {"/dome", "/hollowdome"}
for i = 1,2 do
	override_cc_with_confirm(dome_cmds[i],
		function()
			worldedit.dome = my_we_dome
		end,
		function()
			worldedit.dome = we_dome
		end
	)
end

local we_cylinder = worldedit.cylinder
local function cylinder_func(_,_, ...)
	return we_cylinder(...)
end
local function my_we_cylinder(pos, axis, length, radius, ...)
	local r = math.ceil(radius)
	local pos1 = vector.subtract(pos, r)
	local pos2 = vector.add(pos, r)

	assert(radius >= 0)

	pos1[axis] = pos[axis]
	pos2[axis] = pos[axis] + length - 1
	if length < 0 then
		pos1[axis], pos2[axis] = pos2[axis], pos1[axis]
		-- with negative length, the cylinder is shifted one node FIXME
		pos1[axis] = pos1[axis]-1
		pos2[axis] = pos2[axis]-1
	end

	return we_nodeset_wrapper(cylinder_func, pos1, pos2, pos, axis, length,
		radius, ...)
end
local cylinder_cmds = {"/cylinder", "/hollowcylinder"}
for i = 1,2 do
	override_cc_with_confirm(cylinder_cmds[i],
		function()
			worldedit.cylinder = my_we_cylinder
		end,
		function()
			worldedit.cylinder = we_cylinder
		end
	)
end

local we_pyramid = worldedit.pyramid
local function pyramid_func(_,_, ...)
	return we_pyramid(...)
end
local function my_we_pyramid(pos, axis, height, ...)
	local h = math.ceil(math.abs(height))
	local pos1 = vector.subtract(pos, h-1)
	local pos2 = vector.add(pos, h-1)

	if height > 0 then
		pos1[axis] = pos[axis]
	else
		pos2[axis] = pos[axis]
	end

	return we_nodeset_wrapper(pyramid_func, pos1, pos2, pos, axis, height, ...)
end
local pyramid_cmds = {"/pyramid", "/hollowpyramid"}
for i = 1,2 do
	override_cc_with_confirm(pyramid_cmds[i],
		function()
			worldedit.pyramid = my_we_pyramid
		end,
		function()
			worldedit.pyramid = we_pyramid
		end
	)
end

local we_spiral = worldedit.spiral
local function spiral_func(_,_, ...)
	return we_spiral(...)
end
local function my_we_spiral(pos, length, height, spacer, ...)
	-- FIXME adding the spacer to the extent makes it work
	local extent = math.ceil(length / 2) + spacer

	local pos1 = vector.subtract(pos, extent)
	local pos2 = vector.add(pos, extent)

	pos1.y = pos.y
	pos2.y = pos.y + math.ceil(height) - 1

	return we_nodeset_wrapper(spiral_func, pos1, pos2, pos, length, height,
		spacer, ...)
end
override_cc_with_confirm("/spiral",
	function()
		worldedit.spiral = my_we_spiral
	end,
	function()
		worldedit.spiral = we_spiral
	end
)


local we_deserialize = worldedit.deserialize
local function my_we_deserialize(pos_base, ...)
	-- remember the previous nodes and meta
	-- Collect the changes by overriding minetest.add_node since this is
	-- probably faster than loading the whole area including metadata before
	-- and after worldedit's operation
	local nodes = {}
	local metaens = {}
	local add_node = minetest.add_node
	local function my_add_node(entry)
		local current_node = minetest.get_node(entry)
		local have_changes = 3
		local def_ent = minetest.registered_nodes[entry.name]
		local def_cur = minetest.registered_nodes[current_node.name]
		if current_node.name == entry.name then
			current_node.name = nil
			have_changes = 2
		end
		if current_node.param1 == (entry.param1 or 0)
		or (def_ent and def_cur  -- don't save volatile light values or param1=0
			and (def_ent.paramtype == "light" or (entry.param1 or 0) == 0)
			and (def_cur.paramtype == "light" or current_node.param1 == 0)
		) then
			current_node.param1 = nil
			have_changes = have_changes-1
		end
		if current_node.param2 == (entry.param2 or 0) then
			current_node.param2 = nil
			have_changes = have_changes-1
		end
		local pos = {x=entry.x, y=entry.y, z=entry.z}
		-- we calls add_node always before setting any meta, save it here
		local metat = get_meta_serializable(pos)
		local new_metat = entry.meta
		if new_metat
		and is_meta_empty(new_metat) then
			-- Worldedit save files usually contain redundant metadata
			new_metat = nil
		end
		local meta_changed = (metat or new_metat)
			and (not metat or not new_metat
				or minetest.serialize(metat) ~= minetest.serialize(new_metat)
			)
		if meta_changed then
			metaens[#metaens+1] = {pos, metat}
		end

		if have_changes > 0 then
			nodes[#nodes+1] = {pos, current_node}
		elseif not meta_changed then
			-- neither nodes, nor meta has changed
			return
		end

		-- set the original functions due to on_construct and on_destruct
		minetest.add_node = add_node

		minetest.add_node(pos, entry)

		minetest.add_node = my_add_node
	end

	minetest.add_node = my_add_node

	local count = we_deserialize(pos_base, ...)

	minetest.add_node = add_node

	if #nodes == 0
	and #metaens == 0 then
		-- nothing happened
		return count
	end

	-- add nodes, param1, param2 and meta changes to history
	-- get pos1 and pos2
	local minp = vector.new((nodes[1] or metaens[1])[1])
	local maxp = vector.new(minp)
	for i = 1,#nodes do
		local pos = nodes[i][1]
		for c,v in pairs(pos) do
			if v > maxp[c] then
				maxp[c] = v
			elseif v < minp[c] then
				minp[c] = v
			end
		end
	end
	for i = 1,#metaens do
		local pos = metaens[i][1]
		for c,v in pairs(pos) do
			if v > maxp[c] then
				maxp[c] = v
			elseif v < minp[c] then
				minp[c] = v
			end
		end
	end

	-- order nodes, param1s, param2s and metaens
	local ystride = maxp.x - minp.x + 1
	local zstride = (maxp.y - minp.y + 1) * ystride
	for i = 1,#nodes do
		local rpos = vector.subtract(nodes[i][1], minp)
		nodes[i][1] = rpos.z * zstride + rpos.y * ystride + rpos.x
	end
	table.sort(nodes, function(a, b)
		return a[1] < b[1]
	end)
	local indices_n = {}
	local indices_p1 = {}
	local indices_p2 = {}
	local nodeids = {}
	local param1s = {}
	local param2s = {}
	for i = 1,#nodes do
		local v = nodes[i][2]
		local id = v.name and minetest.get_content_id(v.name)
		if id then
			indices_n[#indices_n+1] = nodes[i][1]
			nodeids[#nodeids+1] = id
		end
		if v.param1 then
			indices_p1[#indices_p1+1] = nodes[i][1]
			param1s[#param1s+1] = v.param1
		end
		if v.param2 then
			indices_p2[#indices_p2+1] = nodes[i][1]
			param2s[#param2s+1] = v.param2
		end
	end

	for i = 1,#metaens do
		local rpos = vector.subtract(metaens[i][1], minp)
		metaens[i][1] = rpos.z * zstride + rpos.y * ystride + rpos.x
	end
	table.sort(metaens, function(a, b)
		return a[1] < b[1]
	end)
	local indices_m = {}
	local metastrings = {}
	for i = 1,#metaens do
		indices_m[i] = metaens[i][1]
		metastrings[i] = minetest.serialize(metaens[i][2])
	end

	-- compress the data and add it to history
	local index_bytes = math.ceil(math.log(worldedit.volume(minp, maxp)) /
		math.log(0x100))
	local compressed_data = compress_nodedata{
		indices_n = indices_n,
		indices_p1 = indices_p1,
		indices_p2 = indices_p2,
		indices_m = indices_m,
		nodeids = nodeids,
		param1s = param1s,
		param2s = param2s,
		metastrings = metastrings,
		index_bytes = index_bytes,
	}
	add_to_history({
		type = "nodes",
		mem_use = #compressed_data,
		pos1 = minp,
		pos2 = maxp,
		count_n = #nodeids,
		count_p1 = #param1s,
		count_p2 = #param2s,
		count_m = #metastrings,
		index_bytes = index_bytes,
		compressed_data = compressed_data
	}, command_invoker)

	return count
end
override_cc_with_confirm("/load",
	function()
		worldedit.deserialize = my_we_deserialize
	end,
	function()
		worldedit.deserialize = we_deserialize
	end
)


local original_place_schematic = minetest.place_schematic
local function my_place_schematic(pos, schematic_path, rotation, replacements,
		force_placement, flags)
	-- Get the area which is changed by the schematic
	if rotation then
		minetest.log("error",
			"Received a rotation from worldedit's schematic placement; " ..
			"not yet implemented in we_undo")
	end
	if flags then
		minetest.log("error",
			"Received flags from worldedit's schematic placement; " ..
			"not yet implemented in we_undo")
	end
	local schem = minetest.read_schematic(schematic_path, {})
	local pos1 = pos
	local pos2 = vector.subtract(vector.add(pos1, schem.size), 1)

	-- Note: schematic placement doesn't change the metadata
	local rvs, changes = run_and_capture_changes(function()
			-- Do the schematic placement
			return original_place_schematic(pos, schematic_path, rotation,
				replacements, force_placement, flags)
		end, pos1, pos2, false)

	-- Compress the collected changes and add it to history
	local compressed_data = compress_nodedata(changes)
	add_to_history({
		type = "nodes",
		mem_use = #compressed_data,
		pos1 = pos1,
		pos2 = pos2,
		count_n = #changes.nodeids,
		count_p1 = #changes.param1s,
		count_p2 = #changes.param2s,
		count_m = 0,
		index_bytes = changes.index_bytes,
		compressed_data = compressed_data
	}, command_invoker)

	return unpack(rvs)
end
override_cc_with_confirm("/mtschemplace",
	function()
		minetest.place_schematic = my_place_schematic
	end,
	function()
		minetest.place_schematic = original_place_schematic
	end
)


local we_luatransform = worldedit.luatransform
local function my_luatransform(pos1_actual, pos2_actual, code)
	local pos1_further, pos2_further = worldedit.sort_pos(pos1_actual,
		pos2_actual)
	-- For safety, add a bit extra space since players can do arbitrary
	-- things at arbitrary positions with luatransform
	pos1_further = vector.subtract(pos1_further, 5)
	pos2_further = vector.add(pos2_further, 5)

	-- Use the generic (but not necessarily fast) function to capture the
	-- changes
	local rvs, changes = run_and_capture_changes(function()
			return we_luatransform(pos1_actual, pos2_actual, code)
		end, pos1_further, pos2_further, true)

	-- Compress the collected changes and add it to history
	local compressed_data = compress_nodedata(changes)
	add_to_history({
		type = "nodes",
		mem_use = #compressed_data,
		pos1 = pos1_further,
		pos2 = pos2_further,
		count_n = #changes.nodeids,
		count_p1 = #changes.param1s,
		count_p2 = #changes.param2s,
		count_m = 0,
		index_bytes = changes.index_bytes,
		compressed_data = compressed_data
	}, command_invoker)

	return unpack(rvs)
end
override_cc_with_confirm("/luatransform",
	function()
		worldedit.luatransform = my_luatransform
	end,
	function()
		worldedit.luatransform = we_luatransform
	end
)
