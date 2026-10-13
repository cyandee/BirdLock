#!/bin/zsh
# BirdLock 开发辅助脚本
# 作用：执行 Claude 放进 .devloop/queue/ 的任务脚本（编译、测试、训练模型等），
#       把输出写到 .devloop/out/，这样 Claude 就能在你的 Mac 上编译调试。
# 用法：在「终端」里运行   zsh ~/Claude/bird/scripts/devloop.sh
#       随时按 Ctrl-C 停止。每个任务开始时会把脚本内容打印出来，方便你查看。

ROOT="${0:A:h:h}"
Q="$ROOT/.devloop/queue"
O="$ROOT/.devloop/out"
R="$ROOT/.devloop/running"
mkdir -p "$Q" "$O" "$R"
setopt NULL_GLOB

echo "[devloop] 项目目录: $ROOT"
echo "[devloop] 正在等待任务 (Ctrl-C 结束)"
date +%s > "$ROOT/.devloop/heartbeat"

while true; do
  for f in "$Q"/*.sh; do
    id="${f:t:r}"
    mv "$f" "$R/$id.sh" || continue
    echo ""
    echo "[devloop] $(date +%T) ▶ 开始任务 $id"
    sed 's/^/    | /' "$R/$id.sh" | head -40
    (
      cd "$ROOT"
      zsh "$R/$id.sh" > "$O/$id.log" 2>&1
      ec=$?
      echo "$ec" > "$O/$id.exit"
      echo "[devloop] $(date +%T) ■ 任务 $id 结束 (exit=$ec)"
    ) &
  done
  date +%s > "$ROOT/.devloop/heartbeat"
  sleep 1
done
