-- BG5 n-gram v1：轻量级上下文联想模块
-- 为 segment_phrase 提供“上下文分”（cf），让笔画输入在连续输入时候选更精准：
--   1. 词级 bigram：前一个上屏词 -> 下一个词（用于词组候选排序）
--   2. 字级 bigram：前一个上屏词 -> 下一个词的首字（用于单字候选排序）
-- 数据保存在用户目录 bg5-ngram.user.tsv，配置在 schema 的 ngram: 段。

local M = {}
local loaded = false
local data = {}         -- 前词..'\t'..后词 -> 次数
local char_data = {}    -- 前词..'\t'..首字 -> 次数
local path = nil
local prev_commit = nil
local last_commit = nil
local save_counter = 0
local SAVE_INTERVAL = 8

-- 配置默认值（可由 schema 的 ngram: 段覆盖）
local ENABLED = true
local WORD_STEP = 100000
local WORD_CAP = 3
local CHAR_STEP = 100000
local CHAR_CAP = 2

local function user_dir()
  if rime_api and rime_api.get_user_data_dir then
    local d = rime_api:get_user_data_dir()
    if d and d ~= '' then return d end
  end
  return '.'
end

local function utf8_chars(s)
  local t = {}
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    t[#t + 1] = ch
  end
  return t
end

local function chinese_only(s)
  if not s or s == '' then return false end
  local chars = utf8_chars(s)
  if #chars == 0 then return false end
  for _, ch in ipairs(chars) do
    if #ch < 3 or ch:byte() < 0x80 then return false end
  end
  return true
end

local function load_config(env)
  if not env or not env.engine or not env.engine.schema or not env.engine.schema.config then return end
  local cfg = env.engine.schema.config
  local v
  v = cfg:get_bool("ngram/enable")
  if v ~= nil then ENABLED = v end
  v = cfg:get_int("ngram/word_weight")
  if v then WORD_STEP = v end
  v = cfg:get_int("ngram/word_cap")
  if v then WORD_CAP = v end
  v = cfg:get_int("ngram/char_weight")
  if v then CHAR_STEP = v end
  v = cfg:get_int("ngram/char_cap")
  if v then CHAR_CAP = v end
end

local function load(env)
  if loaded then return end
  loaded = true
  load_config(env)
  local d = user_dir()
  path = d .. '/bg5-ngram.user.tsv'
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      local kind, a, b, n = line:match('^([WC])\t([^\t]+)\t([^\t]+)\t(%d+)$')
      if kind == 'W' then
        data[a .. '\t' .. b] = tonumber(n)
      elseif kind == 'C' then
        char_data[a .. '\t' .. b] = tonumber(n)
      end
    end
    f:close()
  end
end

local function safe_save(p, t1, t2)
  local tmp = p .. '.tmp.' .. tostring(math.random(100000, 999999))
  local f = nil
  local ok = pcall(function()
    f = assert(io.open(tmp, 'w'))
    for k, n in pairs(t1) do
      local a, b = k:match('^([^\t]+)\t([^\t]+)$')
      if a and b then f:write('W\t', a, '\t', b, '\t', tostring(n), '\n') end
    end
    for k, n in pairs(t2) do
      local a, b = k:match('^([^\t]+)\t([^\t]+)$')
      if a and b then f:write('C\t', a, '\t', b, '\t', tostring(n), '\n') end
    end
    f:close()
    f = nil
    os.rename(tmp, p)
  end)
  if f then pcall(function() f:close() end) end
  if not ok then pcall(os.remove, tmp) end
end

local function save()
  if path then safe_save(path, data, char_data) end
end

function M.word_freq(prev, w, env)
  load(env)
  if not ENABLED or not prev or prev == '' or not w or w == '' then return 0 end
  local n = data[prev .. '\t' .. w]
  if n then return math.min(n, WORD_CAP) * WORD_STEP end
  return 0
end

function M.char_freq(prev, ch, env)
  load(env)
  if not ENABLED or not prev or prev == '' or not ch or ch == '' then return 0 end
  local n = char_data[prev .. '\t' .. ch]
  if n then return math.min(n, CHAR_CAP) * CHAR_STEP end
  return 0
end

function M.get_last_commit()
  return last_commit
end

local function learn_pair(prev, cur)
  if not prev or prev == '' or not cur or cur == '' then return end
  if not chinese_only(prev) or not chinese_only(cur) then return end
  local wk = prev .. '\t' .. cur
  data[wk] = (data[wk] or 0) + 1
  -- 记录 前词 -> 当前词首字
  local chars = utf8_chars(cur)
  local first = chars[1]
  if first then
    local ck = prev .. '\t' .. first
    char_data[ck] = (char_data[ck] or 0) + 1
  end
end

function M.attach(env)
  if not env or not env.engine or not env.engine.context then return false end
  load(env)
  if not ENABLED then return true end
  local c = env.engine.context
  if not c.commit_notifier then return false end
  if env._bg5_ngram_connected then return true end
  local function on_commit(ctx)
    local text = ctx:get_commit_text() or ''
    if text ~= '' and chinese_only(text) then
      if prev_commit and prev_commit ~= text then
        learn_pair(prev_commit, text)
      end
      prev_commit = text
      last_commit = text
      save_counter = save_counter + 1
      if save_counter >= SAVE_INTERVAL then
        save_counter = 0
        save()
      end
    end
  end
  c.commit_notifier:connect(on_commit)
  env._bg5_ngram_connected = true
  return true
end

return M