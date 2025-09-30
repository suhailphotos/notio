local curl = require("plenary.curl")

local Notion = {}
Notion.__index = Notion

function Notion.new(opts)
  local self = setmetatable({}, Notion)
  self.token        = assert(opts.token, "notion: token required")
  self.version      = opts.version or "2022-06-28"
  self.rate_limit_ms= opts.rate_limit_ms or 350
  self.command_prop = opts.command_prop or "Command"
  self.timeout_ms   = opts.timeout_ms or 60000   -- NEW: higher timeout (ms)
  self.retries      = opts.retries or 2          -- NEW: simple retry
  return self
end

local function headers(self)
  return {
    Authorization = "Bearer " .. self.token,
    ["Notion-Version"] = self.version,
    ["Content-Type"] = "application/json",
  }
end

local function decode(body)
  if not body or body == "" then return {} end
  local ok, obj = pcall(vim.json.decode, body)
  return ok and obj or {}
end

local function sleep(ms) if ms and ms > 0 then vim.wait(ms) end end
local function is_tbl(x) return type(x) == "table" end
local function to_list(x) return is_tbl(x) and x or {} end
local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end

-- Unified HTTP caller with timeout + tiny retry/backoff
local function http(self, spec)
  local last
  for attempt = 1, (self.retries or 1) do
    local req = vim.tbl_extend("force", spec, {
      headers = headers(self),
      timeout = self.timeout_ms, -- plenary.job timeout is ms
    })
    local ok, res = pcall(curl.request, req)
    last = ok and res or nil

    -- Success (HTTP < 300)
    if last and last.status and last.status < 300 then return last end

    -- 429/5xx/timeouts → retry (simple)
    local status = last and last.status or 0
    if attempt < (self.retries or 1) and (status == 429 or status >= 500 or status == 0) then
      sleep((self.rate_limit_ms or 300) * attempt * 3)
    else
      break
    end
  end
  return last
end

-- -------- diagnostics --------
function Notion:me()
  local res = http(self, { method = "GET", url = "https://api.notion.com/v1/users/me" })
  sleep(self.rate_limit_ms)
  if not res then return nil, "no response" end
  local obj = decode(res.body)
  if res.status >= 300 then return nil, obj.message or ("HTTP " .. res.status) end
  local name = obj.name or (obj.bot and obj.bot.owner and obj.bot.owner.workspace_name) or "unknown"
  local workspace = (obj.bot and obj.bot.owner and obj.bot.owner.workspace_name) or ""
  return { name = name, workspace = workspace }, nil
end

function Notion:get_database(id)
  local res = http(self, { method = "GET", url = ("https://api.notion.com/v1/databases/%s"):format(id) })
  sleep(self.rate_limit_ms)
  if not res then return nil, "no response" end
  local obj = decode(res.body)
  if res.status >= 300 then return nil, obj.message or ("HTTP " .. res.status) end
  return obj, nil
end

-- -------- robust accessors for Notion props --------
local function title_text(prop)
  local out = {}
  local arr = (is_tbl(prop) and to_list(prop.title)) or {}
  for _, t in ipairs(arr) do
    out[#out+1] = t.plain_text or (t.text and t.text.content) or ""
  end
  return table.concat(out)
end

local function rich_text(prop)
  local out = {}
  local arr = (is_tbl(prop) and to_list(prop.rich_text)) or {}
  for _, t in ipairs(arr) do
    out[#out+1] = t.plain_text or (t.text and t.text.content) or ""
  end
  return table.concat(out)
end

local function sel(prop)
  if not is_tbl(prop) then return "" end
  local v = prop.select
  if is_tbl(v) then return v.name or "" end
  return "" -- treat vim.json.null as empty
end

local function ms(prop)
  if not is_tbl(prop) then return "" end
  local list = {}
  local arr = prop.multi_select
  if is_tbl(arr) then
    for _, it in ipairs(arr) do list[#list+1] = it.name or "" end
  end
  table.sort(list)
  return table.concat(list, ",")
end

local function first_rel_id(prop)
  if not is_tbl(prop) then return "" end
  local rel = prop.relation
  if not is_tbl(rel) then return "" end
  return (rel[1] and rel[1].id) or ""
end

-- -------- pagination --------
function Notion:list_all_pages(database_id)
  local all, cursor = {}, nil
  while true do
    local body = { page_size = 100 }
    if cursor then body.start_cursor = cursor end
    local res = http(self, {
      method = "POST",
      url = ("https://api.notion.com/v1/databases/%s/query"):format(database_id),
      body = vim.json.encode(body),
    })
    sleep(self.rate_limit_ms)
    if not res then break end
    local obj = decode(res.body)
    for _, p in ipairs(obj.results or {}) do all[#all+1] = p end
    if obj.has_more and obj.next_cursor then cursor = obj.next_cursor else break end
  end
  return all
end

-- returns { by_uid = {...}, by_name = {...}, by_command = {...} }
function Notion:index(database_id, prop_names, built_in_value)
  local pages = self:list_all_pages(database_id)
  local P = prop_names or {}
  local Name  = P.Name or "Name"
  local UID   = P.UID  or "UID"          -- NEW
  local Command = P.Command or "Command"
  local Plugin  = P.Plugin or "Plugin"
  local Status  = P.Status or "Status"
  local Type    = P.Type   or "Type"
  local Category= P.Category or "Category"
  local Scope   = P.Scope  or "Scope"
  local Prefix  = P.Prefix or "Prefix"
  local Tier    = P.Tier   or "Tier"
  local Mode    = P.Mode   or "Mode"
  local Action  = P.Action or "Action"
  local Description = P.Description or "Description"

  local by_uid, by_name, by_command = {}, {}, {}

  for _, page in ipairs(pages) do
    local props = page.properties or {}
    local name = title_text(props[Name])
    if name ~= "" then
      local cmd_text = rich_text(props[Command])
      local uid_text = rich_text(props[UID])  -- empty if column missing
      local built_in = false
      if built_in_value and cmd_text ~= "" then
        built_in = trim(cmd_text):lower() == trim(built_in_value):lower()
      end

      local fingerprint = table.concat({
        sel(props[Status]),
        sel(props[Type]),
        sel(props[Category]),
        sel(props[Scope]),
        sel(props[Prefix]),
        sel(props[Tier]),
        ms(props[Mode]),
        rich_text(props[Action]),
        rich_text(props[Command]),
        rich_text(props[Description]),
        first_rel_id(props[Plugin]),
      }, "|")

      local info = {
        id = page.id,
        name = name,
        command = cmd_text,
        uid = uid_text,
        built_in = built_in,
        fingerprint = fingerprint,
        last_edited_time = page.last_edited_time or "",
      }

      by_name[name] = info
      if uid_text and uid_text ~= "" then
        local prev = by_uid[uid_text]
        if not prev or (prev.last_edited_time < info.last_edited_time) then
          by_uid[uid_text] = info
        end
      end
      if cmd_text and cmd_text ~= "" and not built_in then
        local prev = by_command[cmd_text]
        if not prev or (prev.last_edited_time < info.last_edited_time) then
          by_command[cmd_text] = info
        end
      end
    end
  end

  return { by_uid = by_uid, by_name = by_name, by_command = by_command }
end

-- -------- helpers --------
local function rich_text_plain(rt)
  local out = {}
  for _, blk in ipairs(to_list(rt)) do
    out[#out+1] = blk.plain_text or (blk.text and blk.text.content) or ""
  end
  return table.concat(out)
end

function Notion:query_by_name(database_id, name)
  local res = http(self, {
    method = "POST",
    url = ("https://api.notion.com/v1/databases/%s/query"):format(database_id),
    body = vim.json.encode({ filter = { property = "Name", title = { equals = name } }, page_size = 1 }),
  })
  sleep(self.rate_limit_ms)
  if not res or res.status >= 300 then return nil end
  local obj = decode(res.body)
  local hit = obj.results and obj.results[1] or nil
  if not (hit and hit.id) then return nil end

  local is_builtin = false
  local props = hit.properties or {}
  local cmd = props[self.command_prop]
  if is_tbl(cmd) and cmd.type == "rich_text" then
    local txt = trim(rich_text_plain(cmd.rich_text))
    if txt:lower() == "built in" then is_builtin = true end
  end

  return { id = hit.id, is_builtin = is_builtin }
end

local function err_msg(prefix, res)
  if not res then return prefix .. ": no response" end
  local obj = decode(res.body)
  return prefix .. ((obj and obj.message and (": " .. obj.message)) or (": HTTP " .. tostring(res.status)))
end

function Notion:create_page(payload)
  local res = http(self, {
    method = "POST",
    url = "https://api.notion.com/v1/pages",
    body = vim.json.encode(payload),
  })
  sleep(self.rate_limit_ms)
  if not res or res.status >= 300 then
    return { ok = false, status = res and res.status or 0, err = err_msg("notio: create fail", res) }
  end
  local obj = decode(res.body)
  return { ok = true, status = res.status, id = obj.id }
end

function Notion:update_page(page_id, payload)
  local res = http(self, {
    method = "PATCH",
    url = ("https://api.notion.com/v1/pages/%s"):format(page_id),
    body = vim.json.encode(payload),
  })
  sleep(self.rate_limit_ms)
  if not res or res.status >= 300 then
    return { ok = false, status = res and res.status or 0, err = err_msg("notio: update fail", res) }
  end
  local obj = decode(res.body)
  return { ok = true, status = res.status, id = obj.id }
end

return { new = Notion.new }
