#!/bin/sh
# 把元书 Rime 用户目录里的学习数据备份，同步到 Minis 共享目录
#   （元书 App 与 Minis/iSH 是两个独立沙盒，元书的 lua 写不到 /var/minis/shared，
#     所以由 iSH 侧定时「拉」过去）
#
# 用法：
#   sh sync_backup.sh                 # 自动探测挂载点
#   sh sync_backup.sh <源目录> [目标目录]
#
# 自动探测：在 /var/minis/mounts/*/ 下找含 bg5-learning.user.tsv 的目录。

SRC="$1"
DST="${2:-/var/minis/shared/bg5-backup}"

if [ -z "$SRC" ]; then
  for d in /var/minis/mounts/*/; do
    if [ -f "$d/bg5-learning.user.tsv" ] || [ -f "$d/Rime/bg5-learning.user.tsv" ]; then
      SRC="$d"
      break
    fi
    if [ -f "$d/Rime/bg5-learning.user.tsv" ]; then
      SRC="$d/Rime"
      break
    fi
  done
fi

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "未找到元书用户目录（需要先把元书的 Rime 目录挂载到 Minis 共享文件夹）"
  echo "用法: sh sync_backup.sh <元书用户目录> [目标目录]"
  exit 1
fi

mkdir -p "$DST" || { echo "无法创建 $DST"; exit 1; }

n=0
# 逐个前缀处理（busybox ash 关掉 nullglob，未匹配的通配符不会展开，
# 所以在 $SRC 目录里用 ls 生成真实文件名，避免把字面量 "x.*" 当成文件）
for base in bg5-learning.user.tsv bg5-ngram.user.tsv pos_memory.tsv; do
  for f in "$SRC/$base" "$SRC/$base".*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DST/" 2>/dev/null && n=$((n + 1))
  done
done

echo "已同步 $n 个文件：$SRC → $DST"
ls -lh "$DST" 2>/dev/null | tail -n +2 | awk '{print "  " $5, $9}'
