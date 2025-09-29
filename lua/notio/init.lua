local M = {}

local defaults = {
  database_id = nil,
  app_page_id = nil,
  plugin_pages = {},

  skip_builtins = true,
  skip_plug_mappings = true,
  include_modes = { "n","v","x","s","i","c","t","o" },
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
  },

  notion_version = "2022-06-28",
}

local cfg = {}

local function has_api_key()
  local k = vim.env.NOTION_API_KEY
  if not k or k == "" then
    vim.notify("notio: NOTION_API_KEY not set; aborting.", vim.log.levels.WARN)
    return nil
  end
  return k
end

function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", defaults, opts or {})
  if not cfg.database_id or not cfg.app_page_id then
    vim.notify("notio: please set opts.database_id and opts.app_page_id", vim.log.levels.ERROR)
  end

  vim.api.nvim_create_user_command("NotioSync", function(a)
    local Dry = (a.args == "dry" or cfg.dry_run)
    M.sync({ dry = Dry })
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("NotioDryRun", function()
    M.sync({ dry = true })
  end, {})

  -- NEW: ping (token + DB reachability)
  vim.api.nvim_create_user_command("NotioPing", function()
    if not has_api_key() then return end
    local notion = require("notio.notion").new({
      token = vim.env.NOTION_API_KEY,
      version = cfg.notion_version,
      rate_limit_ms = cfg.rate_limit_ms,
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

  -- NEW: create a single smoke-test page
  vim.api.nvim_create_user_command("NotioTestCreate", function()
    if not has_api_key() then return end
    if not cfg.database_id or not cfg.app_page_id then
      vim.notify("notio: database_id/app_page_id missing", vim.log.levels.ERROR)
      return
    end
    local now = os.date("!%Y-%m-%d %H:%M:%S UTC")
    local row = {
      name = "Notio Smoke Test (" .. now .. ")",
      lhs_pretty = "<leader>pv",
      action_suffix = " Yazi: project view",
      status = cfg.status,
      type_ = "leader",
      category = "Navigation",
      prefix = "<leader>",
      scope = "Project",
      modes = { "Normal" },
      command = "Plugin: yazi.nvim",
      description = "Created by :NotioTestCreate",
      docs = nil,
      date = vim.NIL,
      tier = "Essentials",
      plugin_page_id = (cfg.plugin_pages and cfg.plugin_pages["yazi.nvim"]) or nil,
    }

    local props = M._build_props(row)
    local payload = {
      parent = { database_id = cfg.database_id },
      icon   = { type = "external", external = { url = cfg.icon_url } },
      cover  = { type = "external", external = { url = cfg.cover_url } },
      properties = props,
    }

    local notion = require("notio.notion").new({
      token = vim.env.NOTION_API_KEY,
      version = cfg.notion_version,
      rate_limit_ms = cfg.rate_limit_ms,
    })
    if notion:create_page(payload) then
      vim.notify("notio: smoke test page created ✔")
    else
      vim.notify("notio: smoke test failed", vim.log.levels.ERROR)
    end
  end, {})

  -- NEW: readable dry list into a scratch buffer
  vim.api.nvim_create_user_command("NotioDryList", function()
    local km = require("notio.keymaps").collect({
      include_modes = cfg.include_modes,
      skip_builtins = cfg.skip_builtins,
      skip_plug     = cfg.skip_plug_mappings,
      project_plugins = cfg.project_plugins,
      plugin_pages    = cfg.plugin_pages,
    })
    local rows = require("notio.keymaps").to_rows(km, {
      platform = table.concat(cfg.platform, ", "),
      status   = cfg.status,
      project_plugins = cfg.project_plugins,
      plugin_pages    = cfg.plugin_pages,
    })
    local lines = { ("# notio dry list — %d rows"):format(#rows), "" }
    for _, r in ipairs(rows) do
      lines[#lines+1] =
        string.format("%-8s  %-8s  %-11s  %-8s  %s",
          (r.modes and r.modes[1] or "?"), (r.scope or "?"), (r.type_ or "?"),
          (r.category or "?"), r.name or "?")
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_set_current_buf(buf)
  end, {})
end

-- ---------- property builders ----------
local function multi_select(list)
  local out = {}
  for _, name in ipairs(list or {}) do table.insert(out, { name = name }) end
  return out
end

function M._build_props(row)
  local P = cfg.properties
  local function text(s, is_code)
    if not s or s == "" then return {} end
    return {{
      type = "text",
      text = { content = s },
      annotations = {
        bold = false, italic = false, strikethrough = false,
        underline = false, code = is_code or false, color = "default",
      },
      plain_text = s,
    }}
  end

  local props = {
    [P.Name] = { title = { { type = "text", text = { content = row.name } } } },
    [P.Action] = { rich_text = vim.list_extend(
      text(row.lhs_pretty or "", true),
      text(row.action_suffix or "", false)
    ) },
    [P.Application] = { relation = { { id = cfg.app_page_id } } },
    [P.Status]      = row.status and { select = { name = row.status } } or vim.NIL,
    [P.Type]        = row.type_ and { select = { name = row.type_ } } or vim.NIL,
    [P.Plugin]      = (row.plugin_page_id and { relation = { { id = row.plugin_page_id } } }) or { relation = {} },
    [P.Tier]        = row.tier and { select = { name = row.tier } } or vim.NIL,
    [P.Platform]    = { multi_select = multi_select(cfg.platform) },
    [P.Scope]       = row.scope and { select = { name = row.scope } } or vim.NIL,
    [P.Mode]        = { multi_select = multi_select(row.modes or {}) },
    [P.Date]        = { date = row.date or vim.NIL },
    [P.Category]    = row.category and { select = { name = row.category } } or vim.NIL,
    [P.Command]     = { rich_text = text(row.command, false) },
    [P.Description] = { rich_text = text(row.description, false) },
    [P.Docs]        = row.docs and { url = row.docs } or { url = vim.NIL },
    [P.Prefix]      = row.prefix and { select = { name = row.prefix } } or vim.NIL,
  }
  return props
end

local function to_notion_page(row)
  return {
    parent = { database_id = cfg.database_id },
    icon   = { type = "external", external = { url = cfg.icon_url } },
    cover  = { type = "external", external = { url = cfg.cover_url } },
    properties = M._build_props(row),
  }
end

local function to_notion_update(row)
  return { properties = M._build_props(row) }
end

-- ---------- upsert ----------
local function upsert_one(notion, row, dry)
  if dry then
    vim.notify(
      ("notio[dry]: %s  %s  [%s/%s/%s]")
        :format(row.exists and "UPDATE" or "CREATE",
                row.name,
                row.modes and row.modes[1] or "?",
                row.type_ or "?",
                row.category or "?")
    )
    return true
  end
  local existing = notion:query_by_name(cfg.database_id, row.name)
  if existing and existing.id then
    return notion:update_page(existing.id, to_notion_update(row))
  end
  return notion:create_page(to_notion_page(row))
end

-- ---------- public sync ----------
function M.sync(opts)
  if not has_api_key() then return end
  local dry = opts and opts.dry or false

  local km = require("notio.keymaps").collect({
    include_modes = cfg.include_modes,
    skip_builtins = cfg.skip_builtins,
    skip_plug     = cfg.skip_plug_mappings,
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
  })

  local ok_count, fail_count = 0, 0
  for _, row in ipairs(rows) do
    local ok = upsert_one(notion, row, dry)
    if ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end
  end

  vim.notify(("notio: %s %d, failed %d")
    :format(dry and "DRY processed" or "Synced", ok_count, fail_count),
    (fail_count == 0) and vim.log.levels.INFO or vim.log.levels.WARN)
end

return M
