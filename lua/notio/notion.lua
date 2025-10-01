local curl = require("plenary.curl")

local Notion = {}
Notion.__index = Notion

local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end

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

-- normalize <...> tokens so UIDs are stable across runs
local function canon_lhs(s)
  if not s or s == "" then return "" end
  -- leader normalization (you already do this elsewhere too)
  s = s:gsub("^<Space>", "<leader>")

  -- unify modifier case
  s = s:gsub("<[mM]%-", "<M-")
       :gsub("<[aA]%-", "<M-")   -- Alt → Meta (or swap to <A-> if you prefer)
       :gsub("<[cC]%-", "<C-")
       :gsub("<[sS]%-", "<S-")

  -- unify common key names’ case
  local map = { cr="CR", esc="Esc", tab="Tab", space="Space", bs="BS" }
  s = s:gsub("<(%a+)>", function(name) return "<"..(map[name:lower()] or name)..">" end)

  -- unify backslash alias
  s = s:gsub("<C%-[bB]slash>", "<C-\\>")

  return s
end

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


-- pull just the first rich-text run (you write lhs_pretty first)
-- helpers to robustly derive lhs_pretty
local function first_token(s)
  s = trim(s or "")
  if s == "" then return "" end
  local tok = s:match("^%S+") or s
  -- normalize early <Space> form to <leader>
  tok = tok:gsub("^<Space>", "<leader>")
  return tok
end

local function action_first_token(prop)
  if not is_tbl(prop) then return "" end
  local arr = to_list(prop.rich_text)
  if #arr == 0 then return "" end
  local txt = arr[1].plain_text or (arr[1].text and arr[1].text.content) or ""
  return first_token(txt)
end

local function name_first_token(prop)
  -- Extract lhs from Name; take part before " (Plugin)" if present
  if not is_tbl(prop) then return "" end
  local nm = title_text(prop)
  if nm == "" then return "" end
  local base = nm:gsub("%s*%b()", "") -- drop trailing " (…)"
  return first_token(base)
end

local function canon_mode_from_ms(prop)
  if not is_tbl(prop) then return "n" end
  local set = {}
  local arr = prop.multi_select
  if is_tbl(arr) then
    for _, it in ipairs(arr) do set[it.name or ""] = true end
  end
  if set["Visual"] or set["Visual-Select"] or set["Select"] then return "V" end
  if set["Insert"] then return "i" end
  if set["Command"] then return "c" end
  if set["Terminal"] then return "t" end
  if set["Operator-pending"] then return "o" end
  return "n"
end

local function scope_name(prop)
  if not is_tbl(prop) then return "Global" end
  local v = prop.select
  if is_tbl(v) then return v.name or "Global" end
  return "Global"
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

local function canon_uid(uid)
  local m, lhs, sc = uid:match("^([^|]*)|([^|]*)|([^|]*)$")
  if lhs then return table.concat({ m, canon_lhs(lhs), sc }, "|") end
  return uid
end

function Notion:index(database_id, prop_names, built_in_value)
  local pages = self:list_all_pages(database_id)
  local P = prop_names or {}
  local Name   = P.Name   or "Name"
  local UID    = P.UID    or "UID"
  local Command= P.Command or "Command"
  local Mode   = P.Mode   or "Mode"
  local Scope  = P.Scope  or "Scope"
  local Type   = P.Type   or "Type"
  local Prefix = P.Prefix or "Prefix"
  local Action = P.Action or "Action"

  local function title_text(prop)
    local out, arr = {}, (type(prop)=="table" and prop.title) or {}
    for _, t in ipairs(arr or {}) do out[#out+1] = t.plain_text or (t.text and t.text.content) or "" end
    return table.concat(out)
  end
  local function rich_text(prop)
    local out, arr = {}, (type(prop)=="table" and prop.rich_text) or {}
    for _, t in ipairs(arr or {}) do out[#out+1] = t.plain_text or (t.text and t.text.content) or "" end
    return table.concat(out)
  end
  local function sel_name(prop)
    if type(prop)=="table" and type(prop.select)=="table" then return prop.select.name or "" end
    return ""
  end
  local function first_token_of_action(prop)
    local arr = (type(prop)=="table" and prop.rich_text) or {}
    local txt = (arr and arr[1] and (arr[1].plain_text or (arr[1].text and arr[1].text.content))) or ""
    txt = (txt:gsub("^%s+",""):gsub("%s+$",""))
    txt = txt:gsub("^<Space>", "<leader>")
    return (txt:match("^%S+") or txt)
  end
  local function canon_mode_from_ms(ms)
    local set, arr = {}, (type(ms)=="table" and ms.multi_select) or {}
    for _, it in ipairs(arr or {}) do set[it.name or ""] = true end
    if set["Visual"] or set["Visual-Select"] or set["Select"] then return "V" end
    if set["Insert"] then return "i" end
    if set["Command"] then return "c" end
    if set["Terminal"] then return "t" end
    if set["Operator-pending"] then return "o" end
    return "n"
  end
  local function scope_name(sc)
    return (type(sc)=="table" and type(sc.select)=="table" and (sc.select.name or "Global")) or "Global"
  end

  local by_uid, by_name, by_command = {}, {}, {}

  for _, page in ipairs(pages) do
    local props = page.properties or {}
    local name = title_text(props[Name])
    if name ~= "" then
      local cmd_text = (rich_text(props[Command]) or ""):gsub("%s+"," ")
      local uid_text = canon_uid(rich_text(props[UID]) or "")
      local lhs_text = first_token_of_action(props[Action])
      lhs_text = canon_lhs(lhs_text)
      if lhs_text == "" then
        local nm = title_text(props[Name])
        lhs_text = (nm:gsub("%s*%b()", "")):gsub("^%s+",""):gsub("%s+$","")
        lhs_text = lhs_text:gsub("^<Space>", "<leader>")
        lhs_text = (lhs_text:match("^%S+") or lhs_text)
      end
      local mode_canon = canon_mode_from_ms(props[Mode])
      local scope = scope_name(props[Scope])
      local synth_uid = table.concat({ mode_canon, lhs_text, scope }, "|")

      local built_in = false
      if built_in_value and cmd_text ~= "" then
        built_in = (cmd_text:lower() == built_in_value:lower())
      end

      local type_name   = sel_name(props[Type])
      local prefix_name = sel_name(props[Prefix])

      local binding_fp = table.concat({ type_name or "", prefix_name or "", lhs_text or "" }, "|")
      local command_key = canon_command_key(cmd_text)

      local info = {
        id = page.id,
        name = name,
        command = cmd_text,
        command_key = command_key,
        uid = uid_text,
        built_in = built_in,
        last_edited_time = page.last_edited_time or "",
        synth_uid = synth_uid,
        binding_fp = binding_fp,
        mode = mode_canon,
        scope = scope,
        type_ = type_name,
        prefix = prefix_name,
      }

      by_name[name] = info

      if uid_text ~= "" then
        local prev = by_uid[uid_text]
        if not prev or prev.last_edited_time < info.last_edited_time then by_uid[uid_text] = info end
      end

      if not built_in and command_key ~= "" then
        local prev = by_command[command_key]
        if not prev or prev.last_edited_time < info.last_edited_time then by_command[command_key] = info end
      end

      -- also index synthetic UID if no explicit UID present (helps first run)
      if uid_text == "" and not built_in then
        local prev = by_uid[synth_uid]
        if not prev or prev.last_edited_time < info.last_edited_time then by_uid[synth_uid] = info end
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
