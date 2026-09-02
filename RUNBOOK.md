# ISUCON 実戦ランブック

> **迷ったらここだけ見る。** 上から通読しなくてよい。
> 今いるフェーズの節だけ開く。コマンドは全部コピペ可。
>
> 設計の理由・内部の仕組みは [`README.md`](README.md)。英語版の旧ランブックは [`RUNBOOK.en.md`](RUNBOOK.en.md)。

---

## 0. 三行で

1. `isukit` は「計測できる状態のサーバー」を用意して、**スコアと git sha を毎回記録する**ための1枚のbashスクリプト。
2. サーバーは**自分のAWSアカウントでEC2を立てる**。本番も練習も同じ形。
3. 3人で触るなら**最初の5分で自分たちのリポジトリを作る**（§3）。ここを飛ばすと並行作業できない。

---

## 1. isukit とは何か

**bash 1枚**。依存なし。配布元は https://github.com/mako-for-it/isukit （public）。

```
git clone https://github.com/mako-for-it/isukit.git ~/isukit
export PATH="$HOME/isukit:$PATH"      # または ln -s ~/isukit/isukit /usr/local/bin/isukit
```

やることは4つだけ。

| | コマンド | 中身 |
|---|---|---|
| **① 立ち上げ** | `isukit go <repo-url> <app-host> [bench-host]` | リポジトリを clone → サーバーを調査 → `alp` と `pt-query-digest` を入れる → nginx の LTSV ログと `long_query_time=0` を有効化 |
| **② 発見** | `isukit probe` | **動いているサーバーに直接聞く**。systemd unit / `WorkingDirectory` / `ExecStart` / env ファイル / データストアを特定して `.isukit/manifest` に書く |
| **③ 計測** | `isukit bench` `alp` `slow` `pprof` `score` | スコアと git sha を毎回記録。エンドポイントとクエリを**合計時間**で並べる |
| **④ 反映** | `isukit deploy` `finalize` | systemd が実際に exec しているパスへビルドして再起動 / 終盤の締め処理 |

**なぜリポジトリを読まずにサーバーに聞くのか**：ISUCONのリポジトリ構成は年ごとに何も安定していない。Goのディレクトリ名（`webapp/go` か `webapp/golang`）、ビルド方法（Make → Taskfile → 無し）、docker composeの有無、unit名、envファイルの場所と変数名、ベンチのフラグ名 — 全部違う。systemdに問い合わせるのが全年代で唯一通用する手。

**唯一自動で分からないのが `BENCH_CMD`**。ベンチマーカーのターゲット指定フラグは毎年違う（`-target` / `-target-url` / `-target-host` / `-target-addr` / `--target`）。ここは手で埋める。

コンテストごとの状態は clone した各リポジトリの中の `.isukit/` に入るので、複数のコンテストを並行して持てる。

---

## 2. サーバーはどこから来るのか

### 2-1. 本番（ISUCON2026）

- **日時：2026年10月31日（土）10:00–18:00 JST（8時間）**
- チームは**最大3名**
- **参加登録は2026年8月上旬に締切済み**（300/300/335の3回に分けて募集し全枠終了）
- 今年の運営窓口はさくらインターネット（会場は大阪本社 Blooming Camp）。ただし**競技環境はさくらのクラウドではなくAWS**
- レギュレーション：**選手が自分でAWSアカウントを用意し、競技開始後に運営が指定するAMIを自分のEC2で起動する**

つまり本番の環境構築は「運営がAMI IDを公開 → 自分のアカウントでEC2を起動 → 自分の鍵でSSH」。踏み台もVPNもない。**練習で作る手順がそのまま本番の手順になる。**

ログイン先は `ubuntu` ユーザー、そこから `sudo su - isucon`。

### 2-2. 練習（各自の AWS サンドボックスアカウント）

**ap-northeast-1（東京）固定。** ログインと、今どのアカウントにいるかの確認：

```
aws sso login --profile sandbox
export AWS_PROFILE=sandbox AWS_REGION=ap-northeast-1
aws sts get-caller-identity        # 別アカウントに立てる事故がいちばん多い
```

#### 使えるAMI（2026-09-02 に実アカウントで確認済み）

| 過去問 | AMI | 状態 | SSH |
|---|---|---|---|
| isucon13（公式） | `ami-041289d910c114864` | **available** | `ubuntu` → `sudo su - isucon` |
| isucon12-qualify（公式） | `ami-05c5b59deed48f66b` | **消滅（InvalidAMIID.NotFound）** | — |
| isucon12-qualify（matsuu） | `ami-073140ad092048333` | **available** | `ubuntu` → `sudo -i -u isucon` |
| isucon13（matsuu） | `ami-006d211cb716fe8a0` | 未検証 | `ubuntu` → `sudo -i -u isucon` |
| isucon14（matsuu） | `ami-0fcf9e8e8675a9ee4` | 未検証 | `ubuntu` → `sudo -i -u isucon` |

**公式AMIは予告なく消える。実際 isucon12-qualify の公式AMIはもう無い**（そのため公式リポジトリの `cloudformation.yaml` も現状そのままでは動かない）。フォールバックは
[matsuu/aws-isucon](https://github.com/matsuu/aws-isucon) のAMI表 — webappとbenchの両方入り。**IDをハードコードせず、使う日にREADMEの表を見る**（作り直されて変わる）。

さらに古い/無い年は [matsuu/cloud-init-isucon](https://github.com/matsuu/cloud-init-isucon)（素のUbuntuにuser-dataで構築。isucon10q/11q/11f/12q/12f/13/14/private-isu 対応）か、リポジトリ同梱の `provisioning/packer` / `provisioning/ansible`。

#### 実際に立てる手順（このままコピペ可）

```
export AWS_PROFILE=sandbox AWS_REGION=ap-northeast-1
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
MYIP=$(curl -s https://checkip.amazonaws.com)

# ① 鍵（初回だけ）
aws ec2 create-key-pair --key-name isukit-sandbox --query KeyMaterial --output text > ~/.ssh/isukit-sandbox.pem
chmod 600 ~/.ssh/isukit-sandbox.pem

# ② セキュリティグループ（自分のIPからの22番＋グループ内は全開放）
SG=$(aws ec2 create-security-group --group-name isukit-sandbox \
      --description "isucon practice" --vpc-id "$VPC" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$MYIP/32"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol -1 --source-group "$SG"

# ③ 起動。--block-device-mappings は必須（AMIの既定は 8GB / 16GB で、ベンチのログとデータで溢れる）
aws ec2 run-instances \
  --image-id ami-041289d910c114864 \
  --instance-type c5.large \
  --key-name isukit-sandbox --security-group-ids "$SG" --subnet-id "$SUBNET" \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=isucon13-app},{Key=purpose,Value=isucon-practice}]' \
  --query 'Instances[].InstanceId' --output text

# ④ Public IP を取る。これが <app-host> の正体
aws ec2 describe-instances --filters Name=tag:purpose,Values=isucon-practice \
  Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress]' --output text
```

> **`--block-device-mappings` を省くと後で詰む。** 公式isucon13 AMIの既定ルートは **8GB gp2**、matsuu の isucon12-qualify は **16GB**。`long_query_time=0` のスローログはこれをすぐ埋める。**30GB gp3** にしておく。

#### isukit に渡す `<app-host>`

`<app-host>` は **ssh の宛先文字列そのもの**。`ubuntu@<Public IP>` を渡し、鍵は `SSH_OPTS` に書く：

```
isukit host app  ubuntu@43.207.152.140
isukit host bench ubuntu@43.207.152.140      # 練習で1台に寄せる場合は app と同じでよい
$EDITOR .isukit/config
#   SSH_OPTS='-i ~/.ssh/isukit-sandbox.pem'
```

`~/.ssh/config` に書いてしまうなら `Host isu13` の別名を作って `isukit host app isu13` でもよい。どちらでも `isukit` は気にしない。

#### 台数

- 本気の練習：app **3台 × c5.large**（2 vCPU / 4 GiB）＋ bench **1台**。本番と同じ形
- キットの動作確認や、1台構成のチューニング練習だけなら **1台**でよい（matsuu AMIはbench同梱なので同じ箱でベンチも回る）

**費用**：c5.large は東京で約 **$0.107/時**。4台で6時間 ≈ **$3程度**。

> **消し忘れが本当の出費。** 4台を止め忘れると月$300超。練習が終わったら必ず：
> ```
> aws ec2 describe-instances --filters Name=tag:purpose,Values=isucon-practice \
>   Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text \
>   | xargs -r aws ec2 terminate-instances --instance-ids
> ```
> サンドボックスでも請求先は実在する。**その日のうちに落とす。**

### 2-3. ローカルだけで済ませたいとき

スコアの絶対値は当てにならないが、コードを触る練習にはなる。

```
cd ~/personal-projects/isucon/isucon13/development && make up && make go
```

isucon13 は言語別に8つ、isucon12-qualify は19個の compose ファイルを同梱している。
**isukit の `probe` / `deploy` / `logs` はこの構成では効かない**（systemdが無い）。手元のMacでも同じ理由で `probe` は空の manifest を書いて警告だけ出す。

---

## 3. 競技開始5分：自分たちのリポジトリを作る

**3人で並行して触るための必須手順。** コードは配られたサーバーの上にしか無い状態から始まる。公開リポジトリ（`isucon/isucon13` など）は読む専用で、push できない。

**向きが大事：サーバー → 自分たちのリポジトリ → 各自のラップトップ。**

```
# ① サーバー上で。まだ何も変えていないコードをベースラインとして push
ssh <app-host>
sudo su - isucon
cd /home/isucon/webapp          # すでに git リポジトリのこともある
git init                        # 無ければ
git remote add origin git@github.com:<team>/<private-repo>.git
git add -A && git commit -m "baseline: 手を入れる前の状態"
git push -u origin main
```

nginx と MySQL の設定ファイル（`/etc/nginx`、`/etc/mysql`）も一緒に git に入れておくと、あとで「誰がいつ何を変えたか」が追える。

**リポジトリは private。作ったら残り2人を Collaborator に招待する**（招待しないと push できない）：

```
gh repo create <team>/<private-repo> --private
gh api -X PUT repos/<team>/<private-repo>/collaborators/n000r111 -f permission=push
gh api -X PUT repos/<team>/<private-repo>/collaborators/imaharu  -f permission=push
```

参加者： [mako-for-it](https://github.com/mako-for-it) / [n000r111](https://github.com/n000r111) / [imaharu](https://github.com/imaharu)

```
# ② 3人それぞれのラップトップで。公開リポジトリではなく自分たちのリポジトリを渡す
cd ~/personal-projects/isucon
isukit init git@github.com:<team>/<private-repo>.git isucon-2026
cd isucon-2026
isukit host app  <app-host>
isukit host bench <bench-host>
isukit probe
$EDITOR .isukit/config          # BENCH_CMD='...' をリポジトリのREADMEから写す
```

**すでにcloneがあるとき**：`init` は既存ディレクトリをそのまま採用する（cloneし直さない）。**親ディレクトリで**ディレクトリ名を渡して実行する。`init` は `work` ブランチを作って切り替える点に注意。

```
cd ~/personal-projects/isucon
isukit init <repo-url> <既にあるディレクトリ名>
```

**ベースラインのコミットが唯一の戻り先。** ここを作らずに走り出すと、スコアが落ちたときに戻る場所が無い。

---

## 4. チームルール（クロック開始前に合意する）

- **ベンチ係は1人。** ベンチは同時に1本だけ。2本走ると全部の数字が無意味になる。キューイングも1人が持つ。
- **デプロイ係も1人。** `isukit deploy` は **`rsync -a --delete` で自分の手元のツリーをサーバーに上書きする**。3人がそれぞれの手元から打つと最後の人が勝ち、`--delete` で他の2人が追加したファイルが消える。
- **デプロイ直前に必ず `git pull`。** 上のルールの裏返し。pullを忘れたデプロイは、誰かの作業が抜けたツリーを本番に載せてベンチしていることになる。
- **ベンチ直前に必ず commit。** `isukit bench` は `HEAD` の sha を記録するだけで、**コミットはしてくれない**。commitせずに回すと `scores.tsv` の全行が同じ sha になり、「どの変更が効いたか」という記録の意味が消える。
- **1回のベンチにつき変更は1つ。** 2つ入れてスコアが動いても、どちらが効いたか分からない。
- **スコアが落ちたら即revert。** 競技中にリグレッションをデバッグしない。戻して、戻ったことをベンチで確認して、次へ。
- **30分タイムボックス。** 30分でスコアが動かない変更は捨てる。粘らない。
- **数字を声に出す。** ベンチ結果は毎回全員に共有。古いスコアを前提に最適化する人を作らない。

**3人の分担例**：1人がインフラ／計測（`isukit`、alp・slowの読み、デプロイ、スコア台帳） ＝ ベンチ係兼デプロイ係。1人がDB（スキーマ、インデックス、クエリ）。1人がアプリコード。

---

## 5. フェーズ表

割合で書いてあるので3時間の模擬でも8時間の本番でも同じ表が使える。2026本番はちょうど8時間なので右列がそのまま時計になる。

| フェーズ | 割合 | 10:00開始の場合 | 鉄則 |
|---|---|---|---|
| 0 アクセス確認 | 開始前 | 〜10:00 | まだ何も計測されていない |
| 1 ベースラインと偵察 | 0–12% | 10:00–11:00 | **コードを触らない** |
| 2 安い構造的改善 | 12–40% | 11:00–13:15 | 1ベンチ1変更 |
| 3 サーバー分散 | 40–60% | 13:15–14:50 | 1台構成をプロファイルし終えてから |
| 4 アプリロジック | 60–80% | 14:50–16:25 | リスク最大・天井最大 |
| 5 凍結と検証 | 80–100% | 16:25–18:00 | **80%で変更凍結** |

---

## 6. 各フェーズ

### フェーズ0 — アクセス確認（クロック前）

```
ssh <app-host> true && ssh <bench-host> true     # 今この瞬間に両方通ること
chmod 600 ~/.ssh/<contest>.pem                    # 644 だと ssh が拒否する
```

§3 のリポジトリ作成をここで終わらせる。そのあと `.isukit/manifest` をチームに読み上げる：**何台あるか、どのunitが動いているか、メモリ何GBか、データストアは何か**。それがその日の持ち札。

### フェーズ1 — ベースラインと偵察（0–12%）／コードを触らない

**① まず数字を取る。**

```
isukit logs off
isukit bench "baseline"
```

計測ログは実際にスコアを削るので、ベースラインは素の状態で取る。以降の判断は全部「これを超えたか」で決まる。

**② ベンチが走っている間にマニュアルを読む。** 特に：

- **スコアの計算式が何を評価しているか。** スループットとは限らない。特定エンドポイントに重みがある年、エラーで減点される年、比率でゲートがかかる年がある
- **失格条件。** これを踏むと速さに関係なく0点
- `/initialize` のタイムアウトと、返すべきもの
- 禁止事項（偽データを返す、テーブルを消す、等）

**③ アプリのエラーログを読む。** ベンチが黙ってリトライしているエラーはタダのスコア。レイテンシのプロファイルには映らない。

```
ssh <app-host> 'journalctl -u <APP_UNIT> -n 200 --no-pager'   # unit名は .isukit/manifest にある
```

**④ 計測を入れて取り直す。**

```
isukit logs on
isukit bench "instrumented — baselineと比較しないこと"
isukit alp
isukit slow
```

**`alp` は必ず「合計レスポンスタイム」で読む。平均でも件数でもない。** 3msのエンドポイントが40,000回呼ばれていれば、900msが2回より重い。isukitは既定でそう並べる。`pt-query-digest` も合計時間順。

上位3エンドポイントと上位3クエリを全員が見える場所に書く。それがフェーズ2の作業キュー。

### フェーズ2 — 安い構造的改善（12–40%）

リスクあたりの効果が大きい順。**答えのリストではなく「どこを見るか」のリスト。** 必ず自分のプロファイルで裏を取る。

- [ ] **インデックスが無い。** `isukit slow` の重いクエリの `WHERE` / `ORDER BY` / `JOIN` に出てくる列。前後で `EXPLAIN`。参考実装は本当にインデックスが無いことが多い
- [ ] **N+1。** `pt-query-digest` での見え方は「呼び出し回数が異常に多く、1回は速いのに合計で1位」。JOINするか `IN` でまとめる
- [ ] **静的ファイルをアプリが返している。** web サーバーに寄せる。`isukit alp` にアセットのパスが出ていないか
- [ ] **コネクションプールが既定値。** Goで `SetMaxOpenConns` / `SetMaxIdleConns` 未設定は「無制限に開く・idleは2本」で負荷時に病的。DBの `max_connections` に合わせる（超えない）
- [ ] **リクエストごとにやる必要のない処理がハンドラの中にある。** 設定のパース、テンプレートのコンパイル、ファイル読み、鍵導出
- [ ] **重いパスワードハッシュ／暗号処理**でコスト係数が調整可能なもの
- [ ] **全件取ってアプリ側でソート・フィルタしている。** インデックスがあればDBの仕事
- [ ] **webサーバー自身の上限** — worker数、upstreamへの `keepalive`、open files。安いが、アプリがボトルネックでなくなってから

1つやるごとに：`isukit deploy` → `isukit bench "何を変えたか"`。**数字だけで採否を決める。**

### フェーズ3 — サーバー分散（40–60%）

**1台をプロファイルし終えて、ボトルネックが分かってから。** 何が重いか分からないまま分けると、問題が移動するだけでネットワーク遅延が増える。

1. データストアを2台目へ。アプリの接続設定は**コードではなくenvファイル**（`.isukit/manifest` の `ENV_FILE`）にある
2. DBがリモート接続を実際に受けるか、アプリが再接続するかを確認
3. `isukit bench` — **DBがボトルネックでなかった場合ここでスコアが落ちる。** 落ちたら戻す
4. webサーバーの後ろにアプリ2台目を置いてロードバランス

分散のステップは毎回「再起動後に生き残らないと困るもの」を増やす。何を増やしたか書いておく。フェーズ5で確認する。

### フェーズ4 — アプリロジック（60–80%）

天井が最も高く、ベンチの整合性検査を壊すリスクも最も高い。

- [ ] **リクエストごとに変わらないものをキャッシュ。** 1台ならプロセス内、分散後は共有ストア。**invalidationを間違えると整合性検査で落ちて、どれだけ速くても0点**
- [ ] **読みが支配的なら、読み時ではなく書き時に計算しておく**
- [ ] **外部呼び出しとDBの往復をまとめる**
- [ ] **捨てるデータを作るのをやめる** — 使わない列、アプリ側で捨てる行、組み立ててから捨てるレスポンス
- [ ] **上の全部、信じる前にプロファイルを取る。** `net/http/pprof` が入っていれば `isukit pprof 30`。入っていなければ早めに入れる（2行）

採用した変更のあとは毎回 `isukit alp` を取り直す。ボトルネックは動くので、フェーズ1のリストはこの時点でもう古い。

### フェーズ5 — 凍結と検証（80–100%）

**80%で変更凍結。** どんなに良いアイデアでも、ここから先は新しい最適化をしない。**このフェーズは稼いだ分を失わないための時間。**

```
isukit logs off          # 計測ログは今この瞬間もスコアを削っている
isukit finalize          # logs off → 再起動 → unitの復帰確認 → 採点用ベンチ
```

`finalize` があるのは、**実行時だけの状態は再起動で消える**のに、最終採点は再起動されたかもしれないマシンで走るから。以下は手で確認する：

- [ ] 依存している全サービスが **enabled**（動いているだけでは不十分）：`.isukit/manifest` の各unitに `systemctl is-enabled <unit>`
- [ ] やった `SET GLOBAL` が**設定ファイルにも書いてある**。MySQLの実行時変数は再起動で消える
- [ ] 必要なものが `/tmp` に無い
- [ ] ディスクに空きがある：`df -h`
- [ ] スロークエリログが **off** で、ログファイルを削除済み（`long_query_time=0` はディスクを埋める）
- [ ] アプリが完全なコールドスタートから手作業なしで起動する

そのあとベンチを2〜3回回す。スコアは毎回ぶれる。**知りたいのは「運が良かった数字」ではなく「安定して出る数字」。** 終盤の回で失敗したら、`isukit score` の最後の緑の sha に戻る時間がまだある。

**95%で手を止める。**

---

## 7. 詰まったとき（isukit のクセ）

| 症状 | 対処 |
|---|---|
| `probe` が「no app systemd unit found」 | unit選びはスコア付きヒューリスティックで、保証ではない。手で上書き：`isukit unit <unit名>` して再probe |
| `alp` / `slow` が `sudo: a password is required` を出す | 先に `sudo` を叩いてからログの有無を見る作り。競技サーバーの `isucon` はパスワード無しsudoなので本番では出ない。手元のMacでは出る（無害） |
| `logs` が web 層に何もしない | nginx専用。`probe` が nginx 以外を検出すると警告して何もしない。その場合はアプリ層でプロファイルする |
| `deploy` が効かない | **Goアプリ前提**で、systemdが既にexecしているパスにビルドする。他言語は手でデプロイ |
| `pprof` が繋がらない | アプリに `import _ "net/http/pprof"` とリスナーが必要。無いとコマンドがスニペットを教えてくれる |
| MySQLの自動化が動かない | ソケット経由のパスワード無し `sudo mysql` が必要。無ければ `probe` が `MYSQL_OK=0` と報告する |
| 鍵やポートが特殊 | `.isukit/config` の `SSH_OPTS` が全 `ssh`/`scp` に渡る。**`ssh` は `-p <port>`、`scp` は `-P <port>`** で違う点に注意 |
| インフラを変えた | `isukit probe` を打ち直す。manifestは他の全コマンドが読んでいる |

---

## 8. 全部を失う失敗モード

年によらず、チームが丸ごと失うのはこのパターン。

| 失敗 | 予防 |
|---|---|
| 最終計測で計測ログが入ったまま | `isukit logs off`、フェーズ5で確認 |
| 実行時にだけ設定を当てて再起動で消える | `isukit finalize` ＋ enabled チェック |
| サービスが enabled でなく再起動後に死ぬ | 全unitに `systemctl is-enabled` |
| `long_query_time=0` でディスク満杯 | フェーズ5でスローログを削除 |
| ベンチの整合性検査で落ちる | **キャッシュを入れた変更のたびに**ベンチを回す |
| `/initialize` がタイムアウト | 初期化を軽く保つ。時間を測る |
| ベンチが2本同時に走った | ベンチ係1人、徹底 |
| 戻せない状態 — スキーマを手で変えた | スキーマ変更は全部gitのマイグレーションファイルに |
| ベースラインを記録していない | フェーズ1は省略不可 |
| デプロイで他の2人の作業が消えた | デプロイ係1人 ＋ デプロイ直前の `git pull`（§4） |
| `scores.tsv` の sha が全部同じ | ベンチ直前に commit（§4） |

---

## 9. コマンド早見表

```
isukit init <repo-url> [dir]   # clone（既存ディレクトリはそのまま採用）＋ work ブランチ
isukit host app|bench <target> # ssh先を .isukit/config に設定（'local' も可）
isukit probe                   # サーバーを調査して .isukit/manifest を書く。インフラ変更後は毎回
isukit unit <unit名>           # probe のunit選択を手で上書き
isukit logs on|off             # nginx LTSV ＋ MySQLスローログ
isukit bench "メモ"            # スコア＋git sha を .isukit/scores.tsv に記録
isukit score                   # 全履歴
isukit alp                     # エンドポイントを合計レスポンスタイム順
isukit slow                    # クエリを合計時間順
isukit pprof 30                # GoのCPUプロファイル → .isukit/cpu.pprof
isukit deploy                  # rsync＋ビルド → systemdのExecStartパス → 再起動
isukit restart                 # 検出したアプリunitを再起動
isukit finalize                # 終盤の締め処理一式
```

**ファイル**（全部 git-ignore 済み、各リポジトリの `.isukit/` の中）

```
.isukit/config        APP, BENCH, BENCH_CMD, SSH_OPTS, EXTRA_UNITS   ← 手で編集する
.isukit/manifest      probe の結果。他の全コマンドが読む
.isukit/scores.tsv    日時 / sha / スコア / メモ / 生ログのパス
.isukit/bench-*.log   実行ごとのベンチ出力そのまま
```
