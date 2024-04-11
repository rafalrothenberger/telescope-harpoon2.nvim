local harpoon = require("harpoon")
local conf = require("telescope.config").values
local pickers = require("telescope.pickers")

local finders = require("telescope.finders")
local make_entry_generator = require("telescope.make_entry")
local utils = require("telescope.utils")

local actions = require("telescope.actions")
local action_set = require("telescope.actions.set")
local action_state = require("telescope.actions.state")
local action_utils = require("telescope.actions.utils")

local function merge_options(default, user)
  return vim.tbl_deep_extend("force", default, user or {})
end

---@class Harpoon2TelescopeUI
local Harpoon2TelescopeUI = {}
Harpoon2TelescopeUI.__index = Harpoon2TelescopeUI

local finder_default_options = {
  disable_devicons = false,
  make_entry = make_entry_generator.gen_from_file({}),
  make_empty_entry = make_entry_generator.gen_from_string({}),
  entry_display = function(index_width, options)
    return function(entry)
      local display = entry.harpoon.display
      local hl_group, icon

      if display ~= "" then
        display, hl_group, icon = utils.transform_devicons(entry.value, display, options.disable_devicons)
      end

      display = string.format("%" .. index_width .. "s %s", entry.index, display)

      if hl_group then
        return display, { { { index_width + 1, index_width + 1 + #icon }, hl_group } }
      end
      return display
    end
  end,
}

function Harpoon2TelescopeUI:_create_finder(opts)
  local options = merge_options(finder_default_options, opts)
  local index_width = math.floor(math.log(self._list:length(), 10)) + 1
  local display_list = self._list:display()

  local items = {}
  for i = 1, self._list:length() do
    items[i] = { index = i, harpoon_item = self._list.items[i], harpoon_display = display_list[i] }
  end

  return finders.new_table({
    results = items,
    entry_maker = function(item)
      local entry
      local harpoon_item = item.harpoon_item
      if harpoon_item == nil then
        entry = options.make_empty_entry(tostring(item.index))

        entry.lnum = 0
        entry.col = 0
      else
        entry = options.make_entry(harpoon_item.value)

        entry.lnum = harpoon_item.context.row
        entry.col = harpoon_item.context.col
      end

      entry.harpoon = {
        item = item.harpoon_item,
        display = item.harpoon_display,
      }
      entry.display = options.entry_display(index_width, options)

      return entry
    end,
  })
end

local sorter_default_options = {
  generic_sorter = {},
}

function Harpoon2TelescopeUI:_create_sorter(opts)
  local options = merge_options(sorter_default_options, opts)

  local sorter = conf.generic_sorter(options.generic_sorter)
  local generic_sort_scoring = sorter.scoring_function

  sorter.scoring_function = function(sorting_self, prompt, line, entry)
    if tostring(entry.index) == tostring(prompt) then
      return 0
    end
    return generic_sort_scoring(sorting_self, prompt, line, entry)
  end

  return sorter
end

local preview_default_options = {
  grep_previewer = {},
}

function Harpoon2TelescopeUI:_create_previewer(opts)
  local options = merge_options(preview_default_options, opts)

  return conf.grep_previewer(options.grep_previewer)
end

function Harpoon2TelescopeUI:_save_to_history()
  local current_entries = {}
  for _, entry in ipairs(self._finder.results) do
    table.insert(current_entries, entry)
  end

  table.insert(self._history, current_entries)
end

function Harpoon2TelescopeUI:move_mark(prompt_bufnr, offset)
  local length = #self._finder.results
  offset = offset % length

  self:_save_to_history()

  local current_selection = action_state.get_selected_entry()
  local current_index = current_selection.index
  local new_index = ((current_index - 1 + offset) % length) + 1

  local current_entry = self._finder.results[current_index]
  local new_entry = self._finder.results[new_index]

  current_entry.index = new_index
  new_entry.index = current_index

  self._finder.results[current_index] = new_entry
  self._finder.results[new_index] = current_entry

  self:_refresh(new_index, prompt_bufnr)
end

function Harpoon2TelescopeUI:delete_entry(prompt_bufnr)
  self:_save_to_history()

  local current_selection = action_state.get_selected_entry(prompt_bufnr)
  local current_index = current_selection.index

  local indexes = {}
  action_utils.map_selections(prompt_bufnr, function(entry)
    table.insert(indexes, entry.index)
  end)

  if #indexes == 0 then
    table.insert(indexes, current_index)
  end

  table.sort(indexes, function(a, b)
    return a > b
  end)

  for _, idx in ipairs(indexes) do
    self:_delete_entry(idx)
  end

  self:_refresh(current_index, prompt_bufnr)
end

function Harpoon2TelescopeUI:_delete_entry(index)
  table.remove(self._finder.results, index)

  for idx = index, #self._finder.results do
    self._finder.results[idx].index = idx
  end
end

function Harpoon2TelescopeUI:save(_)
  local to_add
  local new_display_items = {}
  for _, entry in ipairs(self._finder.results) do
    to_add = entry.harpoon.display
    if to_add == "" then
      to_add = nil
    end

    table.insert(new_display_items, to_add)
  end

  self._list:resolve_displayed(new_display_items, #self._finder.results)

  print("Harpoon - saved")
end

function Harpoon2TelescopeUI:delete_all(prompt_bufnr)
  self:_save_to_history()

  for _ = 1, #self._finder.results do
    table.remove(self._finder.results)
  end

  self:_refresh(1, prompt_bufnr)
end

function Harpoon2TelescopeUI:_refresh(index, prompt_bufnr)
  local current_picker = action_state.get_current_picker(prompt_bufnr)
  current_picker:refresh()

  -- Refresh is async, and there is no sensible way, or I couldn't find it,
  -- to decide when it ended, so we need to wait...
  vim.wait(1)

  action_set.shift_selection(prompt_bufnr, 1 - index)
end

function Harpoon2TelescopeUI:undo(prompt_bufnr)
  if #self._history == 0 then
    print("Harpoon - nothing to undo")
    return
  end

  local current_index = 1
  if #self._finder.results > 0 then
    local current_selection = action_state.get_selected_entry(prompt_bufnr)
    current_index = current_selection.index
  end

  local history = table.remove(self._history)
  local length = math.max(#self._finder.results, #history)
  for idx = 1, length do
    self._finder.results[idx] = history[idx]
    self._finder.results[idx].index = idx
  end
  self:_refresh(current_index, prompt_bufnr)

  print("Harpoon - undo")
end

function Harpoon2TelescopeUI:new(opts)
  opts = opts or {}

  self._list = harpoon:list()
  self._history = {}
  self._finder = self:_create_finder(opts.finder)
  self._sorter = self:_create_sorter(opts.sorter)
  self._previewer = self:_create_previewer(opts.previewer)

  self._picker = pickers.new(opts, {
    prompt_title = "Harpoion",
    results_title = "Marks",
    preview_title = "Preview",
    finder = self._finder,
    sorter = self._sorter,
    previewer = self._previewer,
    initial_mode = "normal",
    cache_picker = false,
    attach_mappings = function(_, map)
      map("i", "<C-Up>", function(prompt_bufnr)
        self:move_mark(prompt_bufnr, 1)
      end)
      map("n", "<C-Up>", function(prompt_bufnr)
        self:move_mark(prompt_bufnr, 1)
      end)

      map("i", "<C-Down>", function(prompt_bufnr)
        self:move_mark(prompt_bufnr, -1)
      end)
      map("n", "<C-Down>", function(prompt_bufnr)
        self:move_mark(prompt_bufnr, -1)
      end)

      map("n", "dd", function(prompt_bufnr)
        self:delete_entry(prompt_bufnr)
      end)

      map("i", "<C-d>", function(prompt_bufnr)
        self:delete_entry(prompt_bufnr)
      end)

      map("n", "<C-s>", function(prompt_bufnr)
        self:save(prompt_bufnr)
      end)

      map("i", "<C-s>", function(prompt_bufnr)
        self:save(prompt_bufnr)
      end)

      map("n", "da", function(prompt_bufnr)
        self:delete_all(prompt_bufnr)
      end)

      map("n", "u", function(prompt_bufnr)
        self:undo(prompt_bufnr)
      end)

      for i = 1, 10 do
        map("n", "<Leader>" .. tostring(i % 10), function(prompt_bufnr)
          local current_index = action_state.get_selected_entry().index
          action_set.shift_selection(prompt_bufnr, current_index - i)
        end)

        map("n", tostring(i % 10), function(prompt_bufnr)
          actions.close(prompt_bufnr)
          self._list:select(i)
        end)
      end

      return true
    end,
  })
  self._picker:find()

  return self
end

return Harpoon2TelescopeUI
