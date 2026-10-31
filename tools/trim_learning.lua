-- 学习库瘦身工具：分析 / 清理 bg5-learning.user.tsv
--   清理规则（与 learning.lua 一致）：
--     ① 频次 <= 1 且超过 PRUNE_DAYS 天未用 → 删除
--     ② 超过 MAX_ENTRIES 条 → 按「频次低 + 久未用」淘汰
-- 用法：
--   cd lua && lua5.3 ../tools/trim_learning.lua                 # 只分析
--   cd lua && lua5.3 ../tools/trim_learning.lua --apply         # 执行清理（自动备份）
--   cd lua && lua5.3 ../tools/trim_learning.lua --apply --days 90 --max 20000
package.path = './?.lua;' .. package.path

local APPLY = false
local PRUNE_DAYS = 180
local MAX_ENTRIES = 30000
local UD = nil
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == '--apply' then APPLY = true
  elseif a == '--days' then PRUNE_DAYS = tonumber(arg[i + 1]) or PRUNE_DAYS; i = i + 1
  elseif a == '--max' then MAX_ENTRIES = tonumber(arg[i + 1]) or MAX_ENTRIES; i = i + 1
  elseif a == '--dir' then UD = arg[i + 1]; i = i + 1
  end
  i = i + 1
end

local function user_dir()
  if UD then return UD end
  if rime_api and rime_api.get_user_data_dir then
    local d = rime_api:get_user_data_dir()
    if d and d ~= '' then return d end
  end
  return '.'
end

local path = user_dir() .. '/bg5-learning.user.tsv'
local f = io.open(path, 'r')
if not f then
  print('找不到学习库: ' .. path)
  return
end

local now = os.time()
local entries, total = {}, 0
local dist = {}
for line in f:lines() do
  local w, n, ts = line:match('^([^\t]+)\t(%d+)\t(%d+)$')
  if w then
    total = total + 1
    entries[#entries + 1] = { w = w, cnt = tonumber(n), last = tonumber(ts) }
    local bucket = math.min(tonumber(n), 10)
    dist[bucket] = (dist[bucket] or 0) + 1
  end
end
f:close()

print(string.format('学习库: %s', path))
print(string.format('词条 %d 条', total))
for k = 1, 10 do
  if dist[k] then
    print(string.format('  频次 %-2s : %d 条', k == 10 and '10+' or tostring(k), dist[k]))
  end
end

-- 计算清理结果
local stale = PRUNE_DAYS * 86400
local keep, drop = {}, {}
for _, e in ipairs(entries) do
  if e.cnt <= 1 and (now - e.last) > stale then
    drop[#drop + 1] = e
  else
    keep[#keep + 1] = e
  end
end
if #keep > MAX_ENTRIES then
  -- 升序（低频/久未用在前），删掉前面的，保留后面高频的
  table.sort(keep, function(a, b)
    if a.cnt ~= b.cnt then return a.cnt < b.cnt end
    return a.last < b.last
  end)
  local excess = #keep - MAX_ENTRIES
  for j = 1, excess do drop[#drop + 1] = keep[j] end
  local rest = {}
  for j = excess + 1, #keep do rest[#rest + 1] = keep[j] end
  keep = rest
end

print(string.format('\n清理规则: 频次<=1 且 %d 天未用；上限 %d 条', PRUNE_DAYS, MAX_ENTRIES))
print(string.format('将删除 %d 条，保留 %d 条', #drop, #keep))

if not APPLY then
  print('（未写入，加 --apply 执行）')
  return
end
if #drop == 0 then
  print('无需清理')
  return
end

os.execute('cp "' .. path .. '" "' .. path .. '.bak" 2>/dev/null')
local out = assert(io.open(path .. '.tmp', 'w'))
out:write('#\t', tostring(now), '\n')
for _, e in ipairs(keep) do
  out:write(e.w, '\t', tostring(e.cnt), '\t', tostring(e.last), '\n')
end
out:close()
os.rename(path .. '.tmp', path)
print('已写入（备份: ' .. path .. '.bak）')
