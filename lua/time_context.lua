-- time_context.lua：时段感知（让联想/候选带一点「现在几点」的常识）
--
-- 目的：在**没有强上下文**的情况下，让补全词更贴合当前时段。
--   早上打「早上」→ 「好」更容易出现；深夜 → 「晚安 / 睡觉 / 明天」更容易出现。
--
-- 设计原则（避免乱改排序）：
--   1. 只给「时段相关词」一个**固定小额度**加分（默认 2 万分，与衔接词同级）；
--   2. 只在候选**还没有强上下文分**时生效（cf == 0），不覆盖用户 bigram / 离线语料；
--   3. 全部词都必须在 words.lua 里（否则加了分也出不来）。
--
-- 配置（schema segment_phrase 段）：
--   time_context: true    # 总开关
--   time_weight: 20000    # 加分额度
local M = {}

-- 各时段的关键词（按优先级排列，权重递减）
local PERIODS = {
  { -- 05:00 ~ 09:59 早晨
    from = 5, to = 10,
    words = { '早上', '早安', '起床', '早餐', '上午', '上班', '通勤' },
  },
  { -- 10:00 ~ 13:59 中午
    from = 10, to = 14,
    words = { '中午', '午饭', '吃饭', '午休', '下午' },
  },
  { -- 14:00 ~ 17:59 下午
    from = 14, to = 18,
    words = { '下午', '会议', '下班', '加班' },
  },
  { -- 18:00 ~ 22:59 晚上
    from = 18, to = 23,
    words = { '晚上', '晚饭', '回家', '加班', '休息' },
  },
  { -- 23:00 ~ 04:59 深夜
    from = 23, to = 5,
    words = { '晚安', '睡觉', '明天', '早点', '熬夜' },
  },
}

local WEIGHT = 150000
local ENABLE = true
local cache = {}      -- 按「小时 + 是否周末」缓存

function M.configure(enable, weight)
  if enable ~= nil then ENABLE = enable end
  if weight and weight > 0 then WEIGHT = weight end
end

-- 当前时段标识（小时 + 是否周末），供上层做缓存键
function M.period_key(now)
  now = now or os.time()
  local t = os.date('*t', now) or {}
  local hour = t.hour or 12
  local wday = t.wday or 1     -- 1=周日
  local weekend = (wday == 1 or wday == 7)
  return tostring(hour) .. (weekend and 'w' or 'd')
end

-- 返回 word -> 加分（只包含本时段相关的词）
function M.scores(now)
  if not ENABLE then return {} end
  now = now or os.time()
  local t = os.date('*t', now) or {}
  local hour = t.hour or 12
  local wday = t.wday or 1     -- 1=周日
  local weekend = (wday == 1 or wday == 7)
  local key = tostring(hour) .. (weekend and 'w' or 'd')
  local hit = cache[key]
  if hit then return hit end

  hit = {}
  for _, p in ipairs(PERIODS) do
    local inside
    if p.from < p.to then
      inside = (hour >= p.from and hour < p.to)
    else
      inside = (hour >= p.from or hour < p.to)
    end
    if inside then
      for i, w in ipairs(p.words) do
        hit[w] = WEIGHT - (i - 1) * 2000
      end
    end
  end
  -- 周末：休息/周末 加点
  if weekend then
    hit['周末'] = WEIGHT
    hit['休息'] = WEIGHT - 2000
  end
  cache[key] = hit
  return hit
end

return M
