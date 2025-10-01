-- lua/notio/init.lua
local M = {}

local jnull = (vim.json and vim.json.null) or vim.NIL

local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end

local defaults = {
  database_id = nil,
  app_page_id = nil,
  plugin_pages = {},

  skip_builtins = true,
  skip_plug_mappings = true,
  include_modes = { "n","v","x","s","i","c","t","o" },

  -- Guardrails
  update_only = true,                 -- never mass-create unless you flip this
  never_create_builtins = true,       -- don’t create rows with empty/“Built in” command
  skip_prefixes = { "[", "]", "g", "z" }, -- drop noisy prefix families up-front

  platform = { "Linux", "Windows", "macOS" },
  status = "Active",
  dry_run = false,
  rate_limit_ms = 350,

  cover_url = "https://res.cloudinary.com/dicttuyma/image/upload/w_1500,h_600,c_fill,g_auto/v1742094822/banner/notion_33.jpg",
  icon_url  = "https://www.notion.so/icons/keyboard-alternate_lightgray.svg",

  project_plugins = { ["yazi.nvim"] = true, ["telescope.nvim"] = true },

  properties = {
    Name        = "Name",
    Action      = "Action",
    Application = "Application",
    Status      = "Status",
    Type        = "Type",
    Plugin      = "Plugin",
    Tier        = "Tier",
    Platform    = "Platform",
    Scope       = "Scope",
    Mode        = "Mode",
    Date        = "Date",
    Category    = "Category",
    Command     = "Command",
    Description = "Description",
    Docs        = "Docs",
    Prefix      = "Prefix",
    UID         = "UID",      -- rich_text column “UID”
  },

  notion_version = "2022-06-28",
  touch_date_on_create = true,
  touch_date_on_update = false,

  built_in_marker_value = "Built in",
  require_confirm = true,

  -- HTTP resiliency
  timeout_ms = 60000,
  retries    = 2,
}

local function canon_command_key(s)
  s = trim((s or ""):lower()):gsub("%s+"," ")
  local m = s:match("^plugin:%s*(.+)$")
  if m then
    -- normalize common plugin name variants
    m = m:gsub("%.lua$", ""):gsub("%.nvim$", ""):gsub("%s+", "")
    return "plugin:" .. m
  end
  return s
end

local function now_iso_utc() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

local cfg, abort_flag = {}, false

-- -------- small utils --------
local function has_api_key()
  local k = vim.env.NOTION_API_KEY
  if not k or k == "" then
    vim.notify("notio: NOTION_API_KEY not set; aborting.", vim.log.levels.WARN)
    return nil
  end
  return k
end

local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end

local function canon_mode_key(m) return (m == "v" or m == "x" or m == "s") and "V" or m end
local function norm_cmd(s) return trim((s or ""):lower():gsub("%s+"," ")) end
local function binding_fp_of_row(row)
  return table.concat({ row.type_ or "", row.prefix or "", row.lhs_pretty or "" }, "|")
end

-- log buffer
local function open_log()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# notio sync log", "" })
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = "wipe", "markdown"
  vim.api.nvim_set_current_buf(buf)
  local function append(line)
    local n = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, n, n, false, { line })
  end
  return append
end

-- builders
local function text_frag(s, is_code, color)
  if not s or s == "" then return {} end
  return {{
    type = "text",
    text = { content = s },
    annotations = {
      bold = false, italic = false, strikethrough = false,
      underline = false, code = is_code or false,
      color = color or ((is_code and "red") or "default"),
    },
    plain_text = s,
  }}
end

local function multi_select(list)
  local out = {}
  for _, name in ipairs(list or {}) do out[#out+1] = { name = name } end
  return out
end

local function humanize_command(cmd)
  cmd = (cmd or ""):gsub("%s+"," ")
  if cmd:find(":m '") and cmd:find("gv=gv") then
    if cmd:find("%-2<CR>gv=gv") then return "Move selection up one line (keep selection)" end
    if cmd:find("%+1<CR>gv=gv") then return "Move selection down one line (keep selection)" end
    return "Move selection (keep selection)"
  end
  if cmd:find("<Cmd>DiagToggle<CR>") then return "Diagnostics: toggle" end
  if cmd:find("<Cmd>DiagOn<CR>")     then return "Diagnostics: on" end
  if cmd:find("<Cmd>DiagOff<CR>")    then return "Diagnostics: off" end
  if cmd:match("<Cmd>Yazi%s+toggle<CR>") then return "Yazi: resume/toggle" end
  if cmd:match("<Cmd>Yazi%s+cwd<CR>")    then return "Yazi: open CWD" end
  return nil
end

local function build_props(row, for_update)
  local P = cfg.properties
  local props = {}

  if row.date == vim.NIL then row.date = nil end
  if row.docs == vim.NIL then row.docs = nil end

  props[P.Name]        = { title = { { type = "text", text = { content = row.name } } } }
  props[P.Action]      = { rich_text = vim.list_extend(text_frag(row.lhs_pretty or "", true, "red"), text_frag(row.action_suffix or "", false)) }
  props[P.Application] = { relation  = { { id = cfg.app_page_id } } }
  props[P.Platform]    = { multi_select = multi_select(cfg.platform) }
  props[P.Mode]        = { multi_select = multi_select(row.modes or {}) }

  -- Description fallback chain
  local desc_txt = row.description or ""
  if desc_txt == "" and row.action_suffix and row.action_suffix ~= "" then
    desc_txt = trim(row.action_suffix)
  end
  if desc_txt == "" and row.command and trim(row.command):lower() ~= "built in" then
    desc_txt = row.command
  end
  if desc_txt == "" then
    local friendly = humanize_command(row.command)
    if friendly then desc_txt = friendly end
  end
  if not for_update then
    props[P.Description] = { rich_text = text_frag(desc_txt, false) }
  end

  props[P.Command]     = { rich_text = text_frag(row.command, false) }
  props[P.Docs]        = { url = row.docs or jnull }

  props[P.Status]      = row.status   and { select = { name = row.status   } } or { select = jnull }
  props[P.Type]        = row.type_    and { select = { name = row.type_    } } or { select = jnull }
  props[P.Category]    = row.category and { select = { name = row.category } } or { select = jnull }
  props[P.Scope]       = row.scope    and { select = { name = row.scope    } } or { select = jnull }
  props[P.Prefix]      = row.prefix   and { select = { name = row.prefix   } } or { select = jnull }

  -- Tier: only set on create (unless explicitly provided)
  if for_update then
    if row.tier then props[P.Tier] = { select = { name = row.tier } } end
  else
    props[P.Tier] = { select = { name = row.tier or "A" } }
  end

  if row.plugin_page_id then
    props[P.Plugin] = { relation = { { id = row.plugin_page_id } } }
  end

  -- UID (if DB column exists)
  if P.UID and row.uid then
    props[P.UID] = { rich_text = text_frag(row.uid, true, "blue") }
  end

  -- Date (create or explicit)
  if row.date ~= nil then
    if row.date == jnull then
      props[P.Date] = { date = jnull }
    elseif type(row.date) == "string" then
      props[P.Date] = { date = { start = row.date } }
    elseif type(row.date) == "table" then
      props[P.Date] = { date = row.date }
    end
  else
    if (not for_update) and cfg.touch_date_on_create then
      props[P.Date] = { date = { start = now_iso_utc() } }
    end
  end

  return props
end

local function to_notion_page(row)
  return {
    parent = { database_id = cfg.database_id },
    icon   = { type = "external", external = { url = cfg.icon_url } },
    cover  = { type = "external", external = { url = cfg.cover_url } },
    properties = build_props(row, false),
  }
end

local function to_notion_update(row)
  if cfg.touch_date_on_update and (row.date == nil or row.date == vim.NIL) then
    row.date = now_iso_utc()
  end
  return { properties = build_props(row, true) }
end

-- -------- fingerprints & planning --------

-- Keep fingerprint minimal so we don't churn on cosmetic fields
-- Only trigger UPDATE when the keybinding itself changes (mode/scope/lhs)
local function row_fingerprint(row)
  return row.uid or ""
end

local function open_plan_buffer(plan, stats)
  local lines = {
    ("# notio dry list — %d rows (create=%d, update=%d, rebind=%d, skip_same=%d, skip_built_in=%d)")
      :format(#plan, stats.create, stats.update, stats.rebind, stats.skip_same, stats.skip_built_in),
    "",
    "op           mode     scope     type         category   name",
    "----------------------------------------------------------------------------",
  }
  for _, it in ipairs(plan) do
    local r = it.row
    lines[#lines+1] = string.format(
      "%-12s %-8s %-8s %-12s %-10s %s",
      it.op, (r.modes and r.modes[1] or "?"), (r.scope or "?"), (r.type_ or "?"), (r.category or "?"), r.name or "?"
    )
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
end

local function compute_plan(rows, index, built_in_value)
  local plan, stats = {}, { create = 0, update = 0, rebind = 0, skip_same = 0, skip_built_in = 0 }
  local by_uid, by_name, by_command = index.by_uid or {}, index.by_name or {}, index.by_command or {}
  local built_in_lc = trim(built_in_value or ""):lower()

  local function have_fp_from_info(info)
    return (info.uid and info.uid ~= "" and info.uid) or (info.synth_uid or "")
  end

  for _, row in ipairs(rows) do
    local info = nil
    local cmd_key = canon_command_key(row.command)
    local uid = row.uid
    local cmd_lc = trim(row.command or ""):lower()

    -- Always skip built-ins (and never create)
    if cmd_lc == built_in_lc or cmd_lc == "" then
      plan[#plan+1] = { op = "skip_built_in", row = row }
      stats.skip_built_in = stats.skip_built_in + 1
      goto continue
    end

    -- 1) match by UID (explicit or synthetic from previous runs)
    if uid and by_uid[uid] then info = by_uid[uid] end

    -- 2) fallback: Name
    if not info and row.name and by_name[row.name] then info = by_name[row.name] end

    -- 3) fallback: Command (non built-in)
    local info_by_cmd = (cmd_key ~= "" and by_command[cmd_key]) or nil

    if info then
      -- Same page; only update if binding+command changed
      local want = row_fingerprint(row)
      local have = have_fp_from_info(info)
      if want == have then
        plan[#plan+1] = { op = "skip_same", row = row, existing_id = info.id }
        stats.skip_same = stats.skip_same + 1
      else
        plan[#plan+1] = { op = "update", row = row, existing_id = info.id }
        stats.update = stats.update + 1
      end

    elseif info_by_cmd and not info_by_cmd.built_in then
      -- IMPORTANT: if command points to a page that already has the same binding, skip
      local want = row_fingerprint(row)
      local have = have_fp_from_info(info_by_cmd)
      if want == have then
        plan[#plan+1] = { op = "skip_same", row = row, existing_id = info_by_cmd.id }
        stats.skip_same = stats.skip_same + 1
      else
        plan[#plan+1] = {
          op = "rebind",
          row = row,
          existing_id = info_by_cmd.id,
          old_uid = info_by_cmd.uid or info_by_cmd.synth_uid,
        }
        stats.rebind = stats.rebind + 1
      end

    else
      -- No match
      if cfg.update_only or (cfg.never_create_builtins and (cmd_lc == "" or cmd_lc == built_in_lc)) then
        plan[#plan+1] = { op = "skip_no_match", row = row }
        stats.skip_same = stats.skip_same + 1
      else
        plan[#plan+1] = { op = "create", row = row, existing_id = nil }
        stats.create = stats.create + 1
      end
    end

    ::continue::
  end
  return plan, stats
end

-- upsert with per-row logging; `op` distinguishes UPDATE vs REBIND status/date tweaks
local function upsert_one(notion, row, existing_id, log, op)
  if existing_id then
    if op == "rebind" and not cfg.touch_date_on_update then
      row.date = now_iso_utc()          -- stamp Date on rebind
    end
    if op == "rebind" then
      row.status = "Changed"
    end
    local res = notion:update_page(existing_id, to_notion_update(row))
    if res.ok then
      local tag = (op == "rebind") and "REBIND" or "UPDATE"
      log(("%s  ✔  %s  [%s]"):format(tag, row.name, row.uid or "?"))
      return true
    else
      local tag = (op == "rebind") and "REBIND" or "UPDATE"
      log(("%s  ✖  %s  (%s)"):format(tag, row.name, res.err or "error"))
      return false
    end
  else
    row.tier = row.tier or "A"
    local res = notion:create_page(to_notion_page(row))
    if res.ok then
      log(("CREATE  ✔  %s  [%s]"):format(row.name, row.uid or "?"))
      return true
    else
      log(("CREATE  ✖  %s  (%s)"):format(row.name, res.err or "error"))
      return false
    end
  end
end

-- -------- public API --------

function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", defaults, opts or {})
  if not cfg.database_id or not cfg.app_page_id then
    vim.notify("notio: please set opts.database_id and opts.app_page_id", vim.log.levels.ERROR)
  end

  vim.api.nvim_create_user_command("NotioSync", function(a)
    local Dry = (a.args == "dry" or cfg.dry_run)
    M.sync({ dry = Dry })
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("NotioDryRun", function() M.sync({ dry = true }) end, {})

  vim.api.nvim_create_user_command("NotioAbort", function()
    abort_flag = true
    vim.notify("notio: abort requested — will stop after current request.")
  end, {})

  -- Diagnostics
  vim.api.nvim_create_user_command("NotioPing", function()
    if not has_api_key() then return end
    local notion = require("notio.notion").new({
      token = vim.env.NOTION_API_KEY,
      version = cfg.notion_version,
      rate_limit_ms = cfg.rate_limit_ms,
      timeout_ms = cfg.timeout_ms,
      retries = cfg.retries,
    })
    local me, merr = notion:me()
    if me then
      vim.notify(("notio: token OK as '%s' (workspace: %s)"):format(me.name, me.workspace or "?"))
    else
      vim.notify("notio: token check failed " .. (merr or ""), vim.log.levels.ERROR); return
    end
    local db, dberr = notion:get_database(cfg.database_id)
    if db then
      local title = (db.title and db.title[1] and db.title[1].plain_text) or "(untitled)"
      vim.notify("notio: database reachable → " .. title)
    else
      vim.notify("notio: database check failed " .. (dberr or ""), vim.log.levels.ERROR)
    end
  end, {})

  -- Backfill stable UID into the Notion column for rows that lack it
  vim.api.nvim_create_user_command("NotioBackfillUID", function()
    if not has_api_key() then return end
    local notion = require("notio.notion").new({
      token = vim.env.NOTION_API_KEY,
      version = cfg.notion_version,
      rate_limit_ms = cfg.rate_limit_ms,
      timeout_ms = cfg.timeout_ms,
      retries = cfg.retries,
      command_prop = cfg.properties.Command,
    })
    local idx = notion:index(cfg.database_id, cfg.properties, cfg.built_in_marker_value)

    local P = cfg.properties
    local function rt_code_blue(s)
      return { properties = {
        [P.UID] = { rich_text = {{
          type = "text",
          text = { content = s },
          annotations = { code = true, color = "blue", bold=false, italic=false, strikethrough=false, underline=false },
        }}}
      }}
    end

  vim.api.nvim_create_user_command("NotioDebug", function()
    local lines = {
      "# notio effective config",
      "",
      "update_only = " .. tostring(cfg.update_only),
      "never_create_builtins = " .. tostring(cfg.never_create_builtins),
      "skip_builtins = " .. tostring(cfg.skip_builtins),
      "skip_plug_mappings = " .. tostring(cfg.skip_plug_mappings),
      "skip_prefixes = [" .. table.concat(cfg.skip_prefixes or {}, ", ") .. "]",
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden, vim.bo[buf].filetype = "wipe", "markdown"
    vim.api.nvim_set_current_buf(buf)
  end, {})

    local count = 0
    -- iterate by_name to touch every page exactly once
    for _, info in pairs(idx.by_name or {}) do
      if (info.uid or "") == "" and (info.synth_uid or "") ~= "" and not info.built_in then
        local res = notion:update_page(info.id, rt_code_blue(info.synth_uid))
        if res.ok then count = count + 1 end
      end
    end
    vim.notify(("notio: backfilled UID on %d pages"):format(count))
  end, {})
end

function M.sync(opts)
  if not has_api_key() then return end
  abort_flag = false
  local dry = opts and opts.dry or false

  local km = require("notio.keymaps").collect({
    include_modes = cfg.include_modes,
    skip_builtins = cfg.skip_builtins,
    skip_plug     = cfg.skip_plug_mappings,
    skip_prefixes = cfg.skip_prefixes,
    project_plugins = cfg.project_plugins,
    plugin_pages    = cfg.plugin_pages,
  })

  local rows = require("notio.keymaps").to_rows(km, {
    platform = table.concat(cfg.platform, ", "),
    status   = cfg.status,
    project_plugins = cfg.project_plugins,
    plugin_pages    = cfg.plugin_pages,
  })
  if #rows == 0 then
    vim.notify("notio: nothing to sync.", vim.log.levels.INFO)
    return
  end

  local notion = require("notio.notion").new({
    token = vim.env.NOTION_API_KEY,
    version = cfg.notion_version,
    rate_limit_ms = cfg.rate_limit_ms,
    timeout_ms = cfg.timeout_ms,
    retries = cfg.retries,
    command_prop = cfg.properties.Command,
  })

  local index = notion:index(cfg.database_id, cfg.properties, cfg.built_in_marker_value)
  local plan, stats = compute_plan(rows, index, cfg.built_in_marker_value)

  if dry then
    open_plan_buffer(plan, stats)
    return
  end

  if cfg.require_confirm then
    local msg = ("Create %d, Update %d, Rebind %d, Skip %d. Proceed?")
      :format(stats.create, stats.update, stats.rebind, stats.skip_same + stats.skip_built_in)
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    if choice ~= 1 then
      vim.notify("notio: aborted by user.")
      return
    end
  end

  local log = open_log()
  log(("# plan: create=%d update=%d rebind=%d skip_same=%d skip_built_in=%d")
      :format(stats.create, stats.update, stats.rebind, stats.skip_same, stats.skip_built_in))
  log("")

  local ok_count, fail_count, skipped = 0, 0, (stats.skip_same + stats.skip_built_in)
  local created_guard = {} -- prevent duplicate creates within the same run

  for _, it in ipairs(plan) do
    if abort_flag then
      log("")
      log("ABORTED by user.")
      break
    end

    if it.op == "create" then
      local guard_key = table.concat({
        it.row.uid or "",
        it.row.name or "",
        (it.row.command or ""):gsub("%s+"," "),
      }, "|")

      if created_guard[guard_key] then
        log(("SKIP    ·  %s  (duplicate create in this run)"):format(it.row.name))
        skipped = skipped + 1
      else
        local ok = upsert_one(notion, it.row, nil, log, "create")
        if ok then
          ok_count = ok_count + 1
          created_guard[guard_key] = true
        else
          fail_count = fail_count + 1
        end
      end

    elseif it.op == "update" then
      local ok = upsert_one(notion, it.row, it.existing_id, log, "update")
      if ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end

    elseif it.op == "rebind" then
      local ok = upsert_one(notion, it.row, it.existing_id, log, "rebind")
      if ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end

    else
      log(("SKIP    ·  %s  (%s)"):format(it.row.name, it.op))
    end
  end

  vim.notify(("notio: Synced %d, skipped %d, failed %d"):format(ok_count, skipped, fail_count),
    (fail_count == 0) and vim.log.levels.INFO or vim.log.levels.WARN)
end

return M
