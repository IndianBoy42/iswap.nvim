local util = require('iswap.util')
local internal = require('iswap.internal')
local ui = require('iswap.ui')
local err = util.err

local function autoswap(config, iters)
  if config.autoswap == true or config.autoswap == "always" then return true end
  if config.autoswap == nil or config.autoswap == false then return false end
  if config.autoswap == "after_label" then return iters ~= 1 end
end

local function ranges(parent, children, ...)
  return { { parent:range() }, vim.tbl_map(function(child) return { child:range() } end, children), ... }
end

-- merge all nodes from cur_idx:last_idx into one and return the new children array
-- the merged node will be at children[cur_idx]
local function merge_nodes(children, cur_idx, last_idx)
  -- TODO: performance improvements?
  local nodes = vim.list_slice(children, cur_idx + 1, last_idx)
  local merged = children[cur_idx]
  for _, child in ipairs(nodes) do
    merged = util.merge(merged, child)
  end
  local pre, post = vim.list_slice(children, 1, cur_idx - 1), vim.list_slice(children, last_idx + 1)
  return util.join_lists { pre, { merged }, post }
end

local function is_ctrl_key(k) return k:sub(1, 2) == '<C' end
local sticky_modes = {
  [false] = function() return false end,
  [true] = function() return true end,
  on_ctrl = function(_, k, _) return is_ctrl_key(k) end,
}
local subnode_modes = {
  [false] = function() return false end,
  [true] = function() return true end,
  on_ctrl = function(k, i) return is_ctrl_key(k) end,
}

local last_list_index = 1
local function choose(config, callback)
  local direction = config.direction
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local select_two_nodes = direction == 2

  local iters = 0

  local lists, list_index = nil, 1
  if config.all_nodes then
    if type(config.all_nodes) == 'function' then
      lists, list_index = config.all_nodes(direction, config)
      if list_index == nil then list_index = 1 end
    else
      lists, _, list_index = internal.get_ancestors_at_cursor(config.only_current_line, config, not select_two_nodes)
    end
  else
    lists = internal.get_list_nodes_at_cursor(winid, config, not select_two_nodes)
    list_index = 1
  end
  if not lists then return end
  lists = vim.tbl_map(function(list) return ranges(unpack(list)) end, lists)
  local parents = vim.tbl_map(function(list) return list[1] end, lists)
  local incremental_mode, sticky_mode = false, config.sticky == true
  local sticky_callback = type(config.sticky) == 'function' and config.sticky or sticky_modes[config.sticky]
  local subnodes_callback = type(config.subnodes) == 'function' and config.subnodes or subnode_modes[config.subnodes]
  local subnode = util.get_cursor_range(winid, config.mode)
  if #subnode == 2 then subnode = nil end

  if config.is_repeat then list_index = last_list_index > #lists and 1 or last_list_index end

  while true do
    iters = iters + 1
    -- TODO: handle multiple cur_nodes
    local parent, children, cur_idx, last_idx = unpack(lists[list_index])
    if last_idx then
      children = merge_nodes(children, cur_idx, last_idx)
      lists[list_index] = { parent, children, cur_idx }
    end

    if subnode then
      -- TODO: map the children array down to corresponding subnodes
      -- TODO: filter out the parents that are smaller than subnode
      -- children = internal.find_subnodes_of_nodes(children, subnode, cur_idx)
    end

    local sr, sc, er, ec = unpack(parent)

    -- a and b are the nodes to swap
    local swap_node_idx

    local function increment(dir)
      swap_node_idx = cur_idx + dir
      while swap_node_idx > #children do
        swap_node_idx = swap_node_idx - #children
      end
      while swap_node_idx < 1 do
        swap_node_idx = swap_node_idx + #children
      end
    end
    if direction == 'right' then
      increment(vim.v.count1)
    elseif direction == 'left' then
      increment(-vim.v.count1)
    else
      local removed
      if not select_two_nodes then removed = table.remove(children, cur_idx) end

      if autoswap(config, iters) and #children == 1 then
        swap_node_idx = 1
      else
        local function increment_swap(dir)
          table.insert(children, cur_idx, removed)
          incremental_mode = true
          increment(dir * vim.v.count1)
          local swapped = callback(children, swap_node_idx, cur_idx)
          children[cur_idx] = swapped[1]
          children[swap_node_idx] = swapped[2]
          lists[list_index][3] = swap_node_idx
          cur_idx = swap_node_idx
          -- FIXME: this might be glitchy if user changes parent
          -- specifically to a smaller parent: need to recompute cur_idx
          -- maybe remove all labels after doing an incremental swap?
          -- is there any reason to use labels after an incremental swap?
          -- it would be nice if any other key would be fed to the main neovim loop so we don't even have to hit <esc>
        end

        local children_and_parents, parents_after
        if incremental_mode then
          children_and_parents, parents_after = { removed }, 2
        else
          children_and_parents = config.label_parents and util.join_lists { children, parents } or children
          parents_after = #children
        end
        local times = select_two_nodes and 2 or 1

        local user_input, user_keys =
          ui.prompt(bufnr, config, children_and_parents, { { sr, sc }, { er, ec } }, times, parents_after)
        -- TODO: select multiple initial nodes when select_two_nodes
        if not (type(user_input) == 'table' and #user_input >= 1) then
          if user_keys then
            local inp = user_keys[2] or user_keys[1]
            if inp == config.expand_key then
              list_index = list_index + 1
              goto insert_continue
            end
            if inp == config.shrink_key then
              list_index = list_index - 1
              goto insert_continue
            end
            if not select_two_nodes then
              -- TODO: incr but actually swap not move
              if inp == config.incr_left_key then
                increment_swap(-1)
                goto continue
              end
              if inp == config.incr_right_key then
                increment_swap(1)
                goto continue
              end
            end
          end
          err('did not get valid user inputs', config.debug)
          return
        end
        if incremental_mode then return end

        local a, b = user_input[1], user_input[2]
        for i, k in ipairs(user_keys) do
          local s = sticky_callback and sticky_callback(sticky_mode, k, i)
          if s ~= nil then sticky_mode = s end
        end

        if (a and a > #children) or (b and b > #children) then
          list_index = (a > #children and a or b) - #children
          if not select_two_nodes then
            local s = subnodes_callback
              and subnodes_callback(a > #children and user_keys[1] or user_keys[2], list_index)
            if s then subnode = removed end
          end
          goto insert_continue
        end

        if select_two_nodes then
          swap_node_idx = b
          cur_idx = a
        else
          swap_node_idx = a
        end
      end

      ::insert_continue::
      if not select_two_nodes then
        table.insert(children, cur_idx, removed)
        if swap_node_idx and cur_idx <= swap_node_idx then swap_node_idx = swap_node_idx + 1 end
      end
    end

    if children[swap_node_idx] ~= nil then
      last_list_index = list_index
      callback(children, swap_node_idx, cur_idx, subnode)
      if not sticky_mode then return end
    else
      err('no node to swap with', config.debug)
    end

    ::continue::
    if list_index < 1 then list_index = #lists end
    if list_index > #lists then list_index = 1 end
    vim.api.nvim_win_set_cursor(winid, cursor)
    vim.cmd.redraw()
  end
end

return choose
