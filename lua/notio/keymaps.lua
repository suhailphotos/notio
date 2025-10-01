local M = {}

local mode_names = {
  n = "Normal", v = "Visual", x = "Visual-Select", s = "Select",
  i = "Insert", c = "Command", t = "Terminal", o = "Operator-pending",
}

local function canon_mode_key(m)
  -- Collapse Visual family into one group
  if m == "v" or m == "x" or m == "s" then return "V" end
  return m
end

local function mode_display(m)
  return mode_names[m] or m
end

local function add_mode_name(list, m)
  local name = mode_display(m)
  for _, v in ipairs(list) do if v == name then return end end
  table.insert(list, name)
end

-- normalize <...> tokens so UIDs are stable across runs
local function canon_lhs(s)
  if not s or s == "" then return "" end
  -- leader normalization
  s = s:gsub("^<Space>", "<leader>")

  -- unify modifier case
  s = s:gsub("<[mM]%-", "<M-")
       :gsub("<[aA]%-", "<M-")   -- Alt → Meta (or swap to <A-> if you prefer)
       :gsub("<[cC]%-", "<C-")
       :gsub("<[sS]%-", "<S-")
  -- normalize single-letter ctrl/meta/shift keys to uppercase
  s = s:gsub("<([CMS])%-(%a)>", function(mod, k) return "<"..mod.."-"..k:upper()..">" end)

  -- unify common key names’ case
  local map = { cr="CR", esc="Esc", tab="Tab", space="Space", bs="BS" }
  s = s:gsub("<(%a+)>", function(name) return "<"..(map[name:lower()] or name)..">" end)

  -- unify backslash alias
  s = s:gsub("<C%-[bB]slash>", "<C-\\>")

  return s
end

local function leader_string() return vim.g.mapleader or "\\" end

local function pretty_lhs(lhs)
  if not lhs or lhs == "" then return "" end
  local L = leader_string()
  local s = lhs
  if L == " " and s:sub(1,1) == " " then s = "<leader>" .. s:sub(2) end
  s = s:gsub("^<Space>", "<leader>")
  return s
end

local function starts_with_any(s, list)
  for _, p in ipairs(list or {}) do
    if s:sub(1, #p) == p then return true end
  end
  return false
end

local function prefix_of(lhs)
  if not lhs or lhs == "" then return "none" end
  if lhs:find("^<leader>") or (leader_string() == " " and lhs:sub(1,1) == " ") then
    return "<leader>"
  end
  local c = lhs:sub(1,1)
  if c:match("[gzt%[%]%{%}%\"']") then return c end
  if lhs:sub(1,1) == ":" then return ":" end
  return "none"
end

local function is_chord(lhs)
  return lhs and (lhs:find("<C%-") or lhs:find("<M%-") or lhs:find("<A%-") or lhs:find("<S%-"))
end

local function guess_type(lhs, mode)
  lhs = pretty_lhs(lhs)
  if lhs:find("^<leader>") then return "leader" end
  if is_chord(lhs) then return "chord" end
  if lhs:match("^g.") then return "prefix" end
  if lhs == "h" or lhs == "j" or lhs == "k" or lhs == "l"
     or lhs:match("^[wbge]$") or lhs == "gg" or lhs == "G"
     or lhs == "%%" or lhs == "{" or lhs == "}" or lhs:match("^[fFtT].?") then
    return "motion"
  end
  if mode == "o" then return "operator" end
  return "command"
end

local function origin_from_callback(cb)
  if type(cb) ~= "function" then return nil end
  local info = debug.getinfo(cb, "S")
  return info and info.short_src or nil
end

local PLUGIN_SHORT = {
  ["telescope.nvim"]       = "Telescope",
  ["nvim-tree.lua"]        = "NvimTree",
  ["yazi.nvim"]            = "Yazi",
  ["nvim-dap"]             = "DAP",
  ["nvim-dap-ui"]          = "DAP UI",
  ["nvim-lspconfig"]       = "LSP",
  ["nvim-cmp"]             = "CMP",
  ["nvim-tmux-navigation"] = "tmux-nav",
  ["undotree"]             = "UndoTree",
  ["vim-fugitive"]         = "Fugitive",
  ["iris"]                 = "Iris",
  ["nvterm"]               = "NvTerm",
}

local PLUGIN_CATEGORY = {
  ["telescope.nvim"]       = "Search",
  ["nvim-tree.lua"]        = "Navigation",
  ["yazi.nvim"]            = "Navigation",
  ["nvim-dap"]             = "Debug",
  ["nvim-dap-ui"]          = "Debug",
  ["nvim-lspconfig"]       = "LSP",
  ["nvim-cmp"]             = "Editing",
  ["nvim-tmux-navigation"] = "Windows/Tabs",
  ["undotree"]             = "Session",
  ["vim-fugitive"]         = "Git",
  ["iris"]                 = "Session",
  ["nvterm"]               = "Terminal",
}

local function guess_plugin(desc, rhs, origin, buffer)
  desc, rhs, origin = desc or "", rhs or "", origin or ""
  if desc:match("^DAP:") then
    if desc:lower():find("ui") then return "nvim-dap-ui" else return "nvim-dap" end
  end
  if desc:match("^Explorer:") then return "nvim-tree.lua" end
  if desc:match("^Yazi:") then return "yazi.nvim" end
  if desc:match("^Theme:") then return "iris" end
  if desc:find("Grep") or desc:find("Files") or desc:find("Telescope") then return "telescope.nvim" end
  if desc:find("Fugitive") then return "vim-fugitive" end
  if desc:find("CMP") then return "nvim-cmp" end
  if desc:find("Diagnostics") or desc:find("LSP ") or buffer == 1 then
    if desc ~= "" then return "nvim-lspconfig" end
  end
  if desc:find("Terminal") then return "nvterm" end
  if desc:find("Undo tree") then return "undotree" end

  if rhs:find("NvimTree") then return "nvim-tree.lua" end
  if rhs:find("Yazi")     then return "yazi.nvim" end
  if rhs:find("Undotree") then return "undotree" end
  if rhs:find("Git")      then return "vim-fugitive" end

  if origin:find("telescope") then return "telescope.nvim" end
  if origin:find("nvimtree")  then return "nvim-tree.lua" end
  if origin:find("yazi")      then return "yazi.nvim" end
  if origin:find("dap")       then return "nvim-dap" end
  if origin:find("cmp")       then return "nvim-cmp" end
  if origin:find("nvim%-tmux%-navigation") or origin:find("tmux[_%-]nav") then
    return "nvim-tmux-navigation"
  end
  if origin:find("undotree")  then return "undotree" end
  if origin:find("fugitive")  then return "vim-fugitive" end
  if origin:find("iris")      then return "iris" end
  if origin:find("lsp")       then return "nvim-lspconfig" end

  return nil
end

local function guess_category(plugin, desc, lhs)
  if plugin and PLUGIN_CATEGORY[plugin] then return PLUGIN_CATEGORY[plugin] end
  desc = desc or ""
  lhs  = pretty_lhs(lhs or "")
  if lhs:find("^<leader>[eE]?$") or desc:find("Explorer") then return "Navigation" end
  if desc:find("split") or desc:find("zoom") then return "Windows/Tabs" end
  if desc:find("Grep") or desc:find("Files") then return "Search" end
  if desc:find("Diagnostics") then return "LSP" end
  if desc:find("clipboard") or desc:find("yank") then return "Clipboard" end
  if desc:find("Terminal") then return "Terminal" end
  if desc:find("Git") then return "Git" end
  if desc:find("Undo") then return "Session" end
  return "Editing"
end

local function looks_builtin(m)
  if m.desc and m.desc:match("^:help .+%-default$") then return true end
  return false
end

local ALL_MODES = { "n","v","x","s","i","c","t","o" }

function M.collect(opts)
  opts = opts or {}
  local modes = opts.include_modes or ALL_MODES
  local rows = {}

  for _, mode in ipairs(modes) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode) or {}) do
      table.insert(rows, { mode = mode, map = m, buffer = 0 })
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      for _, mode in ipairs(modes) do
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode) or {}) do
          table.insert(rows, { mode = mode, map = m, buffer = 1 })
        end
      end
    end
  end

  -- Filter
  local out = {}
  for _, r in ipairs(rows) do
    local m = r.map
    if m and m.lhs then
      if opts.skip_plug and m.lhs:match("^<Plug>") then goto continue end
      if opts.skip_builtins and looks_builtin(m) then goto continue end
      local lhs_pre = pretty_lhs(m.lhs)
      if starts_with_any(lhs_pre, opts.skip_prefixes) then goto continue end
      table.insert(out, r)
    end
    ::continue::
  end

  return out
end

local function modes_list(mode)
  return { mode_names[mode] or mode }
end

function M.to_rows(list, ctx)
  ctx = ctx or {}
  local rows_by_key, ordered = {}, {}

  local function canon_mode_key(m) return (m=="v" or m=="x" or m=="s") and "V" or m end
  local function leader_string() return vim.g.mapleader or "\\" end
  local function pretty_lhs_local(lhs)
    if not lhs or lhs == "" then return "" end
    local L, s = leader_string(), lhs
    if L == " " and s:sub(1,1) == " " then s = "<leader>" .. s:sub(2) end
    s = s:gsub("^<Space>", "<leader>")
    return s
  end

  -- Prefer Visual > Insert > Command > Terminal > Operator > Normal
  local canon_priority = { ["V"]=6, ["i"]=5, ["c"]=4, ["t"]=3, ["o"]=2, ["n"]=1 }
  local function canon_from_modes(ms)
    local best, bestp = "n", -1
    for _, name in ipairs(ms or {}) do
      local m = (name == "Visual" or name == "Visual-Select" or name == "Select") and "V"
                or (name == "Insert" and "i")
                or (name == "Command" and "c")
                or (name == "Terminal" and "t")
                or (name == "Operator-pending" and "o")
                or "n"
      local p = canon_priority[m] or 0
      if p > bestp then best, bestp = m, p end
    end
    return best
  end

  for _, rec in ipairs(list) do
    local m, mode, buffer = rec.map, rec.mode, rec.buffer
    local lhs = m.lhs or ""
    local lhs_pretty = canon_lhs(pretty_lhs_local(lhs))  -- normalize tokens for stable UIDs
    local rhs = m.rhs or (m.callback and "<lua-callback>") or ""
    local origin = (type(m.callback)=="function" and (debug.getinfo(m.callback,"S").short_src)) or ""
    local desc = m.desc or ""

    local plugin = guess_plugin(desc, rhs, origin, buffer)
    local category = guess_category(plugin, desc, lhs_pretty)
    local type_ = guess_type(lhs, mode)
    local prefix = prefix_of(lhs_pretty)

    local name = lhs_pretty
    if plugin and PLUGIN_SHORT[plugin] then name = name .. " (" .. PLUGIN_SHORT[plugin] .. ")" end

    local scope = (buffer == 1) and "Buffer" or "Global"
    if plugin and ctx.project_plugins and ctx.project_plugins[plugin] then scope = "Project" end

    -- Group by buffer + lhs only (so we merge multiple modes of the same key)
    local key = table.concat({ buffer, lhs_pretty }, "¦")

    local row = rows_by_key[key]
    if not row then
      row = {
        name           = name,
        lhs_pretty     = lhs_pretty,
        action_suffix  = (desc ~= "" and (" " .. desc)) or "",
        status         = ctx.status or "Active",
        type_          = type_,
        category       = category,
        prefix         = prefix,
        modes          = { mode_display(mode) },
        scope          = scope,
        command        = (plugin and ("Plugin: " .. plugin)) or (desc ~= "" and desc) or "Custom configuration",
        docs           = nil,
        tier           = nil,         -- defaulted to "A" on create
        plugin_page_id = ctx.plugin_pages and ctx.plugin_pages[plugin] or nil,
        uid            = nil,         -- set after merging modes
      }
      rows_by_key[key] = row
      ordered[#ordered+1] = row
    else
      -- merge extra modes into multi-select if same lhs & buffer
      add_mode_name(row.modes, mode)
    end
  end

  -- Finalize description + uid (after modes are merged)
  for _, row in ipairs(ordered) do
    row.description = (row.action_suffix or ""):gsub("^%s+","")
    local canon = canon_from_modes(row.modes)
    row.uid = table.concat({ canon, row.lhs_pretty, row.scope }, "|")
  end

  -- set platform + status from ctx (consistent)
  for _, row in ipairs(ordered) do
    row.platform = ctx.platform
    row.status   = ctx.status or "Active"
  end

  return ordered
end

return M
