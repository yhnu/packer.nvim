local api  = vim.api
local log  = require('packer/log')
local util = require('packer/util')
local a    = require('packer/async')

local display = {}
local config = {
  keymaps = {
    -- TODO: Keymap to show output
    { 'n', 'q', '<cmd>lua require"packer/display".quit()<cr>', { nowait = true, silent = true } },
    { 'n', '<cr>', '<cmd>lua require"packer/display".toggle_info()<cr>', { nowait = true, silent = true } }
  }
}

local display_mt = {
  task_start = vim.schedule_wrap(function(self, plugin, message)
    if not api.nvim_buf_is_valid(self.buf) then
      return
    end

    display.status.running = true
    api.nvim_buf_set_lines(
      self.buf,
      config.header_lines,
      config.header_lines,
      true,
      { vim.fn.printf('%s %s: %s', config.working_sym, plugin, message) }
    )
    self.marks[plugin] = api.nvim_buf_set_extmark(self.buf, self.ns, 0, config.header_lines, 0, {})
  end),

  decrement_headline_count = vim.schedule_wrap(function(self)
    if not api.nvim_win_is_valid(self.win) then
      return
    end

    local cursor_pos = api.nvim_win_get_cursor(self.win)
    api.nvim_win_set_cursor(self.win, {1, 0})
    vim.fn.execute('normal! ')
    api.nvim_win_set_cursor(self.win, cursor_pos)
  end),

  task_succeeded = vim.schedule_wrap(function(self, plugin, message)
    if not api.nvim_buf_is_valid(self.buf) then
      return
    end

    local line, _ = api.nvim_buf_get_extmark_by_id(self.buf, self.ns, self.marks[plugin])
    api.nvim_buf_set_lines(
      self.buf,
      line[1],
      line[1] + 1,
      true,
      { vim.fn.printf('%s %s: %s', config.done_sym, plugin, message) }
    )
    api.nvim_buf_del_extmark(self.buf, self.ns, self.marks[plugin])
    self.marks[plugin] = nil
    self:decrement_headline_count()
  end),

  task_failed = vim.schedule_wrap(function(self, plugin, message)
    if not api.nvim_buf_is_valid(self.buf) then
      return
    end

    local line, _ = api.nvim_buf_get_extmark_by_id(self.buf, self.ns, self.marks[plugin])
    api.nvim_buf_set_lines(
      self.buf,
      line[1],
      line[1] + 1,
      true,
      { vim.fn.printf('%s %s: %s', config.error_sym, plugin, message) }
    )
    api.nvim_buf_del_extmark(self.buf, self.ns, self.marks[plugin])
    self.marks[plugin] = nil
    self:decrement_headline_count()
  end),

  task_update = vim.schedule_wrap(function(self, plugin, message)
    if not api.nvim_buf_is_valid(self.buf) then
      return
    end

    local line, _ = api.nvim_buf_get_extmark_by_id(self.buf, self.ns, self.marks[plugin])
    api.nvim_buf_set_lines(
      self.buf,
      line[1],
      line[1] + 1,
      true,
      { vim.fn.printf('%s %s: %s', config.working_sym, plugin, message) }
    )
    api.nvim_buf_set_extmark(self.buf, self.ns, self.marks[plugin], line[1], 0, {})
  end),

  update_headline_message = vim.schedule_wrap(function(self, message)
    if not api.nvim_buf_is_valid(self.buf) or not api.nvim_win_is_valid(self.win) then
      return
    end

    local headline = config.title .. ' - ' .. message
    local width = api.nvim_win_get_width(self.win) - 2
    local pad_width = math.max(math.floor((width - string.len(headline)) / 2.0), 0)
    api.nvim_buf_set_lines(
      self.buf,
      0,
      config.header_lines - 1,
      true,
      { string.rep(' ', pad_width) .. headline .. string.rep(' ', pad_width) }
    )
  end),

  increment_headline_count = vim.schedule_wrap(function(self)
    if not api.nvim_win_is_valid(self.win) then
      return
    end

    local cursor_pos = api.nvim_win_get_cursor(self.win)
    api.nvim_win_set_cursor(self.win, {1, 0})
    vim.fn.execute('normal! ')
    api.nvim_win_set_cursor(self.win, cursor_pos)
  end),

  final_results = vim.schedule_wrap(function(self, results, time)
    if not api.nvim_buf_is_valid(self.buf) or not api.nvim_win_is_valid(self.win) then
      return
    end

    display.status.running = false
    time = tonumber(time)
    self:update_headline_message(vim.fn.printf('finished in %.3fs', time))
    local lines = {}
    if results.removals then
      for _, plugin_dir in ipairs(results.removals) do
        table.insert(
          lines,
          vim.fn.printf(
            '%s Removed %s',
            config.removed_sym,
            plugin_dir
          )
        )
      end
    end

    if results.installs then
      for plugin, result in pairs(results.installs) do
        table.insert(
          lines,
          vim.fn.printf(
            '%s %s %s',
            result and config.done_sym or config.error_sym,
            result and 'Installed' or 'Failed to install',
            plugin
          )
        )
      end
    end

    if results.updates then
      for plugin_name, result_data in pairs(results.updates) do
        local result, plugin = unpack(result_data)
        local message = {}
        if result then
          if plugin.revs[1] == plugin.revs[2] then
            table.insert(message, vim.fn.printf('%s %s is already up to date', config.done_sym, plugin_name))
          else
            table.insert(message, vim.fn.printf(
              '%s Updated %s: %s..%s',
              config.done_sym,
              plugin_name,
              plugin.revs[1],
              plugin.revs[2]
            ))
            vim.list_extend(message, plugin.messages)
          end
        else
          table.insert(message, vim.fn.printf('%s Failed to update %s', config.error_sym, plugin_name))
        end

        lines = vim.list_extend(lines, message)
      end
    end

    api.nvim_buf_set_lines(self.buf, config.header_lines, -1, true, lines)
    local plugins = {}
    for plugin_name, plugin in pairs(results.plugins) do
      local plugin_data = { displayed = false, lines = {} }
      if plugin.output then
        -- if plugin.output.data and #plugin.output.data > 0 then
        --   table.insert(plugin_data.lines, '  Output:')
        --   for _, line in ipairs(plugin.output.data) do
        --     line = string.gsub(vim.trim(line), '\n', ' ')
        --     table.insert(plugin_data.lines, '    ' .. line)
        --   end
        -- end

        if plugin.output.err and #plugin.output.err > 0 then
          table.insert(plugin_data.lines, '  Errors:')
          for _, line in ipairs(plugin.output.err) do
            line = string.gsub(vim.trim(line), '\n', ' ')
            table.insert(plugin_data.lines, '    ' .. line)
          end
        end
      end

      if plugin.messages then
        table.insert(plugin_data.lines, '  Commits:')
        for _, line in ipairs(plugin.messages) do
          line = string.gsub(vim.trim(line), '\n', ' ')
          table.insert(plugin_data.lines, '    - ' .. line)
        end
      end
      plugins[plugin_name] = plugin_data
    end

    self.plugins = plugins
  end),

  toggle_info = function(self)
    if not api.nvim_buf_is_valid(self.buf)
      or not api.nvim_win_is_valid(self.win) then
      return
    end

    if next(self.plugins) == nil then
      log.info('Operations are still running; plugin info is not ready yet')
      return
    end

    local plugin_name, cursor_pos = self:find_nearest_plugin()
    if plugin_name == nil then
      log.warning('nil plugin name!')
      return
    end

    local plugin_data = self.plugins[plugin_name]
    if plugin_data.displayed then
      api.nvim_buf_set_lines(self.buf, cursor_pos[1], cursor_pos[1] + #plugin_data.lines, true, {})
      plugin_data.displayed = false
    elseif #plugin_data.lines > 0 then
      api.nvim_buf_set_lines(self.buf, cursor_pos[1], cursor_pos[1], true, plugin_data.lines)
      plugin_data.displayed = true
    else
      log.info('No further information for ' .. plugin_name)
    end
  end,

  find_nearest_plugin = function(self)
    local cursor_pos = api.nvim_win_get_cursor(0)
    -- TODO: this is a dumb hack
    for i = cursor_pos[1], 1, -1 do
      local curr_line = api.nvim_buf_get_lines(0, i - 1, i, true)[1]
      for name, _ in pairs(self.plugins) do
        if string.find(curr_line, name, 1, true) then
          return name, { i, 0 }
        end
      end
    end
  end

}

display_mt.__index = display_mt

-- TODO: Option for no colors
local function make_filetype_cmds(working_sym, done_sym, error_sym)
  return {
    -- Adapted from https://github.com/kristijanhusak/vim-packager
    'setlocal buftype=nofile bufhidden=wipe nobuflisted nolist noswapfile nowrap nospell nonumber norelativenumber nofoldenable signcolumn=yes:2',
    'syntax clear',
    'syn match packerWorking /^' .. working_sym .. '/',
    'syn match packerSuccess /^' .. done_sym .. '/',
    'syn match packerFail /^' .. error_sym .. '/',
    'syn match packerStatus /\\(^+.*—\\)\\@<=\\s.*$/',
    'syn match packerStatusSuccess /\\(^' .. done_sym .. '.*—\\)\\@<=\\s.*$/',
    'syn match packerStatusFail /\\(^' .. error_sym .. '.*—\\)\\@<=\\s.*$/',
    'syn match packerStatusCommit /\\(^\\*.*—\\)\\@<=\\s.*$/',
    'syn match packerHash /\\(\\s\\)[0-9a-f]\\{7,8}\\(\\s\\)/',
    'syn match packerRelDate /([^)]*)$/',
    'syn match packerProgress /\\(\\[\\)\\@<=[\\=]*/',
    'syn match packerOutput /\\(Output:\\)\\|\\(Commits:\\)\\|\\(Errors:\\)/',
    'hi def link packerWorking        SpecialKey',
    'hi def link packerSuccess        Question',
    'hi def link packerFail           ErrorMsg',
    'hi def link packerStatus         Constant',
    'hi def link packerStatusCommit   Constant',
    'hi def link packerStatusSuccess  Function',
    'hi def link packerStatusFail     WarningMsg',
    'hi def link packerHash           Identifier',
    'hi def link packerRelDate        Comment',
    'hi def link packerProgress       Boolean',
    'hi def link packerOutput         Type',
  }
end

display.set_config = function(working_sym, done_sym, error_sym, removed_sym, header_sym)
  config.working_sym = working_sym
  config.done_sym = done_sym
  config.error_sym = error_sym
  config.removed_sym = removed_sym
  config.header_lines = 2
  config.title = 'packer.nvim'
  config.header_sym = header_sym
  config.filetype_cmds = make_filetype_cmds(working_sym, done_sym, error_sym)
end

local function make_header(disp)
  local width = api.nvim_win_get_width(0) - 2
  local pad_width = math.floor((width - string.len(config.title)) / 2.0)
  api.nvim_buf_set_lines(
    disp.buf,
    0,
    1,
    true,
    {
      string.rep(' ', pad_width) .. config.title,
      ' ' .. string.rep(config.header_sym, width - 2)
    }
  )
end

local function setup_window(disp)
  api.nvim_buf_set_option(disp.buf, 'filetype', 'packer')
  for _, m in ipairs(config.keymaps) do
    api.nvim_buf_set_keymap(disp.buf, m[1], m[2], m[3], m[4])
  end

  for _, c in ipairs(config.filetype_cmds) do
    api.nvim_command(c)
  end
end

display.open = function(opener)
  if display.status.disp then
    api.nvim_win_close(display.status.disp.win, true)
    display.status.disp = nil
  end

  local disp = setmetatable({}, display_mt)
  if type(opener) == 'string' then
    api.nvim_command(opener)
    disp.win = api.nvim_get_current_win()
    disp.buf = api.nvim_get_current_buf()
  else
    disp.win, disp.buf = opener('[packer]')
  end

  disp.marks = {}
  disp.plugins = {}
  disp.ns = api.nvim_create_namespace('')
  make_header(disp)
  setup_window(disp)

  display.status.disp = disp

  return disp
end

display.status = { running = false, disp = nil }

display.quit = function()
  display.status.running = false
  vim.fn.execute('q!', 'silent')
end

display.toggle_info = function()
  display.status.disp:toggle_info()
end

display.ask_user = a.wrap(function(headline, body, callback)
  local buf = api.nvim_create_buf(false, true)
  local width = math.min(65, math.floor(0.8 * vim.o.columns))
  local height = #body + 3
  local x = (vim.o.columns - width) / 2.0
  local y = (vim.o.lines - height) / 2.0
  local pad_width = math.max(math.floor((width - string.len(headline)) / 2.0), 0)
  api.nvim_buf_set_lines(buf, 0, -1, true,
    vim.list_extend({ string.rep(' ', pad_width) .. headline .. string.rep(' ', pad_width), '' }, body))
  api.nvim_buf_set_option(buf, 'modifiable', false)
  local opts = {
    relative = 'editor',
    width = width,
    height = height,
    col = x,
    row = y,
    focusable = false,
    style = 'minimal'
  }

  local win = api.nvim_open_win(buf, false, opts)
  local check = vim.loop.new_prepare()
  local prompted = false
  vim.loop.prepare_start(check, vim.schedule_wrap(function()
    if not api.nvim_win_is_valid(win) then
      return
    end

    vim.loop.prepare_stop(check)
    if not prompted then
      prompted = true
      local ans = string.lower(vim.fn.input('OK to remove? [y/N] ')) == 'y'
      api.nvim_win_close(win, true)
      callback(ans)
    end
  end))
end)

return display