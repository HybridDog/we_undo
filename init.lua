

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

-- Punch before the /p command's punch
table.insert(minetest.registered_on_punchnodes, 1, function(_,_, player)
	local name = player:get_player_name()
	local typ = worldedit.set_pos[name]
	if typ == "pos1"
	or typ == "pos1only" then
		add_to_history({
			type = "marker",
			mem_use = 9 * 7,
			id = 1,
			pos = worldedit.pos1[name]
		}, name)
	elseif typ == "pos2" then
		add_to_history({
			type = "marker",
			mem_use = 9 * 7,
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
	local data = {}
	-- put indices first
	for j = 1,#indic_names do
		local indices = nodedata[indic_names[j]]
		if indices then
			local prev_index = 0
			for i = 1,#indices do
				local index = indices[i]
				local off = index - prev_index -- always > 0
				local v = ""
				for f = nodedata.index_bytes, 0, -1 do
					v = v .. string.char(math.floor(off * 2^(-8*f)) % 0x100)
					data[#data+1] = v
				end
				prev_index = index
			end
		end
	end
	-- nodeids contain 16 bit values (see mapnode.h)
	-- big endian here
	if nodedata.indices_n then
		for i = 1,#nodedata.nodeids do
			data[#data+1] = string.char(math.floor(nodedata.nodeids[i] * 2^-8)
				) .. string.char(nodedata.nodeids[i] % 0x100)
		end
	end
	-- param1 and param2 are 4 bit values
	for j = 1,2 do
		if nodedata["indices_p" .. j] then
			local vs = nodedata["param" .. j .. "s"]
			local bytescnt = math.ceil(#vs / 2)
			for i = 1,bytescnt do
				-- put two values in one byte
				local v = vs[2 * i - 1] * 0x10 + (vs[2 * i] or 0)
				data[#data+1] = string.char(v)
			end
		end
	end
	-- meta…
	if nodedata.indices_m then
		data[#data+1] = minetest.serialize(nodedata.metastrings)
	end
	return minetest.compress(table.concat(data))
end

local cnt_names = {"nodeids_cnt", "param1s_cnt", "param2s_cnt", "metaens_cnt"}
local function decompress_nodedata(ccontent)
	local result = {}
	local data = minetest.decompress(ccontent.compressed_data)
print("daacnt: "..#data)
	local p = 1
	-- get indices
	for i = 1,#cnt_names do
		local cnt = ccontent[cnt_names[i]]
		if cnt then
print("cntnam: "..cnt_names[i])
			local indices = {}
			local prev_index = 0
			for i = 1,cnt do
				local v = prev_index
				for f = ccontent.index_bytes, 0, -1 do
					v = v + 2^(8*f) * data:byte(p)
					p = p+1
				end
				indices[i] = v
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
			local bytescnt = math.ceil(cnt / 2)
			for i = 1,bytescnt do
				local v = data:byte(p)
				p = p+1
				vs[2 * i - 1] = math.floor(v / 0x10)
				if 2 * i <= cnt then
					vs[2 * i] = v % 0x10
				end
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

local we_set = worldedit.set
local function my_we_set(pos1, pos2, ...)
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

	-- can be 0 if only one node is changed
	local index_bytes = math.ceil(math.log(worldedit.volume(pos1, pos2)) /
		math.log(8))
	local compressed_data = compress_nodedata{
		indices_n = indices,
		nodeids = nodeids,
		index_bytes = index_bytes,
	}
	add_to_history({
		type = "nodeids",
		mem_use = 9 * (2 * 7) + #compressed_data,
		pos1 = pos1,
		pos2 = pos2,
		count = #nodeids,
		index_bytes = index_bytes,
		compressed_data = compressed_data
	}, command_invoker)
	-- Note: param1, param2 and metadata are not changed by worldedit.set
print("compressed_l: " .. #compressed_data .. ", count: " .. #nodeids)
	return rv
end
override_cc_with_confirm("/set",
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

print("decomp_bef, count: " .. data.count .. ", compl: " .. #data.compressed_data)
	local decompressed_data = decompress_nodedata{
		compressed_data = data.compressed_data,
		nodeids_cnt = data.count,
		index_bytes = data.index_bytes
	}
	local indices = decompressed_data.indices_n
	local nodeids = decompressed_data.nodeids
print("decomp, indicesc: " .. #indices .. ", nodids: " .. #nodeids)

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
		indices = indices,
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


-- tells if the metadata is that dummy
local function is_meta_empty(metatabl)
	for _, inventory in pairs(metatabl.inventory) do
		if next(inventory) then
			return false
		end
	end
	for k in pairs(metatabl) do
		if k ~= "inventory" then
			return false
		end
	end
	return true
end

local we_deserialize = worldedit.deserialize
local function my_we_deserialize(pos, ...)
	-- remember the previous nodes and meta
	local nodes = {}
	local metaens = {}
	local removed_metaps = {}
	local add_node = minetest.add_node
	local get_meta = minetest.get_meta
	function minetest.add_node(entry)
		local current_node = minetest.get_node(entry)
		local have_changes = 3
		if current_node.name == entry.name then
			current_node.name = nil
			have_changes = 2
		end
		if current_node.param1 == (entry.param1 or 0) then
			current_node.param1 = nil
			have_changes = have_changes-1
		end
		if current_node.param2 == (entry.param2 or 0) then
			current_node.param2 = nil
			have_changes = have_changes-1
		end
		if have_changes == 0 then
			return
		end
		local pos = {x=entry.x, y=entry.y, z=entry.z}
		nodes[#nodes+1] = {pos, current_node}
		-- add_node removes meta, save it here
		local metat = get_meta(pos):to_table()
		if not is_meta_empty(metat) then
			metaens[#metaens+1] = {pos, metat}
			removed_metaps[minetest.hash_node_position(pos)] = #metaens
		end
		return add_node(pos, entry)
	end

	local current_pos
	local function fakemeta_from_table(_, metat)
		if is_meta_empty(metat) then
			-- FIXME Setting an empty meta does the same as setting no meta here
			return
		end
		local meta = get_meta(current_pos)
		local current_metat = meta:to_table()
		if is_meta_empty(current_metat) then
			-- do not save a dummy table
			current_metat = nil
		elseif minetest.serialize(metat) == minetest.serialize(current_metat)
		then
			-- the new meta and old one are apparently the same (untested)
			return
		end
		meta:from_table(metat)
		-- save the previous meta if it's not already saved by node removal
		if not removed_metaps[minetest.hash_node_position(current_pos)] then
			metaens[#metaens+1] = {current_pos, current_metat}
		end
	end
	function minetest.get_meta(pos)
		current_pos = pos
		return {from_table = fakemeta_from_table}
	end

	local count = we_deserialize(pos, ...)

	minetest.add_node = add_node
	minetest.get_meta = get_meta

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
		local id = nodes[i].name and minetest.get_content_id(nodes[id].name)
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
		math.log(8))
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
		mem_use = 9 * (2 * 7) + #compressed_data,
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
		worldedit.set = we_deserialize
	end
)

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
	m_nodes = manip:get_data()
	m_param1s = manip:get_light_data()
	m_param2s = manip:get_param2_data()

	local mts = {m_nodes, m_param1s, m_param2s}
	local indiceses = {indices_n, indices_p1, indices_p2}
	local contentses = {nodeids, param1s, param2s}
	for i = 1,3 do
		local mt = mts[i]
		local indices = indiceses[i]
		local contents = contentses[i]
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
		local meta = minetest.get_meta{
			x = i % ystride,
			y = math.floor(i / ystride) % ylen,
			z = math.floor(i / (ystride * ylen))
		}
		local metat = meta:to_table()
		if is_meta_empty(metat) then
			metat = nil
		end
		meta:from_table(minetest.deserialize(metastrings[i]))
		metastrings[i] = minetest.serialize(metat)
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
		" param2s set and " .. #indices_m .. "")
end
