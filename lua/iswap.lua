local queries = require('nvim-treesitter.query')
local ui = require('iswap.ui')
local internal = require('iswap.internal')
local default_config = require('iswap.defaults')
local choose = require('iswap.choose')

local M = {}

M.config = default_config

function M.setup(config)
  config = config or {}
  M.config = setmetatable(config, { __index = default_config })
end

function M.evaluate_config(config, parent)
  parent = parent or M.config
  config = config and setmetatable(config, { __index = parent }) or vim.deepcopy(parent)
  return config
end

function M.init()
  require('nvim-treesitter').define_modules {
    iswap = {
      module_path = 'iswap.internal',
      is_supported = function(lang) return queries.get_query(lang, 'iswap-list') ~= nil end,
    },
  }

  local cmds = {
    { '', {} },
    { 'Two', { direction = 2 } },
    { 'Right', { direction = 'right' } },
    { 'Left', { direction = 'left' } },
    { 'List', { all_nodes = false } },
    { 'ListTwo', { all_nodes = false, direction = 2 } },
    { 'ListRight', { all_nodes = false, direction = 'right' } },
    { 'ListLeft', { all_nodes = false, direction = 'left' } },
  }
  for _, cmdkind in ipairs { 'Swap', 'Move' } do
    local f = M[cmdkind:lower()]
    for _, v in ipairs(cmds) do
      local suff, opts = unpack(v)

      local cmd = 'I' .. cmdkind .. suff
      -- vim.cmd('command ' .. cmd .. " lua require'iswap'." .. rhs)
      M.cmd(cmd, f, opts, { desc = cmd })
      M.map({ 'n', 'x' }, '<Plug>(' .. cmd .. ')', f, opts, { desc = cmd })
    end
    -- map({ 'n', 'x' }, '<Plug>(' .. cmd .. ')', cb, { desc = cmd })
  end
end

function M.mapping(fn, config)
  config = config or {}
  -- Everything outside of the operatorfunc should not get run on repeat
  config.is_repeat = false
  M.__operatorfunc = function()
    fn(config)
    config.is_repeat = true
  end
  vim.go.operatorfunc = "v:lua.require'iswap'.__operatorfunc"

  config.mode = vim.api.nvim_get_mode().mode

  if config.mode == 'n' and not config.use_operator then
    return 'g@l'
  else
    return 'g@'
  end
end
function M.feedkeys_mapping(fn, config) vim.api.nvim_feedkeys(M.mapping(fn, config), 'n', false) end
M.rhs = {
  swap = function(config) vim.api.nvim_feedkeys(M.mapping('swap', config), 'n', false) end,
  move = function(config) vim.api.nvim_feedkeys(M.mapping('move', config), 'n', false) end,
}

function M.map(mode, lhs, fn, config, opts)
  config = config or {}
  opts = opts or {}
  opts.expr = true
  vim.keymap.set(mode, lhs, function() return M.mapping(fn, config) end, opts)
end
function M.cmd(cmd, fn, config, opts)
  vim.api.nvim_create_user_command(cmd, function() vim.api.nvim_feedkeys(M.mapping(fn, config), 'n', false) end, opts)
end

function M.swap(config)
  config = M.evaluate_config(config)
  local bufnr = vim.api.nvim_get_current_buf()

  choose(config, function(children, b_idx, a_idx)
    local ranges = internal.swap_ranges_in_place(children, a_idx, b_idx, config.move_cursor)

    ui.flash_confirm(bufnr, ranges, config)

    return ranges
  end)
end
function M.move(config)
  config = M.evaluate_config(config)
  local bufnr = vim.api.nvim_get_current_buf()

  choose(config, function(children, b_idx, a_idx)
    local ranges = internal.move_range_in_place(children, a_idx, b_idx, config.move_cursor)

    ui.flash_confirm(bufnr, ranges, config)

    return ranges
  end)
end

return M
