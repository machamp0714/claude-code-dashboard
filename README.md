# Claude Code Usage Dashboard (local, Grafana)

Claude Code の OpenTelemetry テレメトリをローカル Docker で受け、Grafana で可視化する個人用スタック。

## 構成
- OTel Collector (contrib) : OTLP 受信 → metrics を Prometheus 形式で公開、logs を Loki へ転送
- Prometheus : メトリクス保存（既定 90 日）
- Loki : イベントログ保存（既定 30 日、メタデータのみ）
- Grafana : ダッシュボード3枚（Overview / Cost & Tokens / Tools & Activity）

## セットアップ

```bash
cp .env.example .env     # 必要ならポート/保持期間を編集
make up                  # スタック起動
```

### Claude Code 側の設定
`claude-settings-snippet.json` の `env` を `~/.claude/settings.json` の `env` にマージする。
（本リポジトリの Task 5 で自動マージ済みなら不要。）マージ後、新しく `claude` を起動すると
テレメトリが送られる。

本文テキストは記録しない設定。ツールのコマンド/ファイルパスまで見たい場合のみ
`~/.claude/settings.json` の env に `"OTEL_LOG_TOOL_DETAILS": "1"` を追加する。

## 動作確認

```bash
make smoke     # claude を1回起動し、Prometheus と Loki に実データが入るか検証
make names     # Prometheus に入っている claude_code_* メトリクス名を列挙
```

Grafana: http://localhost:3000 （admin / admin）→ フォルダ "Claude Code"

## 停止 / データ削除

```bash
make down                       # コンテナ停止（データは volume に残る）
docker compose down -v          # データも含めて完全削除
```

## config を変更したとき（otelcol / loki / prometheus）

`docker-compose.yml` の各サービスは `config.yaml` 等をホストからボリュームマウントしているだけなので、
**config ファイルを編集しても `docker compose up -d` だけでは稼働中のコンテナは古い config のまま動き続ける**（コンテナ自体に変更差分が無いため再作成が起きない）。
実際に、開発中は logs pipeline を otelcol の config に追加した後 `docker compose up -d` を叩いても反映されず、
`:4318/v1/logs` が 404 を返し続ける事象が確認されている。

config を変更した後は、以下のいずれかで明示的に反映させること：

```bash
make reload                                    # 全サービスを force-recreate
# または特定サービスだけ
docker compose up -d --force-recreate otelcol
# または一旦落として立て直す
make down && make up
```

**初回のクリーンな `make up`（あるいは `down` した直後の `up`）では、コンテナが config ファイルの現在の内容で新規作成されるためこの問題は起きない。** 増分での config 編集時にのみ注意すればよい。

## 保持期間の変更
- Prometheus: `.env` の `PROMETHEUS_RETENTION`（例 `90d`）を変更して `make up`
- Loki: `loki/config.yaml` の `limits_config.retention_period`（時間単位, `720h`=30日）を変更して再起動（config 変更なので上記の `make reload` が必要）

## メトリクス名について（実名）

Prometheus exporter は単位をメトリクス名に挿入するため、Claude Code の OTel ドキュメント上の想定名と実際に `/metrics` に出る名前が一致しない項目がある。本スタックのダッシュボード・トラブルシュートは以下の**実名**を前提にしている。

| 用途 | 実名 |
|---|---|
| コスト | `claude_code_cost_usage_USD_total` |
| トークン | `claude_code_token_usage_tokens_total` |
| アクティブ時間 | `claude_code_active_time_seconds_total` |
| セッション数 | `claude_code_session_count_total` |

想定と違う名前が出た場合は `make names` で実名を確認し、`grafana/provisioning/dashboards/json/*.json` のクエリを合わせること。

## トラブルシュート
- **ダッシュボードが空**: `claude` をまだ使っていない。数回対話してから `make smoke`。
  それでも空なら `make names` でメトリクス名を確認し、想定名と違う場合はダッシュボード JSON の
  クエリを実名に合わせる（`grafana/provisioning/dashboards/json/*.json`）。
- **collector にデータが来ない**: `~/.claude/settings.json` の env が反映されているか、
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` が正しいか確認。`docker compose logs otelcol`。
  config を変更した直後にこれが起きている場合は上記「config を変更したとき」を参照（`make reload` で解決することが多い）。
- **ポート競合**: `.env` の各 `*_PORT` を変更して `make up`。
- **Grafana に `admin:admin` でログインできない（API が 401 を返す）**: `grafana-data` volume が過去の起動から残っており、
  DB 内の admin パスワードが `.env` の `GF_SECURITY_ADMIN_PASSWORD` と食い違っている場合に起きる
  （`GF_SECURITY_ADMIN_PASSWORD` は volume 初回作成時にしか admin パスワードへ反映されない）。
  `docker compose exec grafana grafana-cli admin reset-admin-password admin` でリセットするか、
  データを気にしないなら `docker compose down -v && make up` で volume ごと作り直す。
- **`sum()` や `rate()`/`increase()` で書いたクエリが空になる、または 0 になる**:
  Claude Code のメトリクスは `session_id` ラベル付きの cumulative カウンタで、セッション終了後は
  collector 側の `/metrics` から stale 化して系列が消える（既定 `metric_expiration: 5m`）。
  そのため素朴に `sum(metric)`（瞬時値）を書くとアクティブセッションが無い限り空になり、
  `increase(metric[range])` もスクレイプ間隔の関係で 0 になりやすい。本スタックのダッシュボードは
  各 session_id 系列の最終値（plateau）を `max_over_time(metric[range])` で取ってから `sum` で
  合算する方式で回避している。カスタムパネルを自作する場合も `sum(max_over_time(metric[$__range]))`
  のパターンを使うこと（`sum(increase(...))` や素の `sum(metric)` は使わない）。
