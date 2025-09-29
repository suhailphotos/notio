local M = {}

local defaults = {
  database_id = nil,                 -- REQUIRED: your KeyBindings DB id (string)
  app_page_id = nil,                 -- REQUIRED: the “Neovim” page id in your Apps/Plugins DB
  plugin_pages = {},                 -- OPTIONAL: map plugin slug -> page id in your Apps/Plugins DB

  -- Controls
  skip_builtins = true,              -- skip things recognized as “Built in”
  skip_plug_mappings = true,         -- skip <Plug> lhs
  include_modes = { "n","v","x","s","i","c","t","o" },
  platform = { "Linux", "Windows", "macOS" },
  status = "Active",
  dry_run = false,
  rate_limit_ms = 350,               -- gentle on Notion rate limits

  -- Visual defaults (can be overridden)
  cover_url = "https://res.cloudinary.com/dicttuyma/image/upload/w_1500,h_600,c_fill,g_auto/v1742094822/banner/notion_33.jpg",
  icon_url  = "https://www.notion.so/icons/keyboard-alternate_lightgray.svg",

  -- Optional: tweak how to detect “Project” scope plugins (defaults to Buffer/Global)
  project_plugins = { ["yazi.nvim"] = true, ["telescope.nvim"] = true },

  -- Optional: change property names in your DB (we stick to your schema by default)
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

  -- Notion Version for headers
  notion_version = "2022-06-28",
}

local cfg = {}

local function has_api_key()
  local k = vim.env.NOTION_API_KEY
  if not k or k == "" then
    vim.notify("notio: NOTION_API_KEY not set; aborting sync.", vim.log.levels.WARN)
    return nil
  end
  return k
end

function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", defaults, opts or {})
  if not cfg.database_id or not cfg.app_page_id then
    vim.notify("notio: please set opts.database_id and opts.app_page_id", vim.log.levels.ERROR)
  end

  -- Commands
  vim.api.nvim_create_user_command("NotioSync", function(a)
    local Dry = (a.args == "dry" or cfg.dry_run)
    M.sync({ dry = Dry })
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("NotioDryRun", function()
    M.sync({ dry = true })
  end, {})
end

local function build_props(row)
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

  local function multi_select(list)
    local out = {}
    for _, name in ipairs(list or {}) do table.insert(out, { name = name }) end
    return out
  end

  local props = {
    [P.Name] = { title = { { type = "text", text = { content = row.name } } } },
    [P.Action] = { rich_text = vim.list_extend(
      text(row.lhs_pretty or "", true),
      text(row.action_suffix or "", false)
    ) },
    [P.Application] = { relation = { { id = cfg.app_page_id } } },
    [P.Status] = row.status and { select = { name = row.status } } or vim.NIL,
    [P.Type] = row.type_ and { select = { name = row.type_ } } or vim.NIL,
    [P.Plugin] = (row.plugin_page_id and { relation = { { id = row.plugin_page_id } } }) or { relation = {} },
    [P.Tier] = row.tier and { select = { name = row.tier } } or vim.NIL,
    [P.Platform] = { multi_select = multi_select(cfg.platform) },
    [P.Scope] = row.scope and { select = { name = row.scope } } or vim.NIL,
    [P.Mode] = { multi_select = multi_select(row.modes or {}) },
    [P.Date] = { date = row.date or vim.NIL },
    [P.Category] = row.category and { select = { name = row.category } } or vim.NIL,
    [P.Command] = { rich_text = text(row.command, false) },
    [P.Description] = { rich_text = text(row.description, false) },
    [P.Docs] = row.docs and { url = row.docs } or { url = vim.NIL },
    [P.Prefix] = row.prefix and { select = { name = row.prefix } } or vim.NIL,
  }

  return props
end

local function to_notion_page(row)
  return {
    parent = { database_id = cfg.database_id },
    icon   = { type = "external", external = { url = cfg.icon_url } },
    cover  = { type = "external", external = { url = cfg.cover_url } },
    properties = build_props(row),
  }
end

local function to_notion_update(row)
  return { properties = build_props(row) }
end

-- One record → create/update
local function upsert_one(notion, row, dry)
  if dry then
    vim.schedule(function()
      vim.notify(("notio[dry]: %s  %s"):format(row.exists and "UPDATE" or "CREATE", row.name))
    end)
    return true
  end

  -- Try find by Name (exact)
  local existing = notion.query_by_name(cfg.database_id, row.name)
  if existing and existing.id then
    local ok = notion.update_page(existing.id, to_notion_update(row))
    return ok
  end
  return notion.create_page(to_notion_page(row))
end

-- Public sync
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
    status = cfg.status,
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

  vim.notify(("notio: %s %d, %s %d")
    :format(dry and "DRY processed" or "Synced",
            ok_count, "failed", fail_count),
    (fail_count == 0) and vim.log.levels.INFO or vim.log.levels.WARN)
end

return M
