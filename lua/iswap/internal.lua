local ts_utils = require('nvim-treesitter.ts_utils')
local ts = vim.treesitter
local queries = require('nvim-treesitter.query')
local util = require('iswap.util')
local err = util.err
local api = vim.api

local ft_to_lang = require('nvim-treesitter.parsers').ft_to_lang

local M = {}

-- certain lines of code below are taken from nvim-treesitter where i
-- had to modify the function body of an existing function in ts_utils

--
function M.find(cursor_range)
  local bufnr = api.nvim_get_current_buf()
  local sr, er = cursor_range[1], cursor_range[3]
  er = (er and (er + 1)) or (sr + 1)
  -- local root = ts_utils.get_root_for_position(unpack(cursor_range))
  -- NOTE: this root is freshly parsed, but this may not be the best way of getting a fresh parse
  --       see :h Query:iter_captures()
  local ft = vim.bo[bufnr].filetype
  local root = ts.get_parser(bufnr, ft_to_lang(ft)):parse()[1]:root()
  local q = queries.get_query(ft_to_lang(ft), 'iswap-list')
  -- TODO: initialize correctly so that :ISwap is not callable on unsupported
  -- languages, if that's possible.
  if not q then
    err('Cannot query this filetype', true)
    return
  end
  return q:iter_captures(root, bufnr, sr, er)
end

local function filter_ancestor(ancestor, config, cursor_range, lists)
  local parent = ancestor:parent()
  if parent == nil then
    err('No parent found for swap', config.debug)
    return
  end

  local children = ts_utils.get_named_children(parent)
  if #children < 2 then
    err('No siblings found for swap', config.debug)
    return
  end

  -- TODO: filter out comment nodes,
  -- unless theyre in the visual range,
  -- or have to be moved through,
  -- needs design
  -- comment nodes could be assumed to be a part of the following node
  -- children = vim.tbl_filter(config.ignore_nodes, children)

  local cur_nodes = util.nodes_intersecting_range(children, cursor_range)
  if #cur_nodes >= 1 then
    if #cur_nodes > 1 then
      if config.debug then
        err('multiple found, merging', true)
        local first = cur_nodes[1]
        for i, id in ipairs(cur_nodes) do
          if id ~= first + i - 1 then
            err('multiple nodes are not contiguous, there should be no way for this to happen', true)
          end
        end
      end
      cur_nodes = { cur_nodes[1], cur_nodes[#cur_nodes] }
    end
    lists[#lists + 1] = { parent, children, unpack(cur_nodes) }
  else
    lists[#lists + 1] = { parent, children, 1 }
  end
end

-- Returns ancestors from inside to outside
function M.get_ancestors_at_cursor(only_current_line, config, needs_cursor_node)
  local winid = api.nvim_get_current_win()
  local cursor_range = util.get_cursor_range(winid)
  local cur_node = ts.get_node {
    pos = { cursor_range[1], cursor_range[2] },
  }
  if cur_node == nil then return end
  local parent = cur_node -- :parent()
  -- TODO: this is not perfect for selecting across comment nodes
  if parent:type() == 'comment' then
    cur_node = ts.get_node {
      pos = { cursor_range[3], cursor_range[4] },
    }
    if cur_node == nil then return end
    parent = cur_node
  end

  if not parent then
    err('did not find a satisfiable parent node', config.debug)
    return
  end

  -- pick parent recursive for current line
  local ancestors = { cur_node }
  local prev_parent = cur_node
  local current_row = parent:start()
  local last_row, last_col

  while parent and (not only_current_line or parent:start() == current_row) do
    last_row, last_col = prev_parent:start()
    local s_row, s_col = parent:start()

    if last_row == s_row and last_col == s_col then
      -- new parent has same start as last one. Override last one
      if util.has_siblings(parent) and parent:type() ~= 'comment' then
        -- only add if it has >0 siblings and is not comment node
        -- (override previous since same start position)
        ancestors[#ancestors] = parent
      end
    else
      table.insert(ancestors, parent)
      last_row = s_row
      last_col = s_col
    end
    prev_parent = parent
    parent = parent:parent()
  end

  local lists = {}
  for _, ancestor in ipairs(ancestors) do
    filter_ancestor(ancestor, config, cursor_range, lists)
  end

  -- FIXME: has some bugs when moving multiple nodes
  local initial = 1
  local list_nodes = M.get_list_nodes_at_cursor(winid, config, needs_cursor_node)
  if list_nodes and #list_nodes >= 1 then
    for j, list in ipairs(lists) do
      if list[1] and list[1] == list_nodes[1][1] then
        initial = j
        err('found list ancestor', config.debug)
      end
    end
  end

  return lists, last_row, initial
end

-- returns list_nodes
function M.get_list_nodes_at_cursor(winid, config, needs_cursor_node)
  local cursor_range = util.get_cursor_range(winid)
  local visual_sel = #cursor_range > 2

  local ret = {}
  local iswap_list_captures = M.find(cursor_range)
  if not iswap_list_captures then
    -- query not supported
    return
  end

  for id, node, metadata in iswap_list_captures do
    err('found node', config.debug)
    if util.node_intersects_range(node, cursor_range) and node:named_child_count() > 1 then
      local children = ts_utils.get_named_children(node)
      if needs_cursor_node then
        local cur_nodes = util.nodes_intersecting_range(children, cursor_range)
        if #cur_nodes >= 1 then
          if #cur_nodes > 1 then err('multiple found, using first', config.debug) end
          ret[#ret + 1] = { node, children, unpack(cur_nodes) }
        end
      else
        local r = { node, children }
        if visual_sel and config.visual_select_list then
          if
            util.node_is_range(node, cursor_range)
            or #util.range_containing_nodes(children, cursor_range) == #children
          then
            -- The visual selection is equivalent to the list
            ret[#ret + 1] = r
          end
        else
          ret[#ret + 1] = r
        end
      end
    end
  end
  if not (not needs_cursor_node and visual_sel and config.visual_select_list) then util.tbl_reverse(ret) end
  err('completed', config.debug)
  return ret
end

local get_range_text = function(range, buf)
  local start_row, start_col, end_row, end_col = unpack(range)
  if end_col == 0 then
    if start_row == end_row then
      start_col = -1
      start_row = start_row - 1
    end
    end_col = -1
    end_row = end_row - 1
  end
  local lines = api.nvim_buf_get_text(buf, start_row, start_col, end_row, end_col, {})
  return lines
end

local ns_id = api.nvim_create_namespace('ISwap')
local function setmark(bufnr, pos, id, start)
  api.nvim_buf_set_extmark(bufnr, ns_id, pos.line, pos.character, {
    id = id,
    right_gravity = not start,
  })
end
local function node_to_lsp_range(node)
  local start_line, start_col, end_line, end_col = ts.get_node_range(node)
  local rtn = {}
  rtn.start = { line = start_line, character = start_col }
  rtn['end'] = { line = end_line, character = end_col }
  return rtn
end

local function getmarks(bufnr)
  local marks = {}
  for _, mark in
    ipairs(api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {
      details = true,
    }))
  do
    marks[mark[1]] = { mark[2], mark[3] }
  end
  return marks
end

-- node 'a' is the one the cursor is on
function M.swap_ranges(a, b, should_move_cursor)
  if not a or not b then return end
  local bufnr = api.nvim_get_current_buf()
  local winid = api.nvim_get_current_win()
  local range1 = node_to_lsp_range(a)
  local range2 = node_to_lsp_range(b)

  local cursor_delta
  if should_move_cursor then
    local cursor = api.nvim_win_get_cursor(winid)
    local c_r, c_c = cursor[1] - 1, cursor[2]
    cursor_delta = { c_r - range1.start.line, c_c - range1.start.character }
  end

  setmark(bufnr, range1.start, 1, true)
  setmark(bufnr, range1['end'], 2, false)
  setmark(bufnr, range2.start, 3, true)
  setmark(bufnr, range2['end'], 4, false)

  local text1 = get_range_text(a, bufnr)
  local text2 = get_range_text(b, bufnr)

  local edit1 = { range = range1, newText = table.concat(text2, '\n') }
  local edit2 = { range = range2, newText = table.concat(text1, '\n') }
  vim.lsp.util.apply_text_edits({ edit1, edit2 }, bufnr, 'utf-8')

  local marks = getmarks(bufnr)

  api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  if should_move_cursor then
    vim.cmd("normal! m'")

    api.nvim_win_set_cursor(
      api.nvim_get_current_win(),
      { marks[3][1] + 1 + cursor_delta[1], marks[3][2] + cursor_delta[2] }
    )
  end

  return {
    { marks[1][1], marks[1][2], marks[2][1], marks[2][2] },
    { marks[3][1], marks[3][2], marks[4][1], marks[4][2] },
  }
end

function M.move_range(children, cur_node_idx, a_idx, should_move_cursor)
  if a_idx == cur_node_idx + 1 or a_idx == cur_node_idx - 1 then
    -- This means the node is adjacent, swap and move are equivalent
    return M.swap_ranges(children[cur_node_idx], children[a_idx], should_move_cursor)
  end

  local cur_range = children[cur_node_idx]

  local incr = (cur_node_idx < a_idx) and 1 or -1
  for i = cur_node_idx + incr, a_idx, incr do
    local _, b_range = unpack(M.swap_ranges(cur_range, children[i], should_move_cursor))
    cur_range = b_range
  end

  return { cur_range }
end
function M.move_range_in_place(children, cur_node_idx, a_idx, should_move_cursor)
  if a_idx == cur_node_idx + 1 or a_idx == cur_node_idx - 1 then
    -- This means the node is adjacent, swap and move are equivalent
    return M.swap_ranges_in_place(children, cur_node_idx, a_idx, should_move_cursor)
  end

  local flash_range = children[cur_node_idx]

  local incr = (cur_node_idx < a_idx) and 1 or -1
  for i = cur_node_idx + incr, a_idx, incr do
    local _, b_range = unpack(M.swap_ranges_in_place(children, cur_node_idx, i, should_move_cursor))
    cur_node_idx = i
    flash_range = b_range
  end

  return { flash_range }
end

function M.swap_ranges_in_place(children, a_idx, b_idx, should_move_cursor)
  local swapped = M.swap_ranges(children[a_idx], children[b_idx], should_move_cursor)
  children[a_idx] = swapped[1]
  children[b_idx] = swapped[2]
  return swapped
end

local function field_of_node(node)
  local parent = node:parent()
  if parent == nil then return nil end
  local i = 1
  for child, field in parent:iter_children() do
    if child == node then return field or i, parent end
    i = i + 1
  end
end
local function child_from_field(parent, field)
  if type(field) == 'number' then
    return parent:child(field)
  else
    return parent:field(field)
  end
end
local function recursive_field_of_node_to(node, final)
  local fields = {}
  while true do
    local field, parent = field_of_node(node)
    if field == nil then return false, fields end
    fields[#fields + 1] = field
    if parent == final then return true, fields end
  end
end
local function child_from_fields(parent, fields)
  local child = parent
  for _, field in pairs(fields) do
    local ch = child_from_field(parent, field)
    if ch == nil then
      return child
    else
      child = ch
    end
  end
  return child
end

function M.find_subnodes_of_nodes(children, subnode, cur_idx)
  local tssubnode = ts.get_node { pos = subnode }
  if not tssubnode then return children end

  local curnode = children[cur_idx]
  local tscurnode = ts.get_node { pos = curnode }
  if not tscurnode then return children end

  -- TODO: find f(curnode) == subnode
  local fields = recursive_field_of_node_to(tssubnode, curnode)
  if not fields then
    err('Could not compute subnode address')
    return children
  end

  local nodes = {}
  for i, node in pairs(children) do
    if i == cur_idx then
      nodes[i] = { tssubnode:range() }
    else
      local chnode = ts.get_node { pos = node }
      -- TODO: find f(chnode)
      local sub = child_from_fields(chnode, fields)
      nodes[i] = { sub:range() }
    end
  end
  return nodes
end

function M.attach(bufnr, lang)
  -- TODO: Fill this with what you need to do when attaching to a buffer
end

function M.detach(bufnr)
  -- TODO: Fill this with what you need to do when detaching from a buffer
end

return M
