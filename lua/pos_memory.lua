-- pos_memory.lua：码内候选偏好记忆（对标讯飞「候选位置记忆」的轻量版）
--
-- 记录「在某个笔画码下，用户选中了哪个候选」：
--   同一个码反复选同一个字/词 → 下次把它提前。
-- 与 learning 的区别：learning 记的是「这个词全局被上屏几次」，
-- 这里记的是「在这个码的候选列表里，你偏好哪一个」——即同码竞争关系。
--
-- 不作用于 1~2 笔短码（那里要保持《首两笔速查》头部顺序），只在 >=3 笔时参与排序。
-- 数据：<user_dir>/pos_memory.tsv   格式 code\ttext\t次数
local M = {}

local loaded = false
local data = {}          -- code .. '\t' .. text -> 次数
local path = nil
local dirty = 0
local last_code = nil
local MAX_COUNT = 5      -- 单条偏好计数封顶
local MAX_ENTRIES = 4000

local function user_dir()
  if rime_api and rime_api.get_user_data_dir then
    local d = rime_api:get_user_data_dir()
    if d and d ~= '' then return d end
  end
  return '.'
end

local function load()
  if loaded then return end
  loaded = true
  path = user_dir() .. '/pos_memory.tsv'
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      local code, text, n = line:match('^([^\t]+)\t([^\t]+)\t(%d+)$')
      if code and text then data[code .. '\t' .. text] = tonumber(n) end
    end
    f:close()
  end
end

local function save()
  if not path then return end
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then return end
  for k, n in pairs(data) do
    local code, text = k:match('^([^\t]+)\t([^\t]+)$')
    if code then f:write(code, '\t', text, '\t', tostring(n), '\n') end
  end
  f:close()
  os.rename(tmp, path)
end

-- 翻译器每次拿到非空输入时调用，记录「当前正在打哪个码」
function M.set_code(code)
  if code and code ~= '' then last_code = code end
end

-- 上屏时调用（由 learning 的 commit_notifier 转发）
function M.on_commit(text)
  load()
  if not last_code or not text or text == '' then return end
  local k = last_code .. '\t' .. text
  local n = data[k]
  if n and n >= MAX_COUNT then
    last_code = nil
    return
  end
  data[k] = (n or 0) + 1
  last_code = nil            -- 用过即清，避免下一次上屏错误归属
  dirty = dirty + 1
  if dirty >= 5 then
    dirty = 0
    -- 超限：丢弃只出现 1 次的旧记录
    local cnt = 0
    for _ in pairs(data) do cnt = cnt + 1 end
    if cnt > MAX_ENTRIES then
      for kk, nn in pairs(data) do
        if nn <= 1 then data[kk] = nil end
      end
    end
    save()
  end
end

-- 排序加成：同一个码下越常被选中，加成越高
-- 只在 >=3 笔时使用（短码由「头部冻结」保证顺序，不受此处影响）
function M.score(code, text)
  load()
  if not code or code == '' or #code < 3 or not text or text == '' then return 0 end
  local n = data[code .. '\t' .. text]
  -- 至少选中 2 次才生效：避免「误选一次」就把某个候选永久顶到前面
  if not n or n < 2 then return 0 end
  if n > MAX_COUNT then n = MAX_COUNT end
  return n * 400000       -- 2 次 ≈ 80 万，足以在长码候选中上浮
end

-- 由 learning 在落盘时调用，保证与学习库同一节奏写盘
function M.flush()
  if dirty > 0 then
    dirty = 0
    save()
  end
end

function M.clear(env)
  data = {}
  dirty = 0
  save()
end

return M
