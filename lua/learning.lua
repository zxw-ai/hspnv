-- BG5 learning v11: 高性能、健壮可靠的词组自学习与单字调频系统
-- 1. 静态词与新造词统一调频：使用频次优先；
-- 2. 学习词自动构建 O(1) 前缀索引：杜绝 DFS 性能卡顿；
-- 3. 安全的文件 I/O：原子重命名与 pcall 异常防护；
-- 4. 上屏写入合并（每 4 次上屏落盘一次），杜绝连续上屏卡顿；
-- 5. 纯净度保障：不输出任何 comment 或数字编码。
-- 6. 时间衰减遗忘机制（v11 新增）：长期未使用的字/词按半衰期自动降权，
--    衰减到 0 的条目彻底遗忘（清除），避免选错的词永远占据高位，
--    使笔画方案具备类似万象的双向调频能力（自动加权 + 时间降权）。
-- 7. 用户词频极端保护（v12 新增）：借鉴讯飞 UsrWordExtremeInfo 思路，
--    用户词频设置上限 MAX_UF，防止连续上屏导致频次无限增长、长期霸榜；
--    高频保护下限 MIN_FREQ 同步降低，与上限匹配（衰减到下限即停止）。

local M = {}
local loaded = false
local data = {}             -- 文字/词组 -> { cnt=累计上屏频次, last=最后上屏时间戳 }（唯一持久化数据源）
local learned = {}          -- 所有学习到的多字词组 -> 频次
local learned_chars = {}    -- 学习到的单字 -> 频次
local learned_prefix = {}   -- 学习词组的前缀哈希集合 -> true
local path = nil
local revision = 0
local save_counter = 0
local SAVE_INTERVAL = 4     -- 每 4 次上屏合并落盘一次，减少写盘卡顿
local HALF_LIFE_DAYS = 30   -- 半衰期：30 天未使用，权重减半
local DECAY_MIN_ELAPSED = 86400   -- 至少间隔 1 天（86400 秒）才执行一次衰减
local MIN_FREQ = 8          -- 衰减下限：上屏频次达到该值的词，衰减到此即停止（高频词保护）
local MAX_UF = 10           -- 用户词频上限：单条用户词累计频次封顶，防止霸榜（极端保护）
local last_decay_time = 0

-- 降权词集合（demote.user.tsv）：被手动降权的词不再被学习（对标讯飞 UserWordDelManager，
-- 防止「删了又学」）。带 TTL 缓存，取消降权后最多 DEMOTE_TTL 秒内重新生效。
local demoted = {}
local demoted_loaded_at = 0
local DEMOTE_TTL = 30

-- 偏旁部首不参与学习：必须完整码输入才出现在候选区，不能通过学习调频。
local NON_LEARNING_RADICALS = {}
for ch in ("氵亻艹扌辶讠纟饣忄阝宀疒礻衤钅彳犭夂攵冖冂勹匚廴彡卩厶巛灬爫户戈攴疋癶缶聿艮豸"):gmatch("[\1-\127\194-\244][\128-\191]*") do
  NON_LEARNING_RADICALS[ch] = true
end

function M.revision() return revision end

local function user_dir()
  if rime_api and rime_api.get_user_data_dir then
    local d = rime_api:get_user_data_dir()
    if d and d ~= '' then return d end
  end
  return '.'
end

-- 加载降权词表（TTL 缓存；取消降权后最多 DEMOTE_TTL 秒内重新生效）
local function ensure_demoted()
  local now = os.time()
  if demoted_loaded_at > 0 and now - demoted_loaded_at < DEMOTE_TTL then return end
  demoted_loaded_at = now
  demoted = {}
  local p = user_dir() .. '/demote.user.tsv'
  local f = io.open(p, 'r')
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

local function utf8_chars(s)
  local t = {}
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    t[#t + 1] = ch
  end
  return t
end

-- 提取汉字，排除所有控制字符、英文字母及单字节符号
local function chinese_only(s)
  if not s or s == '' then return false end
  local chars = utf8_chars(s)
  if #chars == 0 then return false end
  for _, ch in ipairs(chars) do
    if #ch < 3 or ch:byte() < 0x80 then return false end
  end
  return true
end

local function add_learned_prefixes(w)
  local chars = utf8_chars(w)
  if #chars <= 1 then return end
  local prefix = ""
  for i = 1, #chars - 1 do
    prefix = prefix .. chars[i]
    learned_prefix[prefix] = true
  end
end

-- 从 data 重建派生索引（加载/衰减时执行）
local function rebuild_indexes()
  learned = {}
  learned_chars = {}
  learned_prefix = {}
  for w, item in pairs(data) do
    local cnt = item.cnt
    local chars = utf8_chars(w)
    if #chars == 1 then
      -- 偏旁部首不参与学习重建。
      if not NON_LEARNING_RADICALS[w] then
        learned_chars[w] = cnt
      end
    else
      learned[w] = cnt
      add_learned_prefixes(w)
    end
  end
end

-- 时间衰减：对超过阈值的条目按半衰期降低权重，衰减到 0 的彻底遗忘（删除）
local function apply_decay(force)
  local now = os.time()
  if not force and (now - last_decay_time) < DECAY_MIN_ELAPSED then return end
  last_decay_time = now
  local changed = false
  for w, item in pairs(data) do
    local elapsed = now - item.last
    if elapsed > DECAY_MIN_ELAPSED then
      -- 半衰期衰减：factor = 0.5^(elapsed/(HALF_LIFE_DAYS*86400))
      local factor = 0.5 ^ (elapsed / (HALF_LIFE_DAYS * 86400))
      local new_cnt = math.floor(item.cnt * factor + 0.5)
      if item.cnt >= MIN_FREQ and new_cnt < MIN_FREQ then
        -- 高频词保护：衰减到下限即停止，避免高频词被遗忘到不可见
        item.cnt = MIN_FREQ
      elseif new_cnt < 1 then
        data[w] = nil   -- 低频词遗忘：权重归零，彻底移除
      else
        item.cnt = new_cnt
      end
      item.last = now -- 衰减后重置计时，避免重复衰减
      changed = true
    end
  end
  if changed then
    rebuild_indexes()
  end
end

local function load(env)
  if loaded then return end
  loaded = true
  local d = user_dir()
  path = d .. '/bg5-learning.user.tsv'

  local now = os.time()
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      local w, n, ts = line:match('^([^\t]+)\t(%d+)\t(%d+)$')
      if w then
        data[w] = { cnt = tonumber(n), last = tonumber(ts) }
      else
        -- 兼容旧格式：只有 词+频次，没有时间戳，视为“刚使用过”，不立即衰减
        local w2, n2 = line:match('^([^\t]+)\t(%d+)$')
        if w2 then
          data[w2] = { cnt = tonumber(n2), last = now }
        end
      end
    end
    f:close()
  end
  -- 加载后执行一次衰减清理
  apply_decay(true)
  rebuild_indexes()
end

local function safe_save_file(p, table_data)
  if not p then return end
  local tmp = p .. '.tmp.' .. tostring(math.random(100000, 999999))
  local f = nil
  local ok, err = pcall(function()
    f = assert(io.open(tmp, 'w'))
    for w, item in pairs(table_data) do
      f:write(w, '\t', tostring(item.cnt), '\t', tostring(item.last), '\n')
    end
    f:close()
    f = nil
    -- POSIX 原子替换，绝不提前 os.remove
    os.rename(tmp, p)
  end)
  if f then
    pcall(function() f:close() end)
  end
  if not ok then
    pcall(os.remove, tmp)
  end
end

-- 合并落盘：每次上屏只累加计数器，达到间隔才写文件（数据源只有 data 一个表）
local function save()
  if path then
    apply_decay(false)
    safe_save_file(path, data)
  end
end

function M.freq(w, env)
  load(env)
  local item = data[w]
  return item and item.cnt or 0
end

function M.all(env)
  load(env)
  return learned
end

function M.all_chars(env)
  load(env)
  return learned_chars
end

function M.is_learned(w, env)
  load(env)
  return learned[w] ~= nil
end

-- O(1) 哈希查询前缀，彻底避免在大规模学习数据下全表扫描卡顿
function M.has_prefix(prefix, env)
  load(env)
  return learned_prefix[prefix] == true
end

-- 累加频次并更新时间戳（新词则创建）；频次封顶 MAX_UF，防止用户词无限增长霸榜。
local function touch(w)
  local now = os.time()
  local item = data[w]
  if item then
    item.cnt = math.min(item.cnt + 1, MAX_UF)
    item.last = now
  else
    data[w] = { cnt = 1, last = now }
  end
end

function M.add(w, env)
  load(env)
  if not chinese_only(w) then return end
  ensure_demoted()
  -- 降权词永久黑名单：被手动降权的词不再被学习（防止「删了又学」）
  if demoted[w] then return end
  local chars = utf8_chars(w)
  -- 偏旁部首不参与学习，不累计、不调频。
  if #chars == 1 and NON_LEARNING_RADICALS[w] then return end

  touch(w)

  local cnt = data[w].cnt
  if #chars == 1 then
    learned_chars[w] = cnt
  else
    learned[w] = cnt
    add_learned_prefixes(w)
  end

  revision = revision + 1
  -- 合并写盘：每 SAVE_INTERVAL 次上屏才落盘一次，消除连续上屏卡顿
  save_counter = save_counter + 1
  if save_counter >= SAVE_INTERVAL then
    save_counter = 0
    save()
  end
end

local last_commit = nil
local prev_commit = nil
local prev2_commit = nil
local prev3_commit = nil
local recent_commits = {}   -- 最近上屏历史（最新在末尾），用于联想排除已上屏词避免循环

function M.get_last_commit()
  return last_commit
end

function M.get_prev_commit()
  return prev_commit
end

function M.get_prev2_commit()
  return prev2_commit
end

function M.get_prev3_commit()
  return prev3_commit
end

function M.get_recent_commits()
  return recent_commits
end

function M.set_last_commit(text)
  last_commit = text
end

-- 仅更新联想上下文（不调频、不写盘）：供 predict_space 连打上屏「通用兜底词」时使用，
-- 避免 unigram_fallback 的接续词（的/了/吧/啊/是）污染用户学习库导致连打卡死。
function M.touch_context(text, env)
  load(env)
  if not text or text == '' then return end
  if not chinese_only(text) then return end
  prev3_commit = prev2_commit
  prev2_commit = prev_commit
  prev_commit = text
  last_commit = text
  -- 维护最近上屏历史（去重：若已存在则移到末尾；限 12 个）
  for i = #recent_commits, 1, -1 do
    if recent_commits[i] == text then
      table.remove(recent_commits, i)
    end
  end
  recent_commits[#recent_commits + 1] = text
  if #recent_commits > 12 then
    table.remove(recent_commits, 1)
  end
end

-- 手动提交通知：供 predict_space（空格连打）在 commit_text 后调用，
-- 模拟正常 commit 的联想上下文更新（last/prev/prev2/prev3 + 组合造词 + 调频）。
-- 因为 commit_text 不触发 commit_notifier，若不手动更新，下一轮联想不会生成。
function M.notify_commit(text, env)
  load(env)
  if not text or text == '' then return end
  if not chinese_only(text) then return end
  if prev_commit and prev_commit ~= text then
    local combined = prev_commit .. text
    if chinese_only(combined) then
      M.learn_word(combined, env)
    end
  end
  prev3_commit = prev2_commit
  prev2_commit = prev_commit
  M.add(text, env)
  prev_commit = text
  last_commit = text
  -- 维护最近上屏历史（去重：若已存在则移到末尾；限 12 个）
  for i = #recent_commits, 1, -1 do
    if recent_commits[i] == text then
      table.remove(recent_commits, i)
    end
  end
  recent_commits[#recent_commits + 1] = text
  if #recent_commits > 12 then
    table.remove(recent_commits, 1)
  end
end

-- 连续上屏组合造词：上一次上屏的字/词 + 本次上屏的字/词 = 新造词（讯飞式造词）
function M.learn_word(w, env)
  load(env)
  if not chinese_only(w) then return end
  ensure_demoted()
  -- 降权词永久黑名单：被手动降权的词不再被学习（防止「删了又学」）
  if demoted[w] then return end
  local chars = utf8_chars(w)
  -- 偏旁部首不参与学习。
  if #chars == 1 and NON_LEARNING_RADICALS[w] then return end

  touch(w)

  local cnt = data[w].cnt
  if #chars == 1 then
    learned_chars[w] = cnt
  else
    learned[w] = cnt
    add_learned_prefixes(w)
  end
  revision = revision + 1
  save_counter = save_counter + 1
  if save_counter >= SAVE_INTERVAL then
    save_counter = 0
    save()
  end
end

-- 手动降权：把某词频次减半，低于 1 则彻底移除（用于候选降权功能键）
function M.demote(w, env)
  load(env)
  if not w or w == '' then return end
  local item = data[w]
  if not item then return end
  item.cnt = math.floor(item.cnt / 2)
  if item.cnt < 1 then
    data[w] = nil
  else
    item.last = os.time()
  end
  rebuild_indexes()
  revision = revision + 1
  save()
end

-- 恢复被降权词的频次（重置排序键调用：撤销降权影响，恢复到降权前顺序）
function M.undemote(w, env)
  load(env)
  if not w or w == '' then return end
  local item = data[w]
  if not item then return end
  item.cnt = math.min(item.cnt * 2, MAX_UF)
  if item.cnt < 1 then
    data[w] = nil
  else
    item.last = os.time()
  end
  rebuild_indexes()
  revision = revision + 1
  save()
end

function M.attach(env)
  -- 挂到 env.engine（所有 Lua 组件共享同一 engine）供其他模块复用同一实例（避免 require 隔离）
  if env.engine then
    env.engine.bg5_learning = M
  end
  env.bg5_learning = M  -- 兼容旧引用
  local c = env.engine and env.engine.context
  if not c or not c.commit_notifier then return false end
  -- 避免重复挂接
  if env._bg5_learning_connected then return true end
  local function on_commit(ctx)
    local text = ctx:get_commit_text() or ''
    if text ~= '' and chinese_only(text) then
      -- 连续上屏组合造词：上一次上屏 + 本次上屏 = 新造词（若组合仍为纯中文）
      if prev_commit and prev_commit ~= text then
        local combined = prev_commit .. text
        if chinese_only(combined) then
          M.learn_word(combined, env)
        end
      end
      prev3_commit = prev2_commit
      prev2_commit = prev_commit
      M.add(text, env)
      prev_commit = text
      last_commit = text
      -- 维护最近上屏历史
      for i = #recent_commits, 1, -1 do
        if recent_commits[i] == text then
          table.remove(recent_commits, i)
        end
      end
      recent_commits[#recent_commits + 1] = text
      if #recent_commits > 12 then
        table.remove(recent_commits, 1)
      end
    end
  end
  c.commit_notifier:connect(on_commit)
  env._bg5_learning_connected = true
  return true
end

return M