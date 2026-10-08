# ISUCON 実戦ランブック

> **迷ったらここだけ見る。** 上から通読しなくてよい。
> 今いるフェーズの節だけ開く。コマンドは全部コピペ可。
>
> 設計の理由・内部の仕組みは [`README.md`](README.md)。英語版の旧ランブックは [`RUNBOOK.en.md`](RUNBOOK.en.md)。

---

## 0. 三行で

1. `isukit` は「計測できる状態のサーバー」を用意して、**変更1つごとにスコアと計測を記録し、2人で同じ記録を見ながら回す**ための道具。インストールは `go install` の1行（§1）。
2. **サーバーに SSH できるまでは、当日のマニュアルに従う**（§2-1。ISUCON14 は CloudFormation のテンプレート）。練習は `launch/` で自分で立てる（§2-2）。SSH できた後の手順は、本番も練習も同じ。
3. **最初の5分で、自分たちのリポジトリを作る**（§3、`isukit go --new`）。ここを飛ばすと並行作業できない。

---

## 1. isukit とは何か

配布元は https://github.com/isucon2026/isukit （public）。**Go のバイナリ1つ**で、中に bash のスクリプト（手元で動く `lib/`、サーバーで動く `remote/`）を埋め込んでいる。サーバー側に入れるものは無い（ssh でスクリプトを送るだけ）。

インストールは1行（本番は凍結したタグを指定する。§3.5）：

```
go install github.com/isucon2026/isukit/cmd/isukit@latest
isukit version                      # 全員で同じ表示か確かめる
```

Go が無い環境では bash 版も入る：`curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh | bash`

主なコマンド（全部は §9 と `isukit help`）：

| | コマンド | 中身 |
|---|---|---|
| **① 立ち上げ** | `isukit go --new <team>/<repo> <app-host>`／`isukit go <repo-url> <app-host>` | リポジトリを作る（サーバーのコード・設定をベースラインに）／clone する → サーバーを調査 → ツール導入 → 計測ログ on → ベンチの準備 |
| **② 構成** | `isukit host role` `hosts` `probe` `etc` `env` | 台ごとの役割（app / web / db）、全台の調査、設定（`etc/`）と env ファイル（`hosts/<台>/`）を repo で管理 |
| **③ 計測** | `isukit bench` `show` `score` `attribute` `alp` `slow` `pprof` | 1回のベンチごとに、台ごとの CPU・alp・slow・pprof を保存（`show`）。`attribute` は **main の最新の回**と比べて KEEP / REVERT / 判断不能 |
| **④ 反映** | `isukit lock` `deploy` `ship` `unlock` | サーバーを自分の番として確保 → main を含むコミット済みのブランチだけを deploy。`ship` はビルドを確かめてから PR |
| **⑤ 締め** | `isukit final check` `final apply` `final strip` `finalize` | スコアを削る出力を止める（`strip` は機械的に消せる分を書き換え） → 全台再起動 → サービスと HTTP の応答を確認 → 最終ベンチ |

**なぜリポジトリを読まずにサーバーに聞くのか**：ISUCONのリポジトリ構成は年ごとに何も安定していない。Goのディレクトリ名（`webapp/go` か `webapp/golang`）、ビルド方法（Make → Taskfile → 無し）、docker composeの有無、unit名、envファイルの場所と変数名、ベンチのフラグ名 — 全部違う。systemdに問い合わせるのが全年代で唯一通用する手。

**`BENCH_CMD` は自動生成される（練習のみ。本番はポータル）。ただし唯一「人間が直す可能性が高い」行**でもある。ベンチマーカーのターゲット指定フラグは毎年違う（`-target` / `-target-url` / `-target-host` / `-target-addr` / `--target`）ので、isukit は**ベンチマーカーのバイナリ自身の `--help` を読んで**使えるフラグを判定し、コマンド行を組み立てて表示する。違っていたら `isukit benchcmd '<正しい行>'` で上書きする。使えるフラグの全一覧は `.isukit/bench-help.txt` に落ちている。

チームで共有するもの（役割 `isukit.hosts`、共通の設定 `isukit.conf`、`etc/`、`hosts/<台>/`、計測の記録 `isukit-runs` ブランチ）は repo に入り、各自の手元に残るのは ssh 先や鍵（`.isukit/config`）と probe の結果だけ。

### ベンチモード：`auto` と `manual`

**`auto` モード** — `isukit bench` は ssh で BENCH_CMD をベンチ用ホストで走す。練習環境の標準。

**`manual` モード** — ベンチマーカーはポータル（web UI）から起動され、スコアは人間が記録する。ISUCON11以降の**本番環境はこれ**。ssh でベンチを走すのは禁止事項。

```
isukit bench --score 12345 "インデックス追加"    # スコアを記録
isukit bench --fail "タイムアウト"                # 失敗を記録
```

`isukit benchprobe` はベンチマーカーバイナリが見つからないと自動的に `manual` モードに切り替える。モードはいつでも手で変更可：

```
isukit benchmode manual      # auto ↔ manual に切替
isukit benchmode             # 現在のモードを表示
```

**なぜ重要か**：本番ではベンチマーカーはサーバー上に無く、ポータルから起動される。スコアを ssh で記録できるのは練習だけ。本番に向けての練習では `manual` モードを試しておく。

---

## 2. サーバーはどこから来るのか

### 2-1. 本番（ISUCON2026）

- **日時：2026年10月31日（土）10:00–18:00 JST（8時間）**
- チームは**最大3名**（このチームは2人）
- **参加登録は2026年8月上旬に締切済み**（300/300/335の3回に分けて募集し全枠終了）
- 今年の運営窓口はさくらインターネット（会場は大阪本社 Blooming Camp）。ただし**競技環境はさくらのクラウドではなくAWS**
- レギュレーション（[原文](https://isucon.net/archives/59966826.html)）：「チームはAWSアカウントを各自で用意し、それを競技に利用する」「主催者より競技開始後に指定されたAMIを利用してAmazon EC2上にサーバーを起動」「**具体的なサーバー起動方法については当日マニュアルに記載される**」。インスタンスの種類・台数・リージョンは書かれていない

**サーバーに SSH できるまでは、当日のマニュアルに従う。** isukit はそこには関わらず、SSH できた後（§3 の `go --new`）から使う。

**ISUCON14 の実例**（レギュレーションの文言は今年とほぼ同じ。同じ形になると考えて準備し、決めつけない）：

- ポータルから**チームごとの CloudFormation のテンプレート**をダウンロード（共有厳禁）し、**東京リージョン**でスタックを作る。c5.large×3、EBS、EIP×3、VPC、セキュリティグループ、Lambda、IAM ロール×2 ができる
- SSH は **`isucon` ユーザーと、GitHub に登録した鍵**（`ubuntu` や `.pem` ではない）。isukit には `isucon@<IP>` を渡す（GitHub の鍵がいつもの鍵なら `-i` は不要）
- **事前の「AWS 環境チェック」が全選手に必須**（期限までにスタックを作って SSH を確認しないと失格）。今年の告知が出たらすぐやる
- テンプレートで作られたもの（インスタンスタイプ、セキュリティグループ、`envcheck`）を変えると失格

**会社のサンドボックスを使う場合の注意**（レギュレーション：「既存のリソースや設定に起因して発生する問題についてはサポートを行わない」）：

- **IAM ロールの作成が禁止**されているとスタックが作れない。主催者のロールにアカウント内の他のリソースを読む権限を渡すことが、会社の規程上問題になる場合もある
- 22番ポートを全世界に開けたセキュリティグループを**自動で閉じる仕組み**があると、**競技中に SSH が切れる**
- vCPU（c5.large×3 = 6）と EIP（3つ）の上限
- → 事前にサンドボックスの管理者に確認し、**予備のチーム用 AWS アカウント**も用意しておく

### 2-2. 練習（各自の AWS サンドボックスアカウント）

> **ここは練習専用の手順。** 本番のテンプレートはチーム固有でポータルからしか手に入らないので、練習は過去問の AMI を `launch/` で自分で立てる。本番の起動は §2-1（当日のマニュアル）。`launch/` を本番で使うのは、マニュアルが「AMI X をタイプ T で N 台起動」とだけ言って起動方法を任せてきた場合だけ。
>
> ログインは `ubuntu` ユーザーと `.pem` の鍵で、必要なら `sudo su - isucon`。

**ap-northeast-1（東京）固定。** ログインと、今どのアカウントにいるかの確認：

```
aws sso login --profile sandbox
export AWS_PROFILE=sandbox AWS_REGION=ap-northeast-1
aws sts get-caller-identity        # 別アカウントに立てる事故がいちばん多い
```

**本番と同じ流れを頭から最後まで一度通す手順は [`REHEARSAL.md`](REHEARSAL.md)**（3台＋ベンチ1台、確認項目と記録シート付き）。

#### 推奨：`launch/` のスクリプトを使う

キット同梱の `launch/prestage.sh` / `launch/launch.sh` を使う。生のAWS CLIを手で組み立てるより速く、鍵・セキュリティグループ・ディスクの大きさの失敗が起きにくい。2026-09-28に実アカウント（`395103361978`）で end-to-end 検証済み：

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
# ② launch — 練習を始めるとき（AMI は過去問のもの。§2-2 の表）
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

**2人で並行して触るための必須手順。** 競技開始の時点では、コードは配られたサーバーの上にしか無い。公開リポジトリ（`isucon/isucon13` など）は読む専用で、push できない。

**1人（リポジトリ係）が1コマンドで作る：**

```
# 本番（ISUCON14 の形なら isucon@ と GitHub の鍵。ベンチ用サーバーは渡さない＝ポータル）
isukit go --new <team>/<private-repo> isucon@<app-host> --invite <相手のGitHub名>
# 練習（launch/ で立てた台）
isukit go --new <team>/<private-repo> ubuntu@<app-host> [ubuntu@<bench-host>] -i ~/.ssh/<鍵>.pem \
  --invite <相手のGitHub名>
```

これで次のことを順番にやる：

1. **コードのベースライン。** probe で見つけたサーバーの webapp（`SRC_DIR`）を手元に持ってきて、`git init` → コミット → `gh repo create --private` → push。`--invite` の人を Collaborator（push 権限）に招待する。GitHub の認証は手元の `gh` だけを使い、サーバーには何も置かない
   - 入れないもの：`node_modules`・ログ・ビルド済みのアプリ（systemd が動かしているバイナリ）・10MB を超えるファイル（DB のダンプや大きな画像など）。どれも `.gitignore` に書かれ、サーバー側には残る
2. **設定のベースライン。** `/etc` の nginx・MySQL・アプリの unit ファイルを repo の `etc/` に移して、`/etc` からシンボリックリンクを張る（`isukit etc adopt` と同じ。置き換えたファイルは `/etc/isukit-orig/` にバックアップ、MySQL の AppArmor 許可も追加）。各台の env ファイル（`/home/isucon/env.sh` など）は `hosts/<台>/` にコピーする（台ごとに中身が違うのでリンクはしない）。以後はこの repo のコピーが正で、編集して `isukit env push`（または `deploy`）で各台に書き込む。ここまでを2つ目のコミットにして push
3. **CI。** main と PR で `go build` を回す最小の CI（`.github/workflows/isukit-ci.yml`、`go vet` は表示だけで止めない）を3つ目のコミットとして push。`DISCORD_WEBHOOK_GIT` があれば、GitHub から #git への通知も設定する
4. **いつもの `go` の続き。** ツールのインストール → 計測ログ on → ベンチコマンドの組み立て

終わると、`main` に「コードのベースライン」「設定のベースライン」「CI」の3コミットがあり、手元は `work` ブランチにいる。**この2つが唯一の戻り先。** 作らずに走り出すと、スコアが落ちたときに戻る場所が無い。

**もう1人は、できたリポジトリを渡すだけ：**

```
isukit go git@github.com:<team>/<private-repo>.git isucon@<app-host>                            # 本番
isukit go git@github.com:<team>/<private-repo>.git ubuntu@<app-host> -i ~/.ssh/<鍵>.pem          # 練習
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

## 3.5. isukit の凍結（本番1週間前）

本番当日に全員が入れるのは **main の最新ではなく、凍結したタグ**。前日の変更で壊れた isukit を、当日に全員が入れる事故を防ぐ。

**1週間前（2026-10-24）**：main への機能追加を止め、CI が通っている main にタグを打つ（Go のモジュールとして扱われるので、タグは `v1.0.0` の形）。

```
git switch main && git pull
gh run list --branch main --limit 1     # 最新が success であること
git tag -a v1.0.0 -m "ISUCON2026 freeze"
git push origin v1.0.0
```

**凍結のあと**：直すのは、本番で困るバグだけ。PR → CI が通る → マージ → `v1.0.1`、`v1.0.2` … とタグを進める。

**前日にやること**：
- 最後のタグをチームに伝える
- 各自のシェルの設定の Discord の Webhook（3行の `export`）を、**本番のチャンネルのもの**に書き換える（§3.6）。書き換え忘れは、本番の通知が練習のチャンネルに流れることで分かる（通知の先頭の `[repo名]` で、どの repo からかも分かる）

**当日の入れ方**（全員）：

```
go install github.com/isucon2026/isukit/cmd/isukit@v1.0.x
# Go が無い場合：
curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh | ISUKIT_REF=v1.0.x bash
isukit version                           # 全員の表示が同じ v1.0.x であること
```

`go install` で新しいタグが見つからないときは、Go のモジュールプロキシの反映待ち（数分）。急ぐなら `GOPROXY=direct go install …`。

---

## 3.6. Discord（チャンネルと通知）

人が話す場所と、isukit・GitHub が自動で書く場所を分ける。自動の投稿が会話に混ざると、相談が流れて読めなくなる。**さらに「練習」と「本番」のカテゴリに分け**、#ベンチ・#サーバー・#git をそれぞれに置く（#作戦とボイスは共通でよい）。練習（過去問）と本番のスコアや PR が混ざると、本番の後半に推移をたどれなくなる。isukit の通知は先頭に `[repo名]` が付くので、もし混ざってもどの repo のものか分かる（`NOTIFY_TAG` で上書きできる）。

| チャンネル | 書き込む人 | 中身 |
|---|---|---|
| **#作戦** | 人 | 相談・決めごと・「次これやる」。マニュアルの要点（スコアの計算式・失格条件・禁止事項）と、決めた値（`FINAL_CHECK_PATH` など）はピン留め |
| **#ベンチ** | isukit | bench の結果：スコア、main との差と判定、ブランチ・誰が・何を変えたか、PR、張り付いた台、alp の上位3つ。**スコアの推移を上から読める場所** |
| **#サーバー** | isukit | lock / unlock（誰の番か）、deploy（誰がどのブランチを出したか）、`final apply`・`finalize` の結果 |
| **#git** | GitHub | PR の作成・マージ、main への push、CI の失敗 |
| ボイス | 人 | 競技中はつなぎっぱなし。「今から lock する」「KEEP だからマージする」を声で |

**準備（前日まで）**：練習用・本番用の #ベンチ・#サーバー・#git にそれぞれ Webhook を作り（練習の間は練習用を、§3.5 の前日に本番用へ書き換える）（チャンネルの設定 → 連携サービス → ウェブフック）、URL を**各自のシェルの設定**（`~/.zshrc` など）に書く。こうすると、競技当日に作る repo でも最初から効く（`.isukit/config` に書いてもよい）。URL を知っていれば誰でも投稿できるので、repo（`isukit.conf` を含む）には入れない。

```
export DISCORD_WEBHOOK_BENCH='https://discord.com/api/webhooks/…'   # #ベンチ
export DISCORD_WEBHOOK_OPS='https://discord.com/api/webhooks/…'     # #サーバー
export DISCORD_WEBHOOK_GIT='https://discord.com/api/webhooks/…'     # #git
# 片方だけなら DISCORD_WEBHOOK に書けば全部そこへ
```

**#git は GitHub が書く。** `isukit go --new` が repo を作るときに、`DISCORD_WEBHOOK_GIT` を GitHub の repo の Webhook（Discord の `/github` 宛て）に登録し、push・PR・CI の結果が流れるようにする。あとから設定するときは `isukit notify github`。

設定が無ければ何も送らない。送信は最大5秒で、失敗しても警告だけで処理は止まらない（Discord の障害で計測が止まらないように）。

---

## 4. チームルール（クロック開始前に合意する）

**2人とも開発する。サーバーは交代で使う。** ブランチは並行して作れるが、サーバーは1組で、ベンチも1回に1本（本番のポータルも同じ）。だから「計測の番」を回す：

```
# 自分の番が来たら
git fetch && git rebase origin/main     # main の最新 ＋ 自分の変更1つ、を測る
isukit lock                             # サーバーを確保（相手の deploy / bench は止まる）
isukit deploy
isukit bench "何を変えたか"
isukit show                             # 台ごとの CPU・alp・slow・pprof
isukit attribute                        # main の最新の回と比べる（相手のブランチの回とは比べない）
# KEEP なら PR をマージ（gh pr merge）／ REVERT なら main を deploy し直す
isukit unlock                           # 相手の番
```

- **サーバーを変えるコマンドは、ロックを取ってから。** `deploy`・`bench`・`etc push`・`env push`・`logs`・`final`・`finalize`・`restart` は、相手がロックしていると「busy — <誰>: <何を> for N分」と出して止まる（自分のコマンドも、実行中だけ自動でロックする）。相手が離席して残ったロックは `isukit unlock --force`。
- **deploy できるのは「main の最新を含む、コミット済みのブランチ」だけ。** 未コミットの変更や、main を取り込んでいないブランチは止まる（取り込まずに出すと、相手がマージした変更をサーバーから消してしまう）。`--force` で強行できるが、その回のスコアは誰にも再現できない。
- **deploy したものをサーバーが覚えている。** `bench` は手元の HEAD ではなく、サーバーに deploy されたブランチと commit をスコアに記録する。
- **記録は2人で共有。** ベンチの記録は repo の `isukit-runs` ブランチに push され、2人とも `isukit score` / `show` / `attribute` で同じ記録を見る。
- **1ブランチ＝1変更。** `isukit ship "<メモ>"` が、手元で `go build` / `go vet` を通してから、`isukit/<slug>` ブランチで commit → push → draft PR を作る。大きすぎる変更（既定 `SHIP_MAX_FILES=10` ファイル／`SHIP_MAX_LINES=300` 行超）は `ship` 自体が止める — `--only <path>...` で対象を絞るか、`ISUKIT_OVERRIDE='<理由>'` で通す。
- **採用したらすぐマージ。** マージを溜めると、相手のブランチがすぐ古くなる。
- **担当を分ける。** 例：1人は DB（スキーマ・インデックス・クエリ・MySQL の設定）、1人はアプリ（ロジック・キャッシュ・nginx）。同じファイル（特に `etc/`）を2人で触らない。
- **サーバーの上で直接編集しない。** 設定は `etc/`、接続先などは `hosts/<台>/env.sh`、DB のスキーマ変更は問題の初期化用 SQL（repo）に書く。ssh で見る（ログ、`top`、`EXPLAIN`）のは自由。
- **スコアが落ちたら即 revert。** 競技中にリグレッションをデバッグしない。`attribute` が REVERT なら main を deploy し直して次へ。
- **スコアは commit に紐づく。** `bench` が記録するたびに、その sha へ `git notes --ref=isukit` でスコアを付け、`ship` 時に push する（`git log` でそのまま見える／rebase・amend後も追従）。素の `git cherry-pick` は note を引き継がないので、スコア付き commit を別ブランチに持っていくときは `isukit pick <sha>` を使う。
- **30分タイムボックス。** 30分でスコアが動かない変更は捨てる。粘らない。
- **数字を声に出す。** 記録は共有されるが、ベンチの結果は毎回相手に伝える。
- **レギュレーション違反は `isukit rules check` が検査する。** クロック終了後（`CONTEST_END`）のサーバー変更や許可外ホストへの接続は自動で止まる。条文ごとの対応は `isukit rules show`。当日のマニュアルと食い違うときだけ `ISUKIT_OVERRIDE='<理由>'`（`.isukit/overrides.log` に記録）。

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
# 本番（ISUCON14 の形なら）：isucon ユーザー＋GitHub に登録した鍵
ssh isucon@<app-host> true                        # 全台、今この瞬間に通ること
# 練習：ubuntu ユーザー＋.pem
ssh -i ~/.ssh/<practice>.pem ubuntu@<app-host> true
chmod 600 ~/.ssh/<practice>.pem                   # 644 だと ssh が拒否する
```

**本番ではベンチマーカーのサーバーに触らない**（SSH も禁止事項）。ベンチはポータルから流す（`manual` モード）。

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

**`alp` の URL のまとめ方は、ログから自動で作る**（数字・UUID・長いトークンの部分と、ユーザー名のように値の種類がとても多い部分をまとめる。`/api/user/me` のように桁違いに多く呼ばれるものは、まとめずに残す）。まとめ方がおかしいときは `isukit alp --patterns` で確認し、`.isukit/config` の `ALP_MATCHES` にカンマ区切りの正規表現を書けば、そちらが優先される。

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
   - app の台：アプリの接続先を db の台に向ける。接続設定は**コードではなく env ファイル**にある。repo の `hosts/<台>/env.sh`（無ければ `isukit env pull` で取り込む）を編集して commit し、`isukit env push`（または `deploy`）で書き込む。サーバーの上で直接編集しない
   - db 以外の台：MySQL を止めて自動起動も切る（`sudo systemctl disable --now mysql`）。止めるだけだと `finalize` の再起動で復活する
   - web の台：nginx の upstream に app の台を並べる（`etc/` の nginx 設定）
3. `isukit probe` をし直す。全台を調べて、役割と実際に動いているものが食い違っていれば警告する（db の台で MySQL が動いていない、db 以外の台で MySQL がまだ動いている、app の台どうしで unit 名や置き場所が違う、など）
4. `isukit deploy` → `isukit bench` → `isukit show`。**DBがボトルネックでなかった場合ここでスコアが落ちる。** 落ちたら戻す。`show` の hosts 欄で、負荷が狙いどおりの台に移ったかを見る
5. webサーバーの後ろにアプリ2台目を置いてロードバランス

分散のステップは毎回「再起動後に生き残らないと困るもの」を増やす。何を増やしたか書いておく。フェーズ5で確認する。

### フェーズ4 — アプリロジック（60–80%）

天井が最も高く、ベンチの整合性検査を壊すリスクも最も高い。

- [ ] **リクエストごとに変わらないものをキャッシュ。** 1台ならプロセス内、分散後は共有ストア。**invalidationを間違えると整合性検査で落ちて、どれだけ速くても0点**
- [ ] **読みが支配的なら、読み時ではなく書き時に計算しておく**
- [ ] **外部呼び出しとDBの往復をまとめる**
- [ ] **捨てるデータを作るのをやめる** — 使わない列、アプリ側で捨てる行、組み立ててから捨てるレスポンス
- [ ] **上の全部、信じる前にプロファイルを取る。** `net/http/pprof` が入っていれば `isukit pprof 30`。入っていなければ `isukit pprof on` で早めに配線する（`func main()` を自動検出、sentinel付き）

採用した変更のあとは毎回 `isukit alp` を取り直す。ボトルネックは動くので、フェーズ1のリストはこの時点でもう古い。

### フェーズ5 — 凍結と検証（80–100%）

**80%で変更凍結。** どんなに良いアイデアでも、ここから先は新しい最適化をしない。**このフェーズは稼いだ分を失わないための時間。**

```
isukit final check       # スコアを削る出力・計測が残っていないか一覧にする（何も変えない）
isukit final apply       # 設定で止められるものを止める（etc/ の差分として）＋ 全台の後片付け
isukit final strip       # 機械的に消せる分の差分を見る（sentinel ブロック・pprof import/route）
isukit final strip --apply   # 書き込む（未コミット）。go build ./... が通らなければ全部戻す
# 残りのアプリのコードの pprof・ロガー・デバッグ設定は手で外す → isukit deploy
isukit bench "final: 出力オフ"   # 止めた状態でスコアが上がるか（下がらないか）を確かめる
isukit ship "final: 出力オフ"
isukit finalize          # logs off → 全ホスト再起動 → unitの復帰確認 → 採点用ベンチ
```

**最後の計測の前に、誰も読まない出力を全部止める。** リクエストのたびに書かれるログは、それだけでスコアを削る。isukit の計測用ログだけでなく、配られたときから有効なものも対象：

| `final check` が見るもの | `final apply` |
|---|---|
| nginx の `access_log`（配られたときから有効。指定が無くても既定のファイルに書く） | repo の `etc/` で `access_log off;` にして `etc push` |
| MySQL のスロークエリログ・general log（実行中の値と `.cnf`） | `etc/` の `.cnf` を 0 にして push、実行中の値も off |
| sysstat の定期収集、isukit の記録プロセス・計測ファイル、isukit の計測ログ | 止めて消す |
| アプリが直近10分に journal に書いた行数 | 一覧に出すだけ |
| アプリの Go コードの `net/http/pprof`、echo / chi / gin のリクエストロガー、デバッグ設定、`log.Print` | パターンで機械的に消せる分だけ `final strip` が消す（下記）。残りは一覧に出すだけ（外し方はアプリ次第なので手で直す） |

設定の変更は repo の差分なので、止めたことでスコアが落ちたら `git revert` で戻せる。`finalize` も最初に `final check` を回し、残っているものがあれば警告する。

**`// isukit:measure-begin` 〜 `// isukit:measure-end`（Go。他の言語は `#` コメントで同じ）で挟んでおいたコードは、`isukit final strip` がブロックごと sentinel ごと消す。** 計測用に手で足した一時コードはこの印で囲んでおくと、最後に手で探して消さずに済む。`final strip` はこれに加えて `net/http/pprof` の blank import と、その登録行（`pprof.Index` などを渡す `HandleFunc` 呼び出し、`pprof.Handler(...)`）だけをパターンで消す。それ以外（`gin.Logger()` などのロガー、デバッグスイッチ）は `final check` / `final strip` の一覧に残り続け、手で判断する。フラグ無しは diff を見るだけ、`--apply` で書き込み（未コミット）、`go build ./...` があれば通るかまで確認して通らなければ全ファイル元に戻す。

**sentinel で挟めない形（3時の手直しなど）の計測コードは、commit 自体にラベルを貼る。** 2通り：`isukit ship --measure "<メモ>"` は trailer `Isukit-Measure: true` を commit メッセージに足す。後から貼るなら `isukit measure <sha>`（`refs/notes/isukit-measure` に note を足す。push は `ship` が `refs/notes/isukit` と一緒に行う）。`isukit measure --undo <sha>` は note だけ外せる（trailer は commit メッセージの書き換えになるので外せない、と言ってくる）。`isukit measures` が今 HEAD から見えるラベル付き commit を一覧にする（sha・日付・件名・著者。無ければ「no measurement commits live in HEAD」）。revert 済みの commit（`This reverts commit <sha>` をメッセージに持つ HEAD 上の commit がある）や、別ブランチにしか無い commit は数えない。`isukit finalize` はこれが残っていると `rules_override` を踏まえた上で止まる。`isukit final strip` は一覧の先頭にラベル付き commit を出し、`--apply` で新しい順に `git revert --no-edit` していく — コンフリクトが出たら即座に止まり、残りは revert しない（`git revert --abort` で戻す）。

**この sentinel ブロックを実際に作っているのが `isukit pprof on`** — `func main()` を1つだけ自動検出して、上記と同じ sentinel 付きで private mux・ループバックのみのリスナーを配線する（複数/0個の `func main()` やビルド破壊は失敗として止める）。pprof だけを外したいなら `isukit pprof off` が `final strip --apply` を直接呼ぶ（別の消し方は無い）。

`finalize` があるのは、**実行時だけの状態は再起動で消える**のに、最終採点は再起動されたかもしれないマシンで走るから。複数ホストがある場合は全部を再起動し、各台の役割に必要な unit（app ならアプリ、web なら nginx、db なら MySQL）が自分で上がってくるかを確かめる。再起動順は保証されない。

**unit が動いていても、応答するとは限らない**（DB につながらずに 500、nginx の転送先が無くて 502）。そこで再起動後に HTTP でも確かめる：web の台は nginx 経由（`http://localhost/`）、app の台はアプリに直接（unit のプロセスが待ち受けているポート）。2xx〜4xx なら応答あり、応答なし・5xx なら失敗で、起動途中を考えて最大60秒待つ。確かめるパスは `.isukit/config` の `FINAL_CHECK_PATH`（既定 `/`）で、**DB を触るエンドポイントにしておく**と DB への接続まで確かめられる。ポートが見つからないときは `FINAL_APP_PORT`。失敗した台があれば、ポータルで最終計測を流す前に直す。

以下は手で確認する：

- [ ] 依存している全サービスが **enabled**（動いているだけでは不十分）：`.isukit/manifest` の各unitに `systemctl is-enabled <unit>`
- [ ] やった `SET GLOBAL` が**設定ファイルにも書いてある**。MySQLの実行時変数は再起動で消える
- [ ] 必要なものが `/tmp` に無い
- [ ] ディスクに空きがある：`df -h`
- [ ] `isukit final check` で hosts の項目が0件（スロークエリログ・アクセスログ・計測ファイルは `final apply` が止めて消す）
- [ ] アプリのコードの pprof・リクエストロガーを外したか、外さない判断をしたか（機械的に消せる分は `isukit final strip --apply`）
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
| `pprof` が繋がらない | アプリに `net/http/pprof` の import とリスナーが必要。無ければ `isukit pprof on` が `func main()` を自動検出して配線する（`func main()` が無い／複数ある場合は失敗するので手で足す） |
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
| クロック終了後にサーバーを変更した | `isukit rules check` / `CONTEST_END` ガードが止める（`ISUKIT_OVERRIDE` で強行可、ログに残る） |

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
isukit env status|pull|push    # 各台の env ファイルを repo の hosts/<台>/ で管理して書き込む
isukit lock [status] / unlock  # サーバーを自分の番として確保する／返す（相手の deploy・bench は止まる）
isukit doctor                  # config / 接続 / manifest / unit / ツール / ログ / ディスク / ベンチモードを診断・修復
isukit os                      # サーバーのスナップショット（uptime / vmstat / iostat / mpstat / free / df）
isukit bench "メモ"            # スコア＋git sha を .isukit/scores.tsv に記録 (manual モード: --score N / --fail)
isukit score                   # 全履歴
isukit show [n]                # 保存した回：台ごとの CPU・プロセス、alp、slow、pprof（logs on の間の bench が保存）
isukit attribute [noise_pct]   # 最後の2回計測の有意差を判定（デフォルト ±10%）
isukit alp                     # エンドポイントを合計レスポンスタイム順
isukit slow                    # クエリを合計時間順
isukit pprof 30                # GoのCPUプロファイル → .isukit/cpu.pprof
isukit pprof on|off             # pprofエンドポイントをfunc main()に自動配線／final strip --applyで除去
isukit deploy                  # rsync＋ビルド → systemdのExecStartパス → 再起動
isukit restart                 # アプリの unit を再起動（app の役割を持つ全台）
isukit ship "<メモ>"            # 新ブランチ作成 → commit → push → draft PR
isukit ship --measure "<メモ>"  # 同上 ＋ commit に Isukit-Measure trailer を足す
isukit measure [--undo] <sha>  # 既存 commit に後から計測ラベルを足す／外す（note。trailer は外せない）
isukit measures                 # HEAD から見えるラベル付き commit の一覧
isukit revert [<sha>]          # git revert で変更を打ち消す
isukit pick <sha>               # git cherry-pick ＋ その commit のスコア note を引き継ぐ
isukit final check             # スコアを削る出力・計測の残りを一覧（何も変えない）
isukit final apply             # 設定で止められるものを止める（etc/ の差分として）＋ 全台の後片付け
isukit final strip [--apply]   # sentinel ブロックと pprof の import/route をパターンで消す
isukit finalize                # 終盤の締め処理一式（ラベル付き commit が残っていると停止／全ホスト再起動）
isukit rules check              # クロック終了後の変更・許可外ホストへの接続などを一覧
isukit rules baseline [sha]     # 触っていないベースライン commit を記録／表示
isukit rules show               # 条文ごとの許可/禁止と isukit の対応表を表示
isukit rules langs              # 有効な言語別 reference 実装 unit を確認（複数有効は事故）
```

**repo に入るもの（チームで共有する）**：`etc/`（`/etc` からリンクされている設定の実体）、`hosts/<台>/`（各台の env ファイル。`env push` で書き込む）、`isukit.hosts`（台ごとの役割）、`isukit.conf`（チーム共通の設定。`FINAL_CHECK_PATH`・`ALP_MATCHES` など。各自の `.isukit/config` が後に読まれて優先される）

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
