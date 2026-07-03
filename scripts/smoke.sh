#!/usr/bin/env bash
set -euo pipefail

echo "[1/4] services healthy?"
docker compose ps

echo "[2/4] generating telemetry via claude (headless)..."
# 新しい claude プロセスを1回起動してテレメトリを発生させる
if command -v timeout >/dev/null 2>&1; then
  timeout 60 claude -p "reply with the single word: pong" >/dev/null 2>&1 || echo "  (claude 実行に失敗しても、既存の利用分があれば以降の確認は通り得る)"
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout 60 claude -p "reply with the single word: pong" >/dev/null 2>&1 || echo "  (claude 実行に失敗しても、既存の利用分があれば以降の確認は通り得る)"
else
  claude -p "reply with the single word: pong" >/dev/null 2>&1 || echo "  (claude 実行に失敗しても、既存の利用分があれば以降の確認は通り得る)"
fi
echo "  waiting for export interval (~15s)..."
sleep 15

echo "[3/4] Prometheus: claude_code metrics present?"
NAMES=$(curl -s 'http://localhost:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep claude_code || true)
if [ -z "$NAMES" ]; then
  echo "  NG: claude_code_* メトリクスがまだ見つかりません（claude を数回使ってから再実行）"
else
  echo "  OK: 見つかったメトリクス:"; echo "$NAMES" | sed 's/^/    /'
fi

echo "[4/4] Loki: claude-code logs present?"
END=$(date +%s)000000000
START=$(( $(date +%s) - 3600 ))000000000
RES=$(curl -s -G 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={service_name="claude-code"}' \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode 'limit=5' || true)
if echo "$RES" | grep -q '"values"'; then
  echo "  OK: Loki に claude-code のログが存在"
else
  echo "  NG: Loki にまだログがありません（claude を使ってから再実行）"
fi
echo "done."
