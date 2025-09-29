local curl = require("plenary.curl")

local Notion = {}
Notion.__index = Notion

function Notion.new(opts)
  local self = setmetatable({}, Notion)
  self.token = assert(opts.token, "notion: token required")
  self.version = opts.version or "2022-06-28"
  self.rate_limit_ms = opts.rate_limit_ms or 350
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

-- ---------- diagnostics ----------
function Notion:me()
  local res = curl.request({
    method = "GET",
    url = "https://api.notion.com/v1/users/me",
    headers = headers(self),
  })
  sleep(self.rate_limit_ms)
  if not res then return nil, "no response" end
  local obj = decode(res.body)
  if res.status >= 300 then
    return nil, obj.message or ("HTTP " .. res.status)
  end
  -- best-effort labels
  local name = obj.name or (obj.bot and obj.bot.owner and obj.bot.owner.workspace_name) or "unknown"
  local workspace = (obj.bot and obj.bot.owner and obj.bot.owner.workspace_name) or ""
  return { name = name, workspace = workspace }, nil
end

function Notion:get_database(id)
  local res = curl.request({
    method = "GET",
    url = ("https://api.notion.com/v1/databases/%s"):format(id),
    headers = headers(self),
  })
  sleep(self.rate_limit_ms)
  if not res then return nil, "no response" end
  local obj = decode(res.body)
  if res.status >= 300 then
    return nil, obj.message or ("HTTP " .. res.status)
  end
  return obj, nil
end

-- ---------- upsert helpers ----------
function Notion:query_by_name(database_id, name)
  local res = curl.request({
    method = "POST",
    url = ("https://api.notion.com/v1/databases/%s/query"):format(database_id),
    headers = headers(self),
    body = vim.json.encode({
      filter = { property = "Name", title = { equals = name } },
      page_size = 1,
    }),
  })
  sleep(self.rate_limit_ms)

  if not res or res.status >= 300 then return nil end
  local obj = decode(res.body)
  local hit = obj.results and obj.results[1] or nil
  if hit and hit.id then return { id = hit.id } end
  return nil
end

local function err_msg(prefix, res)
  local msg = ""
  if res then
    local obj = decode(res.body)
    msg = (obj.message and (": " .. obj.message)) or (": HTTP " .. tostring(res.status))
  else
    msg = ": no response"
  end
  return prefix .. msg
end

function Notion:create_page(payload)
  local res = curl.request({
    method = "POST",
    url = "https://api.notion.com/v1/pages",
    headers = headers(self),
    body = vim.json.encode(payload),
  })
  sleep(self.rate_limit_ms)
  if not res or res.status >= 300 then
    vim.notify(err_msg("notio: create fail", res), vim.log.levels.WARN)
    return false
  end
  return true
end

function Notion:update_page(page_id, payload)
  local res = curl.request({
    method = "PATCH",
    url = ("https://api.notion.com/v1/pages/%s"):format(page_id),
    headers = headers(self),
    body = vim.json.encode(payload),
  })
  sleep(self.rate_limit_ms)
  if not res or res.status >= 300 then
    vim.notify(err_msg("notio: update fail", res), vim.log.levels.WARN)
    return false
  end
  return true
end

return { new = Notion.new }
