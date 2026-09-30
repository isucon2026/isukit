# ISUCON 実戦ランブック

> **迷ったらここだけ見る。** 上から通読しなくてよい。
> 今いるフェーズの節だけ開く。コマンドは全部コピペ可。
>
> 設計の理由・内部の仕組みは [`README.md`](README.md)。英語版の旧ランブックは [`RUNBOOK.en.md`](RUNBOOK.en.md)。

---

## 0. 三行で

1. `isukit` は「計測できる状態のサーバー」を用意して、**スコアと git sha を毎回記録する**ための1枚のbashスクリプト。インストールは `curl | bash` の1行（§1）。
2. サーバーは**自分のAWSアカウントでEC2を立てる**。本番も練習も同じ形。
3. 3人で触るなら**最初の5分で自分たちのリポジトリを作る**（§3）。ここを飛ばすと並行作業できない。

---

## 1. isukit とは何か

**bash 1枚**。依存なし。配布元は https://github.com/isucon2026/isukit （public）。

インストールは1行。

```
curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh | bash
```

`~/.isukit-src` に clone して、`isukit` を PATH の通る場所に置く。2回目以降は更新になる。PATH が通っていなければ、追加すべき `export` 行をそのまま出力するのでそれを貼る。

**インストールと立ち上げを丸ごと1行**にもできる（`--` の後ろはそのまま `isukit` に渡る）。

```
curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh \
  | bash -s -- go <repo-url> ubuntu@<ip> -i ~/.ssh/<key>.pem
```

これで clone → サーバー調査 → `alp`/`pt-query-digest` 導入 → 計測ログ有効化 → **ベンチマーカーの発見と `BENCH_CMD` の自動生成**まで終わる。手で入れる値は3つだけ：**リポジトリURL、サーバーのIP、鍵のパス**。それ以外は全部サーバーに聞いて決まる。

やることは4つだけ。

| | コマンド | 中身 |
|---|---|---|
| **① 立ち上げ** | `isukit go <repo-url> <app-host> [bench-host]` | リポジトリを clone → サーバーを調査 → `alp` と `pt-query-digest` を入れる → nginx の LTSV ログと `long_query_time=0` を有効化 |
| **② 発見** | `isukit probe` | **動いているサーバーに直接聞く**。systemd unit / `WorkingDirectory` / `ExecStart` / env ファイル / データストアを特定して `.isukit/manifest` に書く |
| **③ 計測** | `isukit bench` `alp` `slow` `attribute` `score` | スコアと git sha を毎回記録。エンドポイントとクエリを**合計時間**で並べる。`attribute` で 2 回の計測の有意差を判定 |
| **④ 反映** | `isukit deploy` `ship` `revert` `finalize` | systemd が実際に exec しているパスへビルドして再起動 / 変更を commit + push + PR。終盤の締め処理 |

**なぜリポジトリを読まずにサーバーに聞くのか**：ISUCONのリポジトリ構成は年ごとに何も安定していない。Goのディレクトリ名（`webapp/go` か `webapp/golang`）、ビルド方法（Make → Taskfile → 無し）、docker composeの有無、unit名、envファイルの場所と変数名、ベンチのフラグ名 — 全部違う。systemdに問い合わせるのが全年代で唯一通用する手。

**`BENCH_CMD` は自動生成される。ただし唯一「人間が直す可能性が高い」行**でもある。ベンチマーカーのターゲット指定フラグは毎年違う（`-target` / `-target-url` / `-target-host` / `-target-addr` / `--target`）ので、isukit は**ベンチマーカーのバイナリ自身の `--help` を読んで**使えるフラグを判定し、コマンド行を組み立てて表示する。違っていたら `isukit benchcmd '<正しい行>'` で上書きする（エディタ不要）。使えるフラグの全一覧は `.isukit/bench-help.txt` に落ちている。

コンテストごとの状態は clone した各リポジトリの中の `.isukit/` に入るので、複数のコンテストを並行して持てる。

### ベンチモード：`auto` と `manual`

**`auto` モード** — `isukit bench` は ssh で BENCH_CMD をベンチ用ホストで走す。練習環境の標準。

**`manual` モード** — ベンチマーカーはポータル（web UI）から起動され、スコアは人間が記録する。ISUCON11以降の**本番環境はこれ**。ssh でベンチを走すのは禁止事項。

```
isukit bench --score 12345 "インデックス追加"    # スコアを記録
isukit bench --fail "タイムアウト"                # 失敗を記録
```

`isukit benchprobe` はベンチマーカーバイナリが見つからないと自動的に `manual` 模式に切り替える。モードはいつでも手で変更可：

```
isukit benchmode manual      # auto ↔ manual に切替
isukit benchmode             # 現在のモードを表示
```

**なぜ重要か**：本番ではベンチマーカーはサーバー上に無く、ポータルから起動される。スコアを ssh で記録できるのは練習だけ。本番に向けての練習では `manual` 模式を試しておく。

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

#### 推奨：`launch/` のスクリプトを使う（本番と同じ手順で練習する）

キット同梱の `launch/prestage.sh` / `launch/launch.sh` は本番当日に使うのと同じスクリプト。生のAWS CLIを手で組み立てるより、これで練習する方が当日の手順そのものになる。2026-09-28に実アカウント（`395103361978`）で end-to-end 検証済み：

```
cd ~/personal-projects/isucon/isukit

# ① prestage — 本番なら T-7d 相当。AMI を必要としないので当日より前に済ませておく
launch/prestage.sh \
  --key-name isukit \
  --key-file ~/claude-workspace/isukit.pem \
  --region ap-northeast-1 \
  --sg-name isukit-ssh \
  --allow-ip <n000r111のIP> \
  --allow-ip <imaharuのIP>
```

**セキュリティグループは起動後に変更できない。これはAWSの制約ではなく、ISUCONのルール上の禁止事項。** チームメンバー全員のIPを `--allow-ip` で prestage の時点までに入れておくこと。入れ忘れると、8時間まるごとSSHできないまま復旧手段が無い。スクリプトは実際にSGへ入ったCIDRを出力するので、フラグではなくその出力をロスターと突き合わせて確認する。

`isukit.pem`（`--key-file` の実体）はチームへ別経路で配布する。`.gitignore` 済みなので、間違っても共有リポジトリには置かない。

```
# ② launch — T+0、運営がAMIを発表してから
launch/launch.sh \
  --ami ami-0fcf9e8e8675a9ee4 \
  --type t3.small \
  --count 1 \
  --name-prefix isucon \
  --yes
```

`--ami` / `--type` / `--count` にデフォルトが無いのは意図的。運営が当日発表する値をその都度人間が読んで打ち込む設計で、キットが勝手に推測することはない。`--root-gb` は練習専用のオプション（既定より大きいルートボリュームでベンチのログ溢れを防げる）で、本番当日はマニュアルの指定が優先——インスタンス形状を変えること自体が禁止事項に触れうる。

立ち上げたらあとは通常の計測フローに合流する：

```
isukit init <contest-repo-url> <dir>
isukit host app ubuntu@<public-ip> -i ~/claude-workspace/isukit.pem
isukit probe        # スタックを発見。リポジトリは読まない
isukit benchprobe    # ベンチマーカーが無ければ BENCH_MODE を manual に切替
isukit setup         # alp + percona-toolkit を導入
isukit logs on       # nginx LTSV + mysql long_query_time=0
isukit doctor        # 非破壊の健全性チェック＋自己修復
```

`BENCH_MODE=manual` は**正しい本番状態**であって失敗ではない——ISUCON11以降はベンチマークがポータルUIから起動され、ベンチマーカーホストへのSSHは明確な禁止事項。

練習が終わったら片付ける：

```
aws ec2 terminate-instances --instance-ids <ids>
# 'terminated' を待ってから：
aws ec2 delete-security-group --group-name isukit-ssh
aws ec2 delete-key-pair --key-name isukit
```

**検証済みAMI（2026-09-28）：** `ami-0fcf9e8e8675a9ee4`（ap-northeast-1、x86_64）は isucon14 の問題一式が焼き込まれた箱——`isuride-*` の systemd unit、MySQL 8.0.46、nginx、`alp` まで最初から入っている。`isukit probe` は `APP_UNIT_CONFIDENCE=high` で一発で当てた。練習台として実績あり。下の表の該当行もこれで検証済みに更新。

チームメンバーは自分のSSOではコンソールに入れない（組織レベルのIdentity Centerはアカウント所有者しか権限を配れない）。コンソールが要る場合はアカウント直下のIAMユーザーがフォールバックだが、通常はSSH＋ポータルだけで足りる。

#### 手動でAWS CLIから直接立てる場合

上のスクリプトが内部でやっていることを理解したいとき、あるいはスクリプトを使わずに組み立てたいときの生コマンド。

#### 使えるAMI（2026-09-02 に実アカウントで確認済み）

| 過去問 | AMI | 状態 | SSH |
|---|---|---|---|
| isucon13（公式） | `ami-041289d910c114864` | **available** | `ubuntu` → `sudo su - isucon` |
| isucon12-qualify（公式） | `ami-05c5b59deed48f66b` | **消滅（InvalidAMIID.NotFound）** | — |
| isucon12-qualify（matsuu） | `ami-073140ad092048333` | **available** | `ubuntu` → `sudo -i -u isucon` |
| isucon13（matsuu） | `ami-006d211cb716fe8a0` | 未検証 | `ubuntu` → `sudo -i -u isucon` |
| isucon14（matsuu） | `ami-0fcf9e8e8675a9ee4` | **検証済み**（2026-09-28、`isuride-*` unit / MySQL 8.0.46 / nginx / alp 同梱、`APP_UNIT_CONFIDENCE=high`） | `ubuntu` → `sudo -i -u isucon` |

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

`<app-host>` は **ssh の宛先文字列そのもの**。`ubuntu@<Public IP>` を渡し、鍵は `-i` で渡す：

```
isukit host app   ubuntu@43.207.152.140 -i ~/.ssh/isukit-sandbox.pem
isukit host bench ubuntu@43.207.152.140 -i ~/.ssh/isukit-sandbox.pem   # 練習で1台に寄せる場合は app と同じでよい
```

複数インスタンスの場合（ISUCON2026予定）は、ホストごとに役割を付ける。役割は `app`（アプリ）・`web`（nginx）・`db`（MySQL）の組み合わせ：

```
isukit host role ubuntu@43.207.152.140 web,app   # 1台目: nginx + アプリ（isukit go で指定した台）
isukit host role ubuntu@43.207.152.141 app       # 2台目: アプリだけ
isukit host role ubuntu@43.207.152.142 db        # 3台目: MySQL だけ
isukit hosts                                     # 役割と、各台で動いているべき unit の一覧
```

役割は `.isukit/hosts` に書かれ、各コマンドはそれを見て動く台を決める：`deploy` / `restart` / `pprof` は app の台、nginx のログと `alp` は web の台、スロークエリログと `slow` は db の台、`etc` と `os` は全台。`finalize` は全台を再起動し、それぞれの役割に必要な unit が自分で上がってくるかを確かめる（再起動順は保証されない）。`isukit go -i <鍵>` で作った ssh 設定は、追加した台にも同じ鍵・ユーザー・ポートを使う。

役割は「isukit がどの台に何をするか」を決めるだけで、構成そのものは変えない。app の台の MySQL を止める（`systemctl disable --now mysql`）、db の台の `bind-address` と接続ユーザー、アプリの DB 接続先（`env.sh` の `DB_HOST` など）は、今のところ手で行う。

`.isukit/hosts` が無いときは従来どおり：`isukit go` の台がすべての役割を持ち、`isukit host add` で足した台はアプリ（app）として扱う。

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
**`isukit probe` はこの構成でも動く**：`systemctl` が何も見つけなくても `docker ps` にフォールバックして `WEB_SERVER` / `DB_SERVER` を埋め、`STACK_IN_DOCKER=1` を立てる。効かないのは `deploy` と `logs on` / `slow on`（ホスト側の設定を書き換えるだけで、コンテナの中身には触れない）。手元のMacで打っても同じ：アプリ自体は systemd unit を持たないので `APP_UNIT` は空のまま警告になるが、web/db 側は拾える。

---

## 3. 競技開始5分：自分たちのリポジトリを作る

**3人で並行して触るための必須手順。** 競技開始の時点では、コードは配られたサーバーの上にしか無い。公開リポジトリ（`isucon/isucon13` など）は読む専用で、push できない。

**1人（リポジトリ係）が1コマンドで作る：**

```
isukit go --new <team>/<private-repo> ubuntu@<app-host> [ubuntu@<bench-host>] -i ~/.ssh/<鍵>.pem \
  --invite n000r111,imaharu
```

これで次のことを順番にやる：

1. **コードのベースライン。** probe で見つけたサーバーの webapp（`SRC_DIR`）を手元に持ってきて、`git init` → コミット → `gh repo create --private` → push。`--invite` の人を Collaborator（push 権限）に招待する。GitHub の認証は手元の `gh` だけを使い、サーバーには何も置かない
   - 入れないもの：`node_modules`・ログ・ビルド済みのアプリ（systemd が動かしているバイナリ）・10MB を超えるファイル（DB のダンプや大きな画像など）。どれも `.gitignore` に書かれ、サーバー側には残る
2. **設定のベースライン。** `/etc` の nginx・MySQL・アプリの unit ファイルを repo の `etc/` に移して、`/etc` からシンボリックリンクを張る（`isukit etc adopt` と同じ。置き換えたファイルは `/etc/isukit-orig/` にバックアップ、MySQL の AppArmor 許可も追加）。各台の env ファイル（`/home/isucon/env.sh` など）は `hosts/<台>/` に**控えとして**コピーする（台ごとに中身が違うのでリンクはしない）。ここまでを2つ目のコミットにして push
3. **いつもの `go` の続き。** ツールのインストール → 計測ログ on → ベンチコマンドの組み立て

終わると、`main` に「コードのベースライン」「設定のベースライン」の2コミットがあり、手元は `work` ブランチにいる。**この2つが唯一の戻り先。** 作らずに走り出すと、スコアが落ちたときに戻る場所が無い。

**残り2人は、できたリポジトリを渡すだけ：**

```
isukit go git@github.com:<team>/<private-repo>.git ubuntu@<app-host> [ubuntu@<bench-host>] -i ~/.ssh/<鍵>.pem
```

以後、設定の変更は手元の `etc/` を編集して `isukit deploy`（または `isukit etc push`）で反映する。サーバーの `/etc` を直接いじらない（repo に残らず、次の push で上書きされる）。

**`gh` が使えない・サーバーに webapp が見つからない等で `--new` が使えないとき**は、手でやる：

```
# サーバー上で：まだ何も変えていないコードをベースラインとして push
ssh <app-host>; sudo su - isucon; cd /home/isucon/webapp
git init && git add -A && git commit -m "baseline: 手を入れる前の状態"
git remote add origin git@github.com:<team>/<private-repo>.git && git push -u origin main   # サーバーに GitHub の鍵が必要
# 手元で：
isukit go git@github.com:<team>/<private-repo>.git ubuntu@<app-host> -i ~/.ssh/<鍵>.pem
isukit etc adopt                 # 設定を repo の etc/ に移してリンク → 手元に取り込まれる
isukit ship "etc: 手を入れる前の設定"
```

**すでに clone があるとき**：`init` は既存ディレクトリをそのまま採用する（clone し直さない）。**親ディレクトリで**ディレクトリ名を渡して実行する。`init` は `work` ブランチを作って切り替える点に注意。

```
isukit init <repo-url> <既にあるディレクトリ名>
```

参加者： [mako-for-it](https://github.com/mako-for-it) / [n000r111](https://github.com/n000r111) / [imaharu](https://github.com/imaharu)

---

## 4. チームルール（クロック開始前に合意する）

- **ベンチ係は1人。** ベンチは同時に1本だけ。2本走ると全部の数字が無意味になる。キューイングも1人が持つ。
- **デプロイ係も1人。** `isukit deploy` は **`rsync -a --delete` で自分の手元のツリーをサーバーに上書きする**。3人がそれぞれの手元から打つと最後の人が勝ち、`--delete` で他の2人が追加したファイルが消える。
- **デプロイ直前に必ず `git pull`。** 上のルールの裏返し。pullを忘れたデプロイは、誰かの作業が抜けたツリーを本番に載せてベンチしていることになる。
- **ベンチ直前に必ず commit。** `isukit bench` は `HEAD` の sha を記録するだけで、**コミットはしてくれない**。commitせずに回すと `scores.tsv` の全行が同じ sha になり、「どの変更が効いたか」という記録の意味が消える。`isukit ship "<メモ>"` で自動化できる：新しい `isukit/<slug>` ブランチを作って commit → push → draft PR を開く。
- **1回のベンチにつき変更は1つ。** 2つ入れてスコアが動いても、どちらが効いたか分からない。
- **スコアが落ちたら即revert。** 競技中にリグレッションをデバッグしない。`isukit revert` で手元の最後のコミットを打ち消す（git revert）、または SHA を指定して任意のコミットを打ち消す。戻ったことをベンチで確認して、次へ。
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

複数台なら、この時点で全台を役割付きで登録しておく（最初は全台同じ AMI なので、とりあえず全部 `web,app,db` でも、実際に使う台だけでもよい。フェーズ3で分けるときに付け直す）：

```
isukit host role ubuntu@<ip1> web,app,db
isukit host role ubuntu@<ip2> app
isukit host role ubuntu@<ip3> app
isukit hosts
```

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
isukit show                     # この回の結果：台ごとの CPU・プロセス、alp、slow、pprof
```

`logs on` の間の `bench` は、1回ごとに計測を区切って `.isukit/runs/<日時>/` に保存する（開始時に全台のログを空にし、ベンチ中は全台の CPU とプロセスごとの使用率を1秒ごとに記録し、app の1台目で pprof を取る）。manual モードでは、プロンプトの指示どおり「ポータルで実行が始まったら Enter」→「スコアを入力」とすると同じように記録する。

**まず `show` の hosts 欄で、どの台・どのプロセスが張り付いていたかを見る。** そこが今のボトルネックで、次に見るものが決まる：

| 張り付いているもの | 次に見る |
|---|---|
| db の台の `mysqld` | `show` の slow（クエリ） |
| app の台のアプリ | `show` の pprof（`go tool pprof -http=: <run>/cpu.pprof`） |
| web の台の `nginx` | 静的ファイル・keepalive・worker 数 |
| どの台も余裕があるのにスコアが伸びない | ロック待ち・外部 API 待ち・アプリのエラー（③） |

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

1つやるごとに：`isukit deploy` → `isukit bench "何を変えたか"` → `isukit show`。**数字だけで採否を決める。** 前の回と比べたいときは `isukit show 2`（1つ前）。

ベンチのスコアは揺らぐので、小さい差は有意でない。`isukit attribute` で最後の2回の計測を比較し、差が ±10% を超えているかを判定。

```
isukit attribute           # デフォルト：±10% を閾値に KEEP / REVERT / INCONCLUSIVE を返す
isukit attribute 5         # 閾値を ±5% に設定
```

1回の変更で複数のステップを入れていたら、どちらが効いたか分からない。必ず1つずつ。

### フェーズ3 — サーバー分散（40–60%）

**1台をプロファイルし終えて、ボトルネックが分かってから。** 何が重いか分からないまま分けると、問題が移動するだけでネットワーク遅延が増える。

1. **役割を付け直す。** 例：`isukit host role <ip1> web,app` / `isukit host role <ip2> app` / `isukit host role <ip3> db`。以後 `deploy` / `restart` は app の台、nginx のログと alp は web の台、スロークエリと slow は db の台に行く（§2 の「複数インスタンス」）
2. **構成は手で変える**（isukit は役割に合わせて送り先を変えるだけ）：
   - db の台：MySQL が他の台から接続を受けるようにする（`etc/` の `mysqld.cnf` の `bind-address`、接続用ユーザーの作成）
   - app の台：アプリの接続先を db の台に向ける。接続設定は**コードではなく env ファイル**（`.isukit/manifest` の `ENV_FILE`、元の中身は `hosts/<台>/` に控えがある）
   - db 以外の台：MySQL を止めて自動起動も切る（`sudo systemctl disable --now mysql`）。止めるだけだと `finalize` の再起動で復活する
   - web の台：nginx の upstream に app の台を並べる（`etc/` の nginx 設定）
3. `isukit deploy` → `isukit bench` → `isukit show`。**DBがボトルネックでなかった場合ここでスコアが落ちる。** 落ちたら戻す。`show` の hosts 欄で、負荷が狙いどおりの台に移ったかを見る
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
isukit finalize          # logs off → 全ホスト再起動 → unitの復帰確認 → 採点用ベンチ
```

`finalize` があるのは、**実行時だけの状態は再起動で消える**のに、最終採点は再起動されたかもしれないマシンで走るから。複数ホストがある場合は全部を再起動し、各台の役割に必要な unit（app ならアプリ、web なら nginx、db なら MySQL）が自分で上がってくるかを確かめる。再起動順は保証されない。以下は手で確認する：

- [ ] 依存している全サービスが **enabled**（動いているだけでは不十分）：`.isukit/manifest` の各unitに `systemctl is-enabled <unit>`
- [ ] やった `SET GLOBAL` が**設定ファイルにも書いてある**。MySQLの実行時変数は再起動で消える
- [ ] 必要なものが `/tmp` に無い
- [ ] ディスクに空きがある：`df -h`
- [ ] スロークエリログが **off** で、ログファイルを削除済み（`long_query_time=0` はディスクを埋める）
- [ ] アプリが完全なコールドスタートから手作業なしで起動する
- [ ] db 以外の台で MySQL が**止まったまま**（`disable` し忘れると再起動で復活し、メモリと CPU を食う）
- [ ] app の台がすべて db の台に接続している（db の台が最後に上がっても、アプリが再接続できる）

そのあとベンチを2〜3回回す。スコアは毎回ぶれる。**知りたいのは「運が良かった数字」ではなく「安定して出る数字」。** 終盤の回で失敗したら、`isukit score` の最後の緑の sha に戻る時間がまだある。

**95%で手を止める。**

---

## 7. 詰まったとき（isukit のクセ）

**最初に試すこと：** `isukit doctor` を走す。非破壊的な診断と自動修復を一通り試す。

```
isukit doctor   # config / 接続 / manifest / unit / ツール / ログ / ディスク / ベンチモードを確認・修復
isukit os       # サーバーのスナップショット（uptime / vmstat / iostat / mpstat / free / df）
```

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
| `BENCH_CMD` が自動生成されたが動かない | `.isukit/bench-help.txt` に本物のフラグ一覧がある。直したら `isukit benchcmd '<行>'`。`isukit bench` は失敗しても生ログを `.isukit/bench-*.log` に残す |
| ベンチマーカーが見つからない | ベンチが別ホストにある構成では正常。`isukit host bench <target>` を設定して `isukit benchprobe` を打ち直す |

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

---

## 8.5. キットの構成

`isukit` リポジトリは以下のサブディレクトリを持つ：

- **`launch/`** — AWS の pre-contest staging と T+0 インスタンス起動スクリプト（`prestage.sh`、`launch.sh`、`user-data.sh`）。本番で組織が指定した AMI をそのまま起動する場合のみ使用。詳しくは [`launch/README.md`](launch/README.md)
- **`skills/isucon/`** — Claude AI の skill ファイル（`.claude/skills/` にシンボリックリンク）。計測 → 診断 → 修正 → ship → 再計測のループを支援するプロンプト集。`/isukit` でアクティベート
- **`test/`** — ISUCON の過去年度の実際の systemd unit 設定と nginx 設定をフィクスチャとして保持し、isukit の発見ロジックをオフラインで検証するテストスイート。`test/run-all.sh` で実行。`test/README.md` の「## Known discovery gaps」セクションが tool の実際の限界を記録している

---

## 9. コマンド早見表

```
isukit go --new <team>/<repo> <host> -i <鍵> [--invite u1,u2]
                               # リポジトリがまだ無いとき：サーバーから作って push（コード＋設定の2つのベースライン）
isukit go <repo-url> <host> -i <鍵>   # 丸ごと1コマンド：clone→probe→setup→logs→benchprobe
isukit init <repo-url> [dir]   # clone（既存ディレクトリはそのまま採用）＋ work ブランチ
isukit host app|bench <target> # ssh先を .isukit/config に設定（'local' も可）
isukit host add <target>       # 追加ホストをアプリの台として追加
isukit host role <target> <役割> # app / web / db をカンマ区切りで（.isukit/hosts に書く）
isukit hosts                   # ホストと役割、各台で動いているべき unit の一覧
isukit probe                   # サーバーを調査して .isukit/manifest を書く。インフラ変更後は毎回
isukit benchprobe              # ベンチマーカーを発見して BENCH_CMD を自動生成（probe が自動で呼ぶ）
isukit benchcmd '<行>'         # BENCH_CMD を手で上書き／引数なしで現在値を表示
isukit benchmode [auto|manual] # ベンチモードを表示または変更
isukit unit <unit名>           # probe のunit選択を手で上書き
isukit logs on|off             # nginx LTSV ＋ MySQLスローログ
isukit etc adopt|status|push|pull  # nginx/MySQL/unit 設定を repo の etc/ に移して /etc からリンク・反映
isukit doctor                  # config / 接続 / manifest / unit / ツール / ログ / ディスク / ベンチモードを診断・修復
isukit os                      # サーバーのスナップショット（uptime / vmstat / iostat / mpstat / free / df）
isukit bench "メモ"            # スコア＋git sha を .isukit/scores.tsv に記録 (manual モード: --score N / --fail)
isukit score                   # 全履歴
isukit show [n]                # 保存した回：台ごとの CPU・プロセス、alp、slow、pprof（logs on の間の bench が保存）
isukit attribute [noise_pct]   # 最後の2回計測の有意差を判定（デフォルト ±10%）
isukit alp                     # エンドポイントを合計レスポンスタイム順
isukit slow                    # クエリを合計時間順
isukit pprof 30                # GoのCPUプロファイル → .isukit/cpu.pprof
isukit deploy                  # rsync＋ビルド → systemdのExecStartパス → 再起動
isukit restart                 # アプリの unit を再起動（app の役割を持つ全台）
isukit ship "<メモ>"            # 新ブランチ作成 → commit → push → draft PR
isukit revert [<sha>]          # git revert で変更を打ち消す
isukit finalize                # 終盤の締め処理一式（全ホスト再起動）
```

**repo に入るもの**：`etc/`（`/etc` からリンクされている設定の実体）、`hosts/<台>/`（各台の env ファイルの控え）

**ファイル**（全部 git-ignore 済み、各リポジトリの `.isukit/` の中）

```
.isukit/config         APP, BENCH, BENCH_CMD, SSH_OPTS, EXTRA_UNITS, ETC_REPO, PPROF_*   ← go/benchprobe が書き、benchcmd で直す
.isukit/manifest       probe の結果。他の全コマンドが読む
.isukit/hosts          台ごとの役割（isukit host role が書く）
.isukit/scores.tsv     日時 / sha / スコア / メモ / その回の保存先
.isukit/runs/<日時>/   その回の結果：bench.log・hosts.txt（台ごとの CPU）・alp.txt・slow-<台>.txt・cpu.pprof
.isukit/bench-help.txt ベンチマーカーの --help 全文
.isukit/ssh_config     `go -i` が書く ssh 設定
```

### manifest の主なキー

| キー | 意味 |
|---|---|
| `APP_UNIT` | 検出したアプリの systemd unit 名 |
| `APP_UNIT_CONFIDENCE` | `APP_UNIT` の確信度：`high` / `low` / `override` |
| `ENV_FILE` | アプリが読む env ファイルのパス |
| `WEB_SERVER` | 検出した web サーバー（`nginx` など） |
| `DB_SERVER` | 検出したデータストア（`mysql` など） |
| `STACK_IN_DOCKER` | `1` なら web/db の少なくとも一方は `docker ps` でしか見つかっていない（`systemctl` は何も見ていない）。`logs on` / `slow on` はホスト側の設定を書き換えるだけなので無反応 — compose ファイル/コンテナ設定を直接編集して `isukit restart` |
| `PROC_MANAGER` | `systemd` か `supervisor`。`supervisor` のとき `APP_UNIT` は `supervisor.service` になり、それを再起動すると配下の全プログラムが道連れで再起動する |
| `SUPERVISOR_PROGRAMS` | `PROC_MANAGER=supervisor` のときだけ立つ。`supervisorctl status` のプログラム名一覧（スペース区切り）。1言語だけ再起動したいなら `supervisorctl restart <program>` を使う |
