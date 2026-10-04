# 通し練習の手順書（AWS・複数台）

本番（ISUCON2026、2026-10-31）と同じ流れを、過去問で頭から最後まで一度通す。**目的はスコアではなく、手順と isukit が本番で詰まらないことを確かめること。** 各ステップで「確認すること」が通らなければ、その場で止めて記録シート（末尾）に書く。

- 題材：isucon14（matsuu の AMI `ami-0fcf9e8e8675a9ee4`、2026-09-28 検証済み。アプリ・nginx・MySQL・ベンチマーカーが入っている）
- 構成：競技用 3台（c5.large）＋ ベンチ用 1台。本番と同じ形
- 所要：4〜5時間（AWS 料金はおよそ c5.large × 4台 × 5時間）
- 役割分担：**リポジトリ係**（§2 のリポジトリ作成）、**ベンチ係**（ベンチを流すのは1人だけ）、**記録係**（時刻と詰まった点を書く）

---

## 0. 前日まで

**全員**

```
go install github.com/isucon2026/isukit/cmd/isukit@latest
isukit version              # 全員で表示を突き合わせる（本番は凍結タグを指定する）
gh auth status              # リポジトリ係は必須（go --new が gh で作る）
```

- [ ] 全員の `isukit version` が同じ
- [ ] 鍵ファイル（`isukit.pem`）を受け取り、`chmod 600` 済み

**リポジトリ係（AWS 担当）**

```
aws sso login --profile sandbox
export AWS_PROFILE=sandbox AWS_REGION=ap-northeast-1
aws sts get-caller-identity          # 別アカウントに立てていないか
launch/prestage.sh --key-name isukit --key-file ~/claude-workspace/isukit.pem \
  --region ap-northeast-1 --sg-name isukit-ssh \
  --allow-ip <メンバー2のIP> --allow-ip <メンバー3のIP>
```

- [ ] prestage が出力した「許可した CIDR の一覧」に、全員の IP がある（**起動後は変えられない**）

---

## 1. 起動（本番の T+0:00〜0:10 に相当）

```
launch/launch.sh --ami ami-0fcf9e8e8675a9ee4 --type c5.large --count 4 \
  --name-prefix isucon --root-gb 30 --yes
```

`isucon-1`〜`3` を競技用、`isucon-4` をベンチ用にする。表示される **Public IP と Private IP を全部メモする**（以下 `<pub1>`〜`<pub4>`、`<priv1>`〜`<priv3>`）。

- [ ] 4台とも Public IP がついている
- [ ] 全員が `ssh -i isukit.pem ubuntu@<pub1> true` できる

> `launch.sh` が最後に出す案内（`isukit go <repo-url>` / `host add`）は古い。下の §2 に従う。

---

## 2. チームのリポジトリを作る（T+0:10〜0:20）

**リポジトリ係だけ**

```
isukit go --new <team>/isu14-rehearsal-<日付> ubuntu@<pub1> ubuntu@<pub4> \
  -i ~/claude-workspace/isukit.pem --invite <メンバー2>,<メンバー3>
cd isu14-rehearsal-<日付>
```

- [ ] GitHub の `main` に「baseline: …」と「etc: …」の2コミットがある
- [ ] `ssh ubuntu@<pub1> readlink /etc/nginx/nginx.conf` が repo の `etc/` を指す
- [ ] `.gitignore` に、ビルド済みのアプリと 10MB 超のファイルが入っている（大きなファイルを push していない）
- [ ] `hosts/<台>/env.sh` に env ファイルの控えがある

**ベンチの宛先を直す（isukit の不足 #1）**

`benchprobe` は宛先を `127.0.0.1` で組み立てるので、別の台で動くベンチは自分自身を叩いてしまう。ベンチマーカーの `--help`（`.isukit/bench-help.txt`）を見て、宛先を **`<priv1>`** にして設定し直す：

```
cat .isukit/bench-help.txt
isukit benchcmd 'sudo -iu isucon sh -c "cd <ベンチのディレクトリ> && ./<bench> <宛先フラグ> <priv1>..."'
isukit benchmode auto
```

- [ ] `isukit doctor` が全部 OK（ベンチ用の台にも届く）

**メンバー2・3**

```
isukit go git@github.com:<team>/isu14-rehearsal-<日付>.git ubuntu@<pub1> ubuntu@<pub4> -i ~/…/isukit.pem
```

- [ ] 3人とも `isukit hosts` の表示が同じ（**役割は各自の手元にしか保存されない**。isukit の不足 #3）

---

## 3. ベースラインと偵察（T+0:20〜1:00）

```
isukit logs off
isukit bench "baseline"            # 素のスコア
isukit logs on
isukit bench "instrumented"
isukit show                        # 台ごとの CPU・alp・slow・pprof
isukit alp --patterns              # URL のまとめ方がおかしくないか
```

- [ ] `show` の hosts 欄に、CPU とプロセスごとの使用率が出る
- [ ] alp の上位が `/api/[^/]+/…` のように1行にまとまっていない
- [ ] slow に上位のクエリが出る
- [ ] pprof が保存されている（アプリに `net/http/pprof` を入れていなければ「スキップ」と出る。入れるなら次の §4 で）
- [ ] `.isukit/config` に `FINAL_CHECK_PATH` を設定した（**DB を触るエンドポイント**。§7 の確認に使う）

---

## 4. 改善のループを2周（T+1:00〜2:00）

1周目は **設定**、2周目は **コード** を変える。どちらも `deploy → bench → show → attribute → ship` を通す。

```
# 1周目：etc/mysql/... の mysqld.cnf を編集（例：innodb_buffer_pool_size）
isukit deploy                      # etc/ も push される。MySQL の再起動が走る
isukit bench "buffer pool"
isukit show; isukit attribute
isukit ship "mysql: buffer pool"

# 2周目：slow の1位にインデックスを張る、など
isukit deploy
isukit bench "index on …"
isukit show; isukit attribute
isukit ship "index on …"
```

- [ ] `deploy` で MySQL が再起動し、`logs on` の状態が戻っている（`isukit doctor` で確認）
- [ ] `show 2` で1つ前の回と比べられる
- [ ] `attribute` が KEEP / REVERT / INCONCLUSIVE を出す

**戻す練習も1回**：`isukit revert` → `isukit deploy` → `isukit bench`。

- [ ] 戻したあとのスコアが、戻す前の水準に戻る

---

## 5. 構成を分ける（T+2:00〜3:00）

本番で一番時間を食い、ミスも出やすいところ。**isukit は送り先を変えるだけで、構成の変更は手作業**（isukit の不足 #2）。

```
isukit host role ubuntu@<pub1> web,app
isukit host role ubuntu@<pub2> app
isukit host role ubuntu@<pub3> db
isukit etc adopt                    # 2・3台目の設定も repo の etc/ に（台ごとに違うファイルがあれば止まって知らせる）
isukit probe                        # 役割と実態の食い違いを警告する
```

手で行う変更（それぞれ所要時間を記録する）：

1. **db の台（`<pub3>`）**：`etc/` の mysqld.cnf で `bind-address = 0.0.0.0`。他の台から接続するユーザーを作る（`CREATE USER 'isucon'@'%' …; GRANT …`）
2. **app の台（`<pub1>`・`<pub2>`）**：env ファイル（`.isukit/manifest` の `ENV_FILE`）の DB の接続先を `<priv3>` に。**この変更は git に残らない**（isukit の不足 #4）
3. **db 以外の台**：`sudo systemctl disable --now mysql`
4. **web の台（`<pub1>`）**：`etc/` の nginx の upstream に `<priv1>`・`<priv2>` を並べる
5. `isukit deploy`（設定の push と、全 app の台でのビルドと再起動）

```
isukit probe                        # 警告が消えたか
isukit bench "split: db on isu3"
isukit show                         # 負荷が狙いどおり isu3 / isu2 に移ったか
```

- [ ] `probe` の警告が0件
- [ ] `show` の hosts 欄で、isu3 の mysqld と isu2 のアプリに負荷が出ている
- [ ] スコアが落ちたら戻せる（`git revert` + `deploy`）

---

## 6. 最後の出力オフ（T+3:00〜3:30）

```
isukit final check                  # スコアを削る出力の一覧
isukit final apply                  # 設定で止められるものを止め、全台を片付ける
# アプリのコードに出た項目（pprof・ロガー）を外す → isukit deploy
isukit bench "final: output off"
isukit ship "final: output off"
isukit final check                  # hosts の項目が0件
```

- [ ] `final apply` のあと、`etc/` に `access_log off;` が入り、git の差分として見える
- [ ] 出力オフでスコアが下がっていない

---

## 7. 締め（T+3:30〜4:00）

```
isukit finalize
```

- [ ] 全台が再起動から戻る（5分以内）
- [ ] 役割ごとのサービスが自動で起動している
- [ ] HTTP の確認で全台が OK（`FINAL_CHECK_PATH` で DB まで確かめられている）
- [ ] 確認のベンチが通り、スコアが §6 と同じ水準

**manual モードの練習**（本番はポータルで流すので）：

```
isukit benchmode manual
isukit logs on
isukit bench "manual drill"         # 「実行が始まったら Enter」→ ここでは別端末から BENCH_CMD を手で流す → スコアを入力
isukit show
isukit bench --score <N> "manual, typed later"
```

- [ ] プロンプトに沿って入力でき、`show` にその回が保存される

---

## 8. 片付け

```
aws ec2 terminate-instances --instance-ids <4台のID>
# terminated を待ってから
aws ec2 delete-security-group --group-name isukit-ssh
aws ec2 delete-key-pair --key-name isukit
```

- [ ] インスタンスが残っていない（`aws ec2 describe-instances --filters Name=instance-state-name,Values=running`）

---

## 記録シート

| ステップ | 開始 | 終了 | 詰まったこと / isukit の不具合 | 対応 |
|---|---|---|---|---|
| 0 前日 | | | | |
| 1 起動 | | | | |
| 2 リポジトリ | | | | |
| 3 偵察 | | | | |
| 4 ループ | | | | |
| 5 分割 | | | | |
| 6 出力オフ | | | | |
| 7 締め | | | | |

終わったら、詰まった点を issue にして、凍結（本番の1週間前）までに直すものを決める。

---

## 現状の isukit で足りないもの

この練習で困ることが分かっているもの。優先度は「本番で起きたときの損失」と「直す手間」で付けた。

| # | 足りないもの | 本番での影響 | 対応案 | 優先度 |
|---|---|---|---|---|
| 1 | `benchprobe` がベンチの宛先を常に `127.0.0.1` にする | 別の台のベンチが自分を叩く（練習のみ。本番はポータル） | `--target` 系のフラグに app の台の Private IP を入れる | 中 |
| 2 | 構成の分割が手作業（bind-address・DB ユーザー・接続先・MySQL の停止・upstream） | 本番で最も時間を使い、ミスも出やすい（§5） | 役割に合わせて構成を変える段階2の機能 | **高** |
| 3 | 役割（`.isukit/hosts`）・config が各自の手元にしかない | 3人で設定がずれる。1人が分割しても他の2人の isukit は古い構成のまま | `.isukit/hosts` を repo に入れて共有する（例：`isukit.hosts`） | **高** |
| 4 | env ファイル（`DB_HOST` など）を git で管理していない | 接続先の変更が記録に残らず、戻せない・他の人に見えない | `hosts/<台>/env.sh` を正にして、台ごとに push する | **高** |
| 5 | スコアと計測の記録（`scores.tsv`・`runs/`）が、ベンチを流した人の手元にしかない | 他の2人が `show` / `attribute` を見られない | 記録を repo（別ブランチなど）に push して共有する | 中 |
| 6 | `launch.sh` の最後の案内が古い（`go <repo-url>` / `host add`） | 当日の手順を間違える | `go --new` / `host role` を案内する | 低（すぐ直せる） |
| 7 | 凍結（タグ）の手順が決まっていない | 当日に main の最新を入れて壊れる | 1週間前にタグを打つ手順を RUNBOOK に | 中（すぐ決められる） |
| 8 | 複数の app の台でファイルを共有する仕組みがない（画像をローカルに保存するアプリなど） | 台を増やすと一部のリクエストが失敗する | 問題次第。RUNBOOK に注意として書く | 低 |
