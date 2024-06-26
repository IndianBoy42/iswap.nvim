local M = {}

local keystr = 'asdfghjklqwertyuiopzxcvbnm'
M.keys = keystr .. keystr:upper()
M.hl_grey = 'Comment'
M.hl_snipe = 'Search'
M.hl_parent = 'Substitute'
M.label_snipe_style = 'inline'
M.label_parent_style = 'inline'
M.hl_selection = 'Visual'
M.flash_style = 'sequential'
M.hl_flash = 'IncSearch'
M.hl_grey_priority = 1000
M.grey = 'enable'
M.expand_key = ';'
M.shrink_key = ','
M.incr_right_key = ')'
M.incr_left_key = '('
M.autoswap = false
M.only_current_line = true
M.visual_select_list = true
M.label_parents = true
M.all_nodes = true
M.move_cursor = false
M.direction = 1 ---@type 1|2|'right'|'left'
M.ignore_nodes = function(node) return node:type() ~= 'comment' end
M.sticky = 'on_ctrl' ---@type false|'on_ctrl'|true|function

return M
