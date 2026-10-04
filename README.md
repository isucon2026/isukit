# isukit

リポジトリのURLから1コマンドで、計測できる状態のアプリホストまで持っていく。

**コンテストの立ち回り — フェーズ、チームルール、失敗パターン: [`RUNBOOK.md`](RUNBOOK.md)。**
**本番前の通し練習（AWS・複数台）: [`REHEARSAL.md`](REHEARSAL.md)。**

## インストール

    go install github.com/isucon2026/isukit/cmd/isukit@latest      # 本番は凍結したタグを指定する（@isucon2026 など）

バイナリひとつで完結する（bash のスクリプト `isukit`・`lib/`・`remote/` を埋め込んでいて、初回実行時にキャッシュへ展開する）。`isukit version` で、全員が同じタグ・コミットを使っているかを確かめられる。

Go が無い環境では、従来どおり bash 版も使える：

    curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh | bash

`${ISUKIT_HOME:-$HOME/.isukit-src}` に clone / 更新し、`isukit` を PATH の通る場所にシンボリックリンクする。スクリプトの後ろに続けた引数はそのままインストール直後の `isukit` に渡るので、これは「ゼロから、調査・計測可能な状態のホストまで」を1行で終わらせる本物のワンライナーでもある。

    curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh \
      | bash -s -- go <repo-url> ubuntu@<ip> -i ~/.ssh/key.pem

    ./isukit go <repo-url> <app-ssh-target> [bench-ssh-target] [-i keyfile] [-p port]

チームのリポジトリがまだ無い（競技開始直後）なら `--new` で作る。サーバーの webapp をコードのベースライン、`/etc` の設定と env ファイルを設定のベースラインとして、private リポジトリを作って push する（手順は [`RUNBOOK.md`](RUNBOOK.md) §3）：

    ./isukit go --new <team>/<repo> <app-ssh-target> [bench-ssh-target] -i keyfile [--invite user1,user2]

これで clone → サーバー調査 → `alp` + `pt-query-digest` のインストール → LTSV nginx ログと `long_query_time=0` の有効化 → ベンチマーカー本体の `--help` を読んでの `BENCH_CMD` 組み立て、まで一通り終わる。その行を目視で確認したら、あとはループに入るだけ。

## ループ

    isukit bench "baseline"     # BENCH_CMD をベンチホストで実行し、スコアとgit shaを記録
    isukit alp                  # エンドポイントを合計レスポンスタイム順に（URL のまとめ方はログから自動で作る。--patterns で確認）
    isukit slow                 # クエリを合計時間順に
    isukit pprof 30             # Go CPUプロファイル（pprofが組み込まれていれば）
    isukit attribute            # 直近2回の計測を比較；KEEP / REVERT / INCONCLUSIVE
    # 変更は必ず1つだけ
    isukit deploy                # rsync + build → systemdのExecStartパス → 再起動
    isukit bench "added idx X"   # スコアを記録（manualモードでは値の入力を求められる）
    isukit ship "added idx X"    # 全部commit + push + draft PR、1変更1コミット
    isukit score                 # 全履歴
    isukit show [n]              # 保存した回の結果（1 = 最新、2 = その前）

`logs on` の間の `isukit bench` は、1回ごとに計測を区切って `.isukit/runs/<日時>/` に保存する：ベンチの開始時に全台のログを空にし、ベンチ中は全台の CPU とプロセスごとの使用率を1秒ごとに記録し、app の1台目で負荷がかかっている最中の pprof（`PPROF_SEC` 秒、既定30秒）を取る。終わったら、台ごとの使用率の要約・alp（web の台が複数なら全台のログをまとめて集計）・db の台ごとの slow・`cpu.pprof`・ベンチの出力を保存して、要約を表示する。どの台（どのプロセス）が張り付いていたかで、次に見るもの（slow か pprof か）が決まる。manual モードでも、プロンプトに答えれば同じように記録する。`--score N` で後からスコアだけ入れた場合も、その回の alp / slow は残る（ログは記録のたびに空にしているので、前回の記録以降の分になる）。`logs off` の間は何も計測しない。

## ミドルウェア設定を git で管理

    isukit etc adopt            # /etc の設定を <サーバーの repo>/etc/<同じパス> に移し、/etc からリンク
    isukit etc status           # repo の各ファイルを /etc が本当に読んでいるか
    isukit etc push             # 手元の etc/ → サーバー。変わった層だけ reload / restart
    isukit etc pull             # サーバーの etc/ → 手元の etc/

`adopt` は `nginx.conf`・有効なサイト設定・`[mysqld]` を含む `.cnf`・アプリの unit ファイルを自動で探し、それぞれ `<サーバーの repo>/etc/`（例：`etc/nginx/sites-available/isucon.conf`）に移して `/etc` からシンボリックリンクを張る。置き換えたファイルは `/etc/isukit-orig/<同じパス>` にバックアップする（`sites-enabled/*` などの include で読み込まれないよう、元の場所には置かない）。そのあと層ごとに確認し（`nginx -t` + reload、`daemon-reload`、mysql 再起動 + mysql ユーザーがリンク先を読めるか + 設定値が実際に反映されているか）、失敗した層だけ元に戻す。Ubuntu では、mysqld がリンク先を読めるように AppArmor の許可も追加する。repo にすでに同じファイルがあれば（repo からサーバーを作り直す場合）、repo 側が優先される。`/etc` がリンク済みなら、`deploy` が先に `etc push` を行う。サーバー側の repo は、probe で見つけた `SRC_DIR` の git ルート（`.isukit/config` の `ETC_REPO` で上書き可）。サーバー側で動くスクリプトは `remote/` にある。複数台では `etc pull` が全台から取り込み、台ごとに中身が違うファイル（db の台だけ調整した `mysqld.cnf` など）は、どちらかで黙って上書きしないよう取り込まずに知らせる。

`isukit probe` はスコア付きヒューリスティックでアプリのsystemd unitを選ぶ。保証ではない — 理由は下の「なぜリポジトリを読まずにサーバーに聞くのか」を参照。選択が外れていたら：

    isukit unit <systemd-unit-name>   # 上書き + 再probe

診断用：

    isukit doctor               # config / 接続性 / ベンチモードの非破壊チェック＋自動修復

終盤：

    isukit final check           # スコアを削る出力（access_log・スローログ・ロガー・pprof・計測の残り）の一覧
    isukit final apply           # 設定で止められるものを etc/ の差分として止め、全台を片付ける
    isukit finalize              # ログOFF → 全ホスト再起動 → unit確認 → スコア計測

## なぜリポジトリを読まずにサーバーに聞くのか

ISUCONのリポジトリ構成は何ひとつ安定していない。isucon9, 10-q, 10-f, 11-q, 11-f, 12-q, 12-f, 13, 14, private-isu を横断して確認した限り、以下は全部年によって変わっている：

| 項目 | 確認された範囲 |
|---|---|
| Goのソースディレクトリ | `webapp/go`, `webapp/golang` |
| 言語セット | 4〜8実装；Denoが1回、Javaが1回、Perlは出たり消えたり |
| ビルドツール | Makefile → Taskfile.yml → どちらも無し |
| docker-compose | root / 言語別 / `development/` / `dev/` / **丸ごと無し**（10-f, 12-f） |
| systemdの命名 | `app.lang.service`, `app-lang.service`, `app-api-lang.service` + `app-web-lang.service`、言語非依存のラッパーunitが1つだけの年も |
| 追加unit | matcher、payment mock、JIA API mock、PowerDNS、shipment/payment simulator |
| envファイル | `/home/isucon/env.sh`, `/home/isucon/env`, 無し |
| 環境変数名 | `ISUCON13_MYSQL_*`（年プレフィックス付き）→ `ISUCON_DB_*`（年非依存）→ その場しのぎの `MYSQL_*` |
| webサーバー | nginx — **ただしisucon10-finalだけEnvoy** |
| データストア | MySQL 5.7 / 8.0 / 8.0.31、MariaDB 10.3、＋テナント別SQLite（12-q） |
| ベンチのターゲット指定フラグ | `-target`, `-target-url`, `-target-host`, `-target-addr`, `--target` |
| アプリのインスタンス数 | 3（通常）、5（12-f）、ドキュメント上は1（9） |

補足：**isucon15は存在しない。** 運営は14以降で連番方式をやめており、次のイベントはISUCON2026（2026-10-31、さくらインターネット主催）。`isucon{N+1}` を前提にしたツールを書かないこと。

`isukit probe` はだからこそリポジトリの中身を一切読まない。動いているマシンそのものに聞く：

- **systemdが正。** `/etc/systemd/system` 配下にfragmentを持つunit（＝distro標準ではなく後から入れられたunit）を列挙し、動いているものに `systemctl show` を打って `WorkingDirectory` / `ExecStart` / `EnvironmentFiles` / `User` を取る。この1つのトリックが、上の表の命名規則・Envoyの年・docker-composeラッパーの年、全部を生き延びる。
- webサーバーとデータストアは候補リストへの `is-active` 確認で特定。
- nginxのログパスと設定ファイルは推測ではなく `nginx -T` から取る。
- Goのモジュールディレクトリは `go.mod` を探して特定（`bench*` とvendorは除外）。

ベンチマーカーの起動コマンドも同じ話：年をまたいだ共通のフラグ契約が無いので、`isukit probe`（内部で `isukit benchprobe`）が `$BENCH` 上の `/home/isucon` 配下からベンチマーカーのバイナリを見つけ、そのバイナリ自身の `--help` を読んで `BENCH_CMD` を組み立てる — 詳しくは下の「`BENCH_CMD` は自動生成される、確認すること」を参照。

**既知の限界：** アプリunitの選定はスコア付きヒューリスティック（`/home/isucon` 配下のworkdir、execパス、envファイル、実行ユーザー、…）であって確実ではない。珍しいレイアウトだと本物のアプリunitより高スコアが出ることもある。`isukit probe` はスコアを付けた全候補を `APP_CANDIDATES` として出力し、選択が低信頼のときは警告する。その行は必ず目視確認し、外れていたら `isukit unit <name>` で直す。

## 鉄則（答え固有ではなく一般則）

- **必ず合計時間で並べる。平均でも件数でもない。** 3msのエンドポイントが40,000回呼ばれていれば、900msが2回より重い。ここでの `alp --sort=sum` が既定なのもそのため。`pt-query-digest` も同じ理由で合計時間順。
- **何かを触る前にベンチする。** 記録していないベースラインは、評価できない変更と同義。
- **1回のベンチにつき変更は1つ。** 2つ変えてスコアが動いても、何も分からない。
- **計測はスコアを削る。** `long_query_time=0` とLTSVロギングは重い。記録として残したい計測の前には `isukit logs off`。
- **再起動を生き延びないものはカウントされない。** `SET GLOBAL`、手で起動したサービス、`/tmp` のファイル、disabledなunit — ランタイムだけの状態は全部消える。多くのチームが最終計測でここを全部失う。`isukit finalize` がそのチェック。
- **最適化の前にアプリ自身のログを読む。** ベンチマーカーが黙ってリトライしているエラーは、どんなインデックスよりスコアを稼ぐ。

## ファイル

    .isukit/config        APP, BENCH, BENCH_CMD, SSH_OPTS, EXTRA_UNITS, EXTRA_HOSTS, BENCH_MODE
    .isukit/manifest      probeの出力。他の全コマンドがこれを読む
    .isukit/scores.tsv    日時 / sha / スコア / メモ / 生ログへのパス
    .isukit/bench-*.log   ベンチマーカーの生出力（実行ごと）

全部git-ignore済み。`.isukit/` はcloneした各問題リポジトリの中に入るので、複数のコンテストが互いに干渉せず同居できる。

開発：`bash test/run-all.sh`（オフラインのテスト）、`bash test/e2e/run.sh`（Docker の中で isukit を通しで動かす）、shellcheck（コマンドは [`test/README.md`](test/README.md)）。3つとも PR ごとに CI で回る。

Go への移行：`cmd/isukit` が入口（cobra）。まだ移していないコマンドは、埋め込んだ bash にそのまま渡す（`internal/shell`）。設定・ホスト・実行は `internal/config`・`hosts`・`runner` を `internal/app` にまとめて各コマンドに渡す。1つ移すときは、`internal/cli` に Go のコマンドを書き、`Passthrough` から外し、bash 版と出力が完全に一致するテストを付ける（`TestHostsMatchesBash` が例）。今 Go で動くのは `version` と `hosts`。

複数人での作業：2人ともブランチで開発し、サーバーは `isukit lock` / `unlock` で交代で使う。`deploy` は未コミットの変更や main を含まないブランチを止め、deploy したものをサーバーに記録する。ベンチの記録は `isukit-runs` ブランチで共有され、`attribute` は main の最新の回と比べる（RUNBOOK §4）。

Discord への通知：`.isukit/config` に `DISCORD_WEBHOOK_BENCH`（bench の結果）と `DISCORD_WEBHOOK_OPS`（lock / unlock・deploy・final・finalize）を書くと、isukit が流す（チャンネルの構成は RUNBOOK §3.6）。

チームでの共有：役割（`isukit.hosts`）・チーム共通の設定（`isukit.conf`）・各台の env ファイル（`hosts/<台>/`）・設定（`etc/`）は repo に commit して3人で共有する。各自の手元に残るのは ssh 先や鍵（`.isukit/config`）と、probe の結果・計測の記録（`.isukit/`）だけ。

コードの置き場所：`isukit` は入口だけ（設定・`lib/` の読み込み・ヘルプ・コマンドの振り分け）。手元で動く処理は `lib/` に機能ごと（`core`・`hosts`・`probe`・`logs`・`etc`・`runs`・`analyze`・`deploy`・`repo`・`go`・`doctor`）、サーバー側で動く処理は `remote/` に普通のスクリプトとして置き、isukit は ssh で送るだけ。

サブディレクトリ：[`launch/`](launch/README.md) はAWSでの競技前ステージングとインスタンス起動スクリプト。[`skills/isucon/`](skills/isucon/SKILL.md) は計測 → 診断 → 修正 → ship → 再計測ループ用のClaude skill。[`test/`](test/) は過去の全ISUCONの実際のsystemd unitと設定を使って発見ロジックをオフライン検証するフィクスチャ集。

## 注意点

- **`BENCH_CMD` は自動生成される、確認すること。** `isukit benchprobe` は `/home/isucon` 配下で最大サイズのELFバイナリのうちベンチマーカーらしい名前のものを選び、その `--help` を読んで、見つかったtarget/nameserver系フラグから `sudo -iu <owner> sh -c '...'` を組み立てる — ここが一番人間の手直しが必要になりやすい行。読み取り元のフラグ一覧全部は `.isukit/bench-help.txt` に残る。修正は `isukit benchcmd '<command>'`（引数無しだと現在値を表示）。`isukit benchprobe` は一度手で設定した `BENCH_CMD` を上書きしない。
- `logs on` は `/etc/nginx` を `/etc/nginx.isukit.bak` にバックアップしたうえで、`conf.d/00-isukit.conf` を追加し、既存の `access_log` 行を `#isukit# access_log` としてコメントアウトする（シンボリックリンクの場合はリンク先の実ファイルを編集する）。`logs off` はその目印の付いた変更だけを元に戻す（バックアップは手動復旧用に残すだけ）ので、repo にリンクした設定はリンクのまま、その後のチューニングも消えない。logs が on の間はサーバー側の repo のファイルにこの目印が入るが、`etc pull` で取り除かれる。webサーバーがnginxでない場合、`probe` が警告してwebサイドの `logs` は何もしない。
- MySQLの自動化にはソケット越しのパスワード無し `sudo mysql` が必要。使えない場合 `probe` は `MYSQL_OK=0` と報告する。
- `pprof` には `import _ "net/http/pprof"` とリスナーがアプリ側に必要。エンドポイントが無ければ、コマンド自身が追加すべきスニペットを教えてくれる。
- `deploy` はGoアプリを前提としており、systemdが既にexecしている正確なパスへビルドする。他言語実装は手でデプロイする。
- `SSH_OPTS`（config）は全ての `ssh`/`scp` 呼び出しに付与される — カスタム鍵、カスタムポート、カスタム設定ファイルなど。`ssh` は `-p <port>`、`scp` は `-P <port>` と大文字小文字が違う点に注意 — 手でポートフラグを組み立てる場合は両方の形が要る。
- `EXTRA_UNITS`（config）はスペース区切りの追加unitリストで、`restart`/`finalize` は検出した `APP_UNIT` と一緒にこれらも再起動する — matcher/mock/simulator系のサービスを別unitとして持つ年向け。
- 複数インスタンスは `isukit host role <target> <役割>` で `.isukit/hosts` に役割（`app` / `web` / `db`）を書く。`deploy`・`restart`・`pprof` は app の台、nginx ログと `alp` は web の台、スロークエリと `slow` は db の台、`etc`・`os`・`finalize` は全台で動く。役割は isukit の送り先を決めるだけで、MySQL を止める・`bind-address`・`DB_HOST` などの構成変更は手で行う。`.isukit/hosts` が無いときは `EXTRA_HOSTS`（`isukit host add <target>` で設定）がアプリの台として扱われる。インスタンス間の再起動順は保証されない。
- `BENCH_MODE`（config）は `auto`（`BENCH_CMD` をベンチホストへsshして実行）か `manual`（コンテストポータルで実行をキューし、`isukit bench --score <N>` でスコアを記録）のどちらか。`isukit benchprobe` はベンチマーカーのバイナリが見つからないと自動で `manual` モードを検出する。本番環境（ISUCON11以降）ではベンチマークはWebポータルから起動されssh経由ではないので、`manual` モードは失敗ではなく正しい本番状態。モードの切り替えは `isukit benchmode <mode>`。manualモードでは、合格した実行の記録に `isukit bench --score <N> "<note>"`、エラーで終わった実行の記録に `isukit bench --fail "<note>"` を使う。
- `isukit revert [<sha>]` は `isukit/*` ブランチ上の1コミットを取り消す — 競技中に`scores.tsv`の記録を失わずに悪い変更を戻すときに使う。
