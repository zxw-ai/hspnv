-- lua/demote.lua
-- 手动降权处理器：对当前高亮候选降权（支持任意候选词，包括静态词典词）
--
-- 处理器挂载：lua_processor@*demote（librime-lua 调用模块的 func 字段）
-- 触发键：皮肤「降权」键发送 ]（Rime 键名 bracketright）；桌面 Control+Delete
--   1) 把该词写入用户降权词表 demote.user.tsv（任意词都记录；再次按取消降权）
--   2) 若该词在学习数据中，同时 learning.demote 减半频次
--   3) 尝试立即从当前候选移除并刷新候选，让效果立即可见
-- 无候选时也消费降权键，避免穿透成标点输出。
--
-- 降权效果的最终呈现由独立过滤器 lua/demote_filter.lua 完成（沉底/隐藏）。
--
-- 配置（stroke_bg5cgq_learning.schema.yaml）：
--   demote:
--     key: "Control+Delete"   # 桌面触发键
--     mode: demote            # demote=沉底（默认）；hide=直接隐藏

local learning = require('learning')

local M = {}

local DEMOTE_FILE = 'demote.user.tsv'

local demoted = {}          -- word -> true
local loaded = false
local path = nil

------------------------------------------------------------
-- 一、降权词表持久化（任意词）
------------------------------------------------------------

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
  path = user_dir() .. '/' .. DEMOTE_FILE
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      local w = line:match('^([^\t]+)\t%d+$') or line:match('^([^\t]+)$')
      if w and w ~= '' then
        demoted[w] = true
      end
    end
    f:close()
  end
end

local function save()
  if not path then return end
  local tmp = path .. '.tmp.' .. tostring(math.random(100000, 999999))
  local f = nil
  local ok = pcall(function()
    f = assert(io.open(tmp, 'w'))
    local now = os.time()
    for w in pairs(demoted) do
      f:write(w, '\t', tostring(now), '\n')
    end
    f:close()
    f = nil
    os.rename(tmp, path)
  end)
  if f then
    pcall(function() f:close() end)
  end
  if not ok then
    pcall(os.remove, tmp)
  end
end

------------------------------------------------------------
-- 二、配置读取
------------------------------------------------------------

local function get_config(env)
  if env and env.engine and env.engine.schema and env.engine.schema.config then
    return env.engine.schema.config
  end
  return nil
end

local function get_trigger_key(env)
  local config = get_config(env)
  if config then
    local k = config:get_string('demote/key')
    if k and k ~= '' then return k end
  end
  return 'Control+Delete'
end

------------------------------------------------------------
-- 三、处理器（librime-lua 调用 func 字段）
------------------------------------------------------------

function M.func(key_event, env)
  local key_repr = key_event:repr()
  local trigger = get_trigger_key(env)

  -- 是否为降权键：配置键 / Control+Delete / ] / bracketright
  local is_demote_key =
    key_repr == trigger or
    key_repr == 'Control+Delete' or
    key_repr == ']' or
    key_repr == 'bracketright'

  if not is_demote_key then
    return 2  -- kNoop：不是降权键
  end

  local ctx = env.engine and env.engine.context
  if not ctx or not ctx:has_menu() then
    return 1  -- kAccepted：无候选也消费降权键，避免输出标点
  end

  local cand = ctx:get_selected_candidate()
  local text = cand and cand.text or ''
  if text ~= '' then
    load()
    if demoted[text] then
      demoted[text] = nil   -- 已在降权表：取消降权
    else
      demoted[text] = true  -- 降权（任意词）
    end
    save()

    -- 若该词在学习数据中，同时降低学习频次（双保险）
    pcall(function()
      learning.demote(text, env)
    end)

    -- 尝试立即移除当前候选（对 Lua 候选可能无效，失败无妨）
    pcall(function()
      ctx:delete_current_selection()
    end)

    -- 强制重新生成候选，让降权效果（沉底/隐藏）立刻可见
    pcall(function()
      ctx:refresh_non_confirmed_composition()
    end)
  end
  return 1  -- kAccepted：按键已被消费，不再输出字符
end

return M