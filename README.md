# Cloud HPC Template — Terraform で構築する AWS ParallelCluster

`terraform apply` 1 コマンドで、Slurm スケジューラを備えた HPC クラスタ（AWS ParallelCluster）を
ネットワークから共有ストレージまで丸ごと構築するテンプレートです。
動作確認用に LAMMPS（分子動力学シミュレーション）のビルド／実行スクリプトを同梱しています。

- インフラ（VPC・サブネット・NAT・EFS・S3・SSH 鍵）を Terraform で作成
- 続けて ParallelCluster 本体を `pcluster create-cluster` で作成（Terraform から自動実行）
- CPU キューと GPU キューの 2 本立て、どちらもゼロ台までオートスケール
- 後片付けは `terraform destroy` 1 コマンド

---

## 目次

1. [クラスタ構成](#クラスタ構成)
2. [前提条件](#前提条件)
3. [デプロイ手順](#デプロイ手順)
4. [デプロイ後の動作確認](#デプロイ後の動作確認)
5. [LAMMPS の利用](#lammps-の利用)
6. [クラスタの運用](#クラスタの運用)
7. [削除（クリーンアップ）](#削除クリーンアップ)
8. [コストの目安](#コストの目安)
9. [カスタマイズ](#カスタマイズ)
10. [トラブルシューティング](#トラブルシューティング)
11. [既知の注意点](#既知の注意点)
12. [ディレクトリ構成](#ディレクトリ構成)

---

## クラスタ構成

### 全体アーキテクチャ

```
                                   Internet
                                       │
┌──────────────────────────────────────┼───────────────────────────────────┐
│ VPC 10.0.0.0/16 (DNS hostnames 有効) │                                   │
│                                Internet Gateway                          │
│                                      │                                   │
│  ┌───────────────────────────────────┼────────┐  ┌─────────────────────┐ │
│  │ Public Subnet 10.0.0.0/24         │        │  │ Private Subnet      │ │
│  │ (AZ: ap-northeast-1a)             │        │  │ 10.0.1.0/24         │ │
│  │                                   │        │  │ (同一 AZ)           │ │
│  │  ┌─────────────────┐         ┌────┴─────┐  │  │                     │ │
│  │  │ HeadNode        │         │ NAT      │  │  │ ┌─────────────────┐ │ │
│  │  │ t3.medium       │         │ Gateway  │◄─┼──┼─┤ cpu キュー      │ │ │
│  │  │ Ubuntu 22.04    │         │ (+EIP)   │  │  │ │ t3.medium × 0〜2│ │ │
│  │  │ Elastic IP 付与 │         └──────────┘  │  │ └─────────────────┘ │ │
│  │  │ 常時起動        │                       │  │                     │ │
│  │  │ Slurm ctld      │                       │  │ ┌─────────────────┐ │ │
│  │  └────────┬────────┘                       │  │ │ gpu キュー      │ │ │
│  │           │                                │  │ │ g4dn.xlarge     │ │ │
│  └───────────┼────────────────────────────────┘  │ │ × 0〜2 (T4 GPU) │ │ │
│              │                                   │ └────────┬────────┘ │ │
│              │                                   └──────────┼──────────┘ │
│              │                                              │            │
│              └──────────────┬───────────────────────────────┘            │
│                             │                                            │
│                   ┌─────────┴──────────┐   ┌────────────────────────┐    │
│                   │ EFS  /shared       │   │ S3 Gateway VPC Endpoint│    │
│                   │ 暗号化・全ノード共有│   │ (NAT 経由の課金を回避) │    │
│                   └────────────────────┘   └────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

- **HeadNode はパブリックサブネット**に置かれ、Elastic IP 経由で SSH 接続します。
- **計算ノードはプライベートサブネット**に置かれ、外向き通信は NAT Gateway を通ります。
- **EFS のマウントターゲットはプライベートサブネットに 1 つだけ**作成します。EFS のマウントターゲットは
  AZ 単位で機能し、セキュリティグループが VPC 全体（`10.0.0.0/16`）からの NFS を許可しているため、
  同一 AZ のパブリックサブネットにいる HeadNode からも同じ `/shared` をマウントできます。
  **この理由から、パブリック／プライベート両サブネットは必ず同じ AZ に置いてください。**
- **S3 Gateway VPC Endpoint** を両方のルートテーブルに紐付けているため、
  ノード初期化スクリプトの S3 取得が NAT Gateway のデータ処理料金を消費しません。

### 作成される AWS リソース

| 分類 | リソース | 設定内容 |
|------|----------|----------|
| ネットワーク | VPC | `10.0.0.0/16`、DNS hostnames / DNS support 有効（ParallelCluster の必須要件） |
| | パブリックサブネット | `10.0.0.0/24`（HeadNode 用） |
| | プライベートサブネット | `10.0.1.0/24`（計算ノード用） |
| | Internet Gateway | パブリックサブネットの外部接続 |
| | NAT Gateway + EIP | プライベートサブネットからの外向き通信 |
| | ルートテーブル ×2 | public → IGW / private → NAT |
| | S3 Gateway VPC Endpoint | 両ルートテーブルに紐付け |
| ストレージ | EFS | 暗号化あり、`generalPurpose` / `bursting`、30 日で IA へ移行、全ノードの `/shared` にマウント |
| | EFS 用セキュリティグループ | VPC CIDR からの TCP 2049 (NFS) を許可 |
| | S3 バケット | `parallelcluster-<ランダム16桁>-v1-do-not-delete`、バージョニング有効、パブリックアクセス全ブロック |
| | S3 オブジェクト | `scripts/install_software.sh`（ノード初期化スクリプト） |
| 認証 | SSH キーペア | ED25519 を Terraform が生成し、秘密鍵をリポジトリ直下に `pcluster-key-ed25519.pem`（パーミッション 0400）として保存 |
| クラスタ | ParallelCluster | 生成した `terraform/generated-config.yaml` を使って `pcluster create-cluster` を実行 |

### クラスタのノード構成

| 役割 | インスタンス | 台数 | 配置 | 備考 |
|------|--------------|------|------|------|
| HeadNode | `t3.medium` (2 vCPU / 4 GiB) | 1（常時起動） | パブリックサブネット | Elastic IP、Slurm コントローラ、ジョブ投入用 |
| `cpu` キュー | `t3.medium` (2 vCPU / 4 GiB) | 0〜2（オートスケール） | プライベートサブネット | 計算リソース名 `t3medium` |
| `gpu` キュー | `g4dn.xlarge` (4 vCPU / 16 GiB / NVIDIA T4 16GB) | 0〜2（オートスケール） | プライベートサブネット | 計算リソース名 `g4dnxlarge` |

- スケジューラは **Slurm**。キュー名がそのまま Slurm のパーティション名（`--partition=cpu` / `--partition=gpu`）になります。
- 計算ノードは `MinCount: 0` なので、**ジョブが無いときは 0 台まで縮退**し課金されません。
  ジョブ投入から実際に計算が始まるまで、ノード起動＋初期化で数分かかります。
- 全ノードに `AmazonS3ReadOnlyAccess` を追加付与しています（初期化スクリプトの S3 取得に必要）。

### ソフトウェアスタック

`install_software.sh` が全ノードの `OnNodeConfigured`（ノード設定完了時）で実行され、以下を導入します。

| 項目 | 内容 |
|------|------|
| OS | Ubuntu 22.04 (`ubuntu2204`) |
| スケジューラ | Slurm（ParallelCluster が導入） |
| コンパイラ | GCC 11.x（`build-essential`） |
| MPI | OpenMPI 4.1.x（`libopenmpi-dev` / `openmpi-bin`） |
| ビルドツール | CMake 3.22.x |
| 数値ライブラリ | FFTW3 (`libfftw3-dev`) |
| GPU | CUDA Toolkit 12.3（**GPU ノードのみ**、`lspci` で NVIDIA デバイスを検出して自動判定） |
| Python | python3 + `uv`（`/usr/local/bin/uv` に配置） |
| アプリケーション | LAMMPS（Kokkos: CPU=OpenMP / GPU=CUDA）※ `utils/` のスクリプトで手動ビルド |

> LAMMPS 自体は初期化スクリプトには含まれません。クラスタ作成後に
> [LAMMPS の利用](#lammps-の利用) の手順でビルドします。

---

## 前提条件

### 必要なツール

| ツール | バージョン | 用途 |
|--------|-----------|------|
| Terraform | >= 1.0 | インフラ構築 |
| AWS CLI | v1/v2 | 認証情報の設定 |
| AWS ParallelCluster CLI (`pcluster`) | >= 3.14 | クラスタ作成（**Terraform から呼ばれるので PATH に必須**） |
| Python | >= 3.9 | `pcluster` の実行環境 |

```bash
# Terraform（macOS）
brew install terraform

# Terraform（Linux）
wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
unzip terraform_1.6.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# pcluster / awscli（本リポジトリの pyproject.toml で管理）
uv sync
source .venv/bin/activate

# もしくは pip で
pip install "aws-parallelcluster>=3.14.1" awscli
```

### AWS 認証情報

```bash
aws configure   # Access Key / Secret Key / デフォルトリージョンを設定
```

### 事前チェック

```bash
terraform version
aws sts get-caller-identity
pcluster version          # ← PATH に無いと terraform apply が失敗します
```

### 必要な IAM 権限

デプロイを実行する IAM ユーザー／ロールには、少なくとも以下を操作する権限が必要です。

- EC2（VPC・サブネット・IGW・NAT・EIP・ルートテーブル・VPC エンドポイント・セキュリティグループ・キーペア・インスタンス）
- EFS、S3、CloudFormation（ParallelCluster は CloudFormation スタックとして構築されます）
- IAM（ParallelCluster がノード用のロール／インスタンスプロファイルを作成します）
- CloudWatch Logs、Auto Scaling、Lambda、DynamoDB（ParallelCluster が内部的に使用）

検証環境では `AdministratorAccess` が手軽ですが、本番では
[ParallelCluster の公式 IAM ポリシー](https://docs.aws.amazon.com/parallelcluster/latest/ug/iam-roles-in-parallelcluster-v3.html)
を参照して絞り込んでください。

### サービスクォータ

デフォルト設定では以下を消費します。リージョンのクォータ不足で作成に失敗することがあります。

- Elastic IP：**2 個**（NAT Gateway 用 + HeadNode 用）
- `g4dn` 系のオンデマンド vCPU：GPU ノード 2 台で **8 vCPU**（新規アカウントは 0 のことがあり、その場合は緩和申請が必要）

---

## デプロイ手順

所要時間はおよそ **15 分**（インフラ 3〜5 分 + クラスタ 10〜12 分）です。

### Step 1. Terraform の初期化

```bash
cd terraform
terraform init
```

`aws` / `tls` / `local` / `random` / `null` プロバイダがダウンロードされます。

### Step 2. 変数のカスタマイズ（任意）

デフォルトのままでも動作します。変更したい場合のみ：

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `aws_region` | `ap-northeast-1` | デプロイ先リージョン |
| `availability_zone` | `ap-northeast-1a` | サブネットを置く AZ（**リージョンを変えたら必ず合わせて変更**） |
| `project_name` | `pcluster` | 各リソース名のプレフィックス |
| `cluster_name` | `my-cluster` | ParallelCluster 名 |
| `vpc_cidr` | `10.0.0.0/16` | VPC の CIDR |
| `public_subnet_cidr` | `10.0.0.0/24` | HeadNode 用サブネット |
| `private_subnet_cidr` | `10.0.1.0/24` | 計算ノード用サブネット |
| `key_name` | `pcluster-key-ed25519` | 生成する EC2 キーペア名 |
| `tags` | Project/Environment/ManagedBy | 全リソース共通タグ |

### Step 3. 内容確認とデプロイ

```bash
terraform plan     # 作成される内容を確認
terraform apply    # 'yes' を入力
```

`terraform apply` が行うことは次のとおりです。

1. VPC・サブネット・NAT・EFS・S3・SSH 鍵を作成（3〜5 分）
2. `install_software.sh` を S3 にアップロード
3. `config.yaml.tpl` に実際のサブネット ID / EFS ID / S3 パスを埋め込み、
   `terraform/generated-config.yaml` を生成
4. `pcluster create-cluster` を実行してクラスタ作成を **開始**

> **重要**: `pcluster create-cluster` は完了を待たずに戻ります。
> つまり `terraform apply` が成功した時点ではクラスタはまだ構築中です。Step 4 で完了を確認してください。

### Step 4. クラスタ作成完了の確認

```bash
# 状態を確認
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1

# 30 秒ごとに監視
watch -n 30 "pcluster describe-cluster \
  --cluster-name my-cluster \
  --region ap-northeast-1 \
  --query 'clusterStatus' --output text"
```

`CREATE_IN_PROGRESS` → **`CREATE_COMPLETE`** になれば完了です（10〜12 分程度）。

### Step 5. HeadNode へ接続

```bash
pcluster ssh --cluster-name my-cluster --region ap-northeast-1
```

このコマンドが HeadNode の IP 取得・鍵の指定・`ubuntu` ユーザーでの接続をすべて行います。

手動で接続する場合：

```bash
# HeadNode の Public IP を取得
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1 \
  --query 'headNode.publicIpAddress' --output text

# 秘密鍵はリポジトリ直下に生成されています
chmod 400 ../pcluster-key-ed25519.pem
ssh -i ../pcluster-key-ed25519.pem ubuntu@<HeadNode-IP>
```

### 出力値の確認

```bash
terraform output                     # 全出力
terraform output ssh_command         # 接続コマンド
terraform output s3_bucket_name      # 作成された S3 バケット名
terraform output infrastructure_summary
```

---

## デプロイ後の動作確認

HeadNode にログインして、Slurm が 2 つのパーティションを認識しているか確認します。

```bash
sinfo
# PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
# cpu*         up   infinite      2   idle~ cpu-dy-t3medium-[1-2]
# gpu          up   infinite      2   idle~ gpu-dy-g4dnxlarge-[1-2]
#                                        ↑ "idle~" = 停止中（オートスケールで必要時に起動）

df -h /shared          # EFS がマウントされていることを確認
mpirun --version       # OpenMPI
uv --version           # uv

# 簡単なジョブで計算ノードの起動を確認（初回は起動に数分かかります）
srun --partition=cpu --nodes=1 --ntasks=1 hostname
```

---

## LAMMPS の利用

`utils/` 以下のスクリプトは HeadNode 上で実行します。ローカルから転送するか、
このリポジトリを HeadNode 上で `git clone` してください。

```bash
# ローカルからコピーする例
scp -i pcluster-key-ed25519.pem -r utils ubuntu@<HeadNode-IP>:~/
```

### 事前準備（`/shared` の権限）

`/shared`（EFS）は初期状態では root 所有です。ビルド前に書き込み権限を用意します。

```bash
sudo chown ubuntu:ubuntu /shared
sudo mkdir -p /shared/lammps_jobs
sudo chown ubuntu:ubuntu /shared/lammps_jobs

# MPI テストスクリプトはホームの入力ファイルを参照します
cp ~/utils/lammps_test_input.lmp ~/lammps_test_input.lmp
```

### CPU 版のビルド（HeadNode 上で直接実行）

```bash
./utils/build_lammps_cpu.sh
```

- LAMMPS を `/shared/lammps` に clone し、`build-cpu` でビルドして `/shared/lammps/cpu` にインストール
- 有効化パッケージ：`KOKKOS`(OpenMP)、`MOLECULE`、`KSPACE`、`RIGID`、`MANYBODY`、MPI、OpenMP
- ログ：`/shared/lammps_cpu_build.log`
- **HeadNode は 2 vCPU なのでビルドに 30 分以上かかることがあります。**
  `tmux` / `screen` の中で実行するか、`sbatch` でジョブとして投げることを推奨します。

```bash
# 動作確認
source /shared/lammps/cpu-env.sh
lmp -h
```

### GPU 版のビルド（GPU ノードでジョブとして実行）

CUDA と GPU が必要なため、Slurm ジョブとして GPU キューに投入します。

```bash
sbatch utils/build_lammps_gpu.sh

squeue                                  # 進捗確認
tail -f /shared/lammps_gpu_build_*.out  # ログ確認
```

- `/shared/lammps/gpu` にインストールされ、環境設定は `/shared/lammps/gpu-env.sh`
- Kokkos の GPU アーキテクチャは `Kokkos_ARCH_TURING75`（g4dn の NVIDIA T4 = Turing SM75）を指定しています。
  他の GPU インスタンスに変更する場合は、この値も合わせて変更してください
  （例：`p3` の V100 → `Kokkos_ARCH_VOLTA70`、`g5` の A10G → `Kokkos_ARCH_AMPERE86`）。

### MPI 並列テストの実行

```bash
sbatch utils/run_lammps_mpi_test.sh

squeue                # ジョブ状態
watch -n 5 sinfo      # ノードの起動状況
cat lammps_test_*.out # 結果
```

- 2 ノード × 合計 4 MPI プロセスで Lennard-Jones 流体（32,000 原子 / 5,000 ステップ）を計算します
- 作業ディレクトリ：`/shared/lammps_jobs/<JOB_ID>`
- ジョブ内で `/home/ubuntu/lammps_test_input.lmp` を参照するため、
  [事前準備](#事前準備shared-の権限) のコピーを忘れないでください

### スケーリングテスト

```bash
./utils/run_lammps_scaling_test.sh
```

以下の 4 構成を順にジョブ投入し、`Loop time` を比較できるようにします。

| ノード数 | MPI プロセス数 |
|---------|---------------|
| 1 | 1 |
| 1 | 2 |
| 2 | 2 |
| 2 | 4 |

```bash
cat /shared/lammps_scaling_results_*/summary.txt
```

> `cpu` キューは最大 2 ノードなので、2 ノードを使う構成は同時には走りません（順番待ちになります）。

---

## クラスタの運用

### Slurm の基本コマンド

| コマンド | 説明 |
|----------|------|
| `sinfo` | パーティションとノードの状態 |
| `squeue` | ジョブキューの確認 |
| `sbatch <script>` | バッチジョブの投入 |
| `srun <cmd>` | 対話的なジョブ実行 |
| `scancel <job_id>` | ジョブのキャンセル |
| `scontrol show job <job_id>` | ジョブの詳細 |
| `scontrol show node <node>` | ノードの詳細 |

### ログの確認

```bash
# ログストリーム一覧
pcluster list-cluster-log-streams --cluster-name my-cluster --region ap-northeast-1

# 個別のログを取得
pcluster get-cluster-log-events --cluster-name my-cluster \
  --log-stream-name <stream-name> --region ap-northeast-1
```

ノード上の主なログ：

- `/var/log/parallelcluster/install_software.log` — 本テンプレートの初期化スクリプトの出力
- `/var/log/parallelcluster/clustermgtd` — オートスケール（HeadNode）
- `/var/log/slurmctld.log` — Slurm コントローラ

### 構成変更の反映

`terraform/config.yaml.tpl`（インスタンスタイプ、最大ノード数など）を編集して `terraform apply` すると、
`null_resource` のトリガー（config の内容）が変化するため **クラスタは削除・再作成** されます。
`/shared`（EFS）のデータは Terraform 管理下の別リソースなので保持されます。

キューの追加やノード数の変更だけであれば、クラスタを止めて `pcluster update-cluster` を使う方が高速です。

---

## 削除（クリーンアップ）

```bash
cd terraform
terraform destroy   # 'yes' を入力
```

処理の流れ：

1. `pcluster delete-cluster` を実行
2. 削除完了を 10 秒間隔で最大 60 回（10 分）ポーリング
3. VPC・NAT・EFS・S3・キーペアなどインフラを削除

所要時間はおよそ **15〜20 分**です。

> ⚠️ **`/shared`（EFS）のデータは完全に削除されます。** 必要なファイルは事前に退避してください。
>
> ⚠️ NAT Gateway と Elastic IP は起動している限り課金されます。使わない間は destroy を推奨します。

クラスタだけ消してインフラを残す場合：

```bash
pcluster delete-cluster --cluster-name my-cluster --region ap-northeast-1
```

削除に失敗して S3 バケットが残る場合は、バージョニング有効のため中身を空にしてから削除します。

```bash
aws s3 rm s3://<bucket-name> --recursive
aws s3api delete-bucket --bucket <bucket-name> --region ap-northeast-1
```

---

## コストの目安

ap-northeast-1 の概算です（実際の料金は必ず [AWS 料金ページ](https://aws.amazon.com/jp/pricing/) で確認してください）。

**常時発生（クラスタを起動したまま）**

| 項目 | 単価 | 月額概算 |
|------|------|---------|
| NAT Gateway | 約 $0.045/時 + データ処理料 | 約 $33 |
| HeadNode (`t3.medium`) | 約 $0.0416/時 | 約 $30 |
| Elastic IP ×2 | 使用中は概ね無料枠／低額 | 数ドル |
| **小計** | | **約 $65〜70/月** |

**ジョブ実行時のみ**

| 項目 | 単価 |
|------|------|
| CPU ノード (`t3.medium`) | 約 $0.0416/時 × 台数 |
| GPU ノード (`g4dn.xlarge`) | 約 $0.526/時 × 台数 |

**ストレージ**

| 項目 | 単価 |
|------|------|
| EFS（標準） | 約 $0.30/GB-月（30 日後に IA へ自動移行して低減） |
| S3 | 約 $0.025/GB-月（スクリプトのみなので実質ゼロ） |

**コストを抑えるコツ**

- 計算ノードは `MinCount: 0` なので、放置しても計算ノード分は課金されません
- 使わない期間は `terraform destroy` で NAT Gateway ごと削除するのが最も効果的
- S3 Gateway VPC Endpoint により、S3 アクセス分の NAT データ処理料金を回避済み

---

## カスタマイズ

### リージョンを変更する

`availability_zone` も必ず併せて変更してください。

```hcl
# terraform/terraform.tfvars
aws_region        = "us-east-1"
availability_zone = "us-east-1a"
```

### インスタンスタイプ／ノード数を変更する

`terraform/config.yaml.tpl` を編集します。

```yaml
    - Name: cpu
      ComputeResources:
        - Name: c6i8xlarge         # 計算リソース名（英数字のみ）
          InstanceType: c6i.8xlarge
          MinCount: 0
          MaxCount: 8              # 最大ノード数
```

- `MaxCount` を増やす場合は、リージョンの vCPU クォータを確認してください
- 複数ノードで MPI を多用するなら、`Efa: Enabled: true`（EFA 対応インスタンスのみ）の検討を推奨します
- GPU インスタンスを変えた場合は `utils/build_lammps_gpu.sh` の `Kokkos_ARCH_*` も合わせて変更してください

### 初期化ソフトウェアを追加する

`install_software.sh` に追記して `terraform apply` を実行すると、
S3 のオブジェクトが更新され（`etag` が変わるため）クラスタが再作成されて反映されます。

### 手動デプロイ（Terraform を使わない場合）

リポジトリ直下の `config.yaml` は、既存のインフラに対して手動で
`pcluster create-cluster` を実行するための参考テンプレートです。
`<...>` のプレースホルダを実際の ID に置き換えて使用してください（Terraform 経由では使用されません）。

---

## トラブルシューティング

### `terraform apply` が `pcluster: command not found` で失敗する

`pcluster` CLI は Terraform を実行するローカル環境の PATH に必要です。

```bash
uv sync && source .venv/bin/activate   # もしくは pip install aws-parallelcluster
pcluster version
```

### クラスタが `CREATE_FAILED` になる

```bash
pcluster describe-cluster --cluster-name my-cluster --region ap-northeast-1
pcluster list-cluster-log-streams --cluster-name my-cluster --region ap-northeast-1
pcluster get-cluster-log-events --cluster-name my-cluster \
  --log-stream-name <stream> --region ap-northeast-1
```

よくある原因：

- VPC の DNS hostnames が無効（本テンプレートでは有効化済み）
- IAM 権限不足（特に CloudFormation / IAM ロール作成）
- vCPU クォータ不足、または指定 AZ で当該インスタンスタイプが提供されていない
- EIP のクォータ不足
- `install_software.sh` の失敗（`/var/log/parallelcluster/install_software.log` を確認）

失敗したクラスタは残るため、再実行前に削除してください。

```bash
pcluster delete-cluster --cluster-name my-cluster --region ap-northeast-1
```

### SSH で接続できない

```bash
# まずは pcluster ssh を試す（鍵と IP を自動で解決）
pcluster ssh --cluster-name my-cluster --region ap-northeast-1

# 手動接続時は鍵のパーミッションを確認
chmod 400 pcluster-key-ed25519.pem
```

クラスタが `CREATE_COMPLETE` になっているか、HeadNode に Public IP が付いているかも確認してください。

### 計算ノードが起動しない／すぐ落ちる

```bash
sinfo -R                                    # ノードが down した理由
sudo tail -f /var/log/parallelcluster/clustermgtd
```

インスタンスタイプの在庫不足やクォータ不足が典型的な原因です。

### `/shared` に書き込めない

```bash
sudo chown ubuntu:ubuntu /shared
sudo chown -R ubuntu:ubuntu /shared/lammps /shared/lammps_jobs
```

### LAMMPS のビルドが失敗する

```bash
cat /shared/lammps_cpu_build.log
cat /shared/lammps_gpu_build.log

gcc --version     # 11.x
cmake --version   # 3.22.x
mpirun --version  # 4.1.x
nvcc --version    # GPU ノードで 12.3
nvidia-smi        # GPU の認識確認
```

HeadNode（2 vCPU / 4 GiB）ではメモリ不足でコンパイラが強制終了することがあります。
その場合は `make -j1` に落とすか、より大きなインスタンスでビルドしてください。

### Terraform の state がずれた

```bash
terraform refresh
terraform show
terraform state list
```

クラスタを CLI で手動削除した場合は、Terraform 側の認識と食い違います。

```bash
terraform state rm null_resource.pcluster_create
```

---

## 既知の注意点

- **`terraform apply` はクラスタ作成の完了を待ちません。** `pcluster create-cluster` に `--wait` を
  付けていないため、apply 成功 ≠ クラスタ利用可能です。`describe-cluster` で確認してください。
- **SSH 秘密鍵がリポジトリ直下に平文で生成されます**（`pcluster-key-ed25519.pem`）。
  ルートの `.gitignore` で `*.pem` を除外していますが、コミットしないよう注意してください。
  Terraform state にも秘密鍵が平文で含まれるため、`terraform.tfstate` の取り扱いにも注意が必要です。
- **HeadNode の SSH はどこからでも到達可能**です（ParallelCluster のデフォルト）。
  運用環境では `HeadNode.Ssh.AllowedIps` で接続元 IP を制限してください。
- **パブリック／プライベートサブネットは同じ AZ である必要があります**（EFS マウントターゲットが
  プライベートサブネットに 1 つだけのため）。
- `terraform destroy` の削除待ちは最大 10 分でタイムアウトします。タイムアウト後もインフラ削除に進むため、
  VPC 削除が依存関係エラーで失敗することがあります。その場合はクラスタ削除完了後に再度 `terraform destroy` を実行してください。
- 本テンプレートは検証・学習用の構成です。本番利用では最小権限 IAM、リモート Terraform backend、
  EFS のバックアップ、CloudWatch アラームなどの追加を検討してください。

---

## ディレクトリ構成

```
cloud-hpc-template/
├── README.md                      # 本ドキュメント
├── config.yaml                    # 手動デプロイ用の参考 pcluster 設定（Terraform では未使用）
├── install_software.sh            # 全ノードの初期化スクリプト（S3 経由で OnNodeConfigured 実行）
├── pyproject.toml / uv.lock       # pcluster / awscli の依存管理
├── .gitignore
│
├── terraform/                     # Infrastructure as Code
│   ├── main.tf                    # プロバイダ定義（aws / tls / local / random / null）
│   ├── variables.tf               # 入力変数
│   ├── vpc.tf                     # VPC・サブネット・IGW・NAT・ルート・S3 エンドポイント
│   ├── efs.tf                     # EFS・セキュリティグループ・マウントターゲット
│   ├── s3.tf                      # S3 バケットと初期化スクリプトのアップロード
│   ├── key_pair.tf                # ED25519 鍵の生成と保存
│   ├── pcluster.tf                # config 生成 + pcluster create/delete の実行
│   ├── outputs.tf                 # 出力値
│   ├── config.yaml.tpl            # ParallelCluster 設定テンプレート
│   ├── terraform.tfvars.example   # 変数設定の例
│   └── .gitignore
│
└── utils/                         # HeadNode 上で使う実行スクリプト
    ├── build_lammps_cpu.sh        # LAMMPS CPU 版ビルド（Kokkos OpenMP）
    ├── build_lammps_gpu.sh        # LAMMPS GPU 版ビルド（Kokkos CUDA / Slurm ジョブ）
    ├── lammps_test_input.lmp      # LJ 流体ベンチマーク入力
    ├── run_lammps_mpi_test.sh     # 2 ノード 4 プロセスの MPI テストジョブ
    └── run_lammps_scaling_test.sh # スケーリングテスト一式
```

---

## 参考リンク

- [AWS ParallelCluster ドキュメント](https://docs.aws.amazon.com/parallelcluster/)
- [ParallelCluster 設定ファイルリファレンス](https://docs.aws.amazon.com/parallelcluster/latest/ug/cluster-configuration-file-v3.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [LAMMPS ドキュメント](https://docs.lammps.org/)
- [Kokkos アーキテクチャ一覧](https://kokkos.org/kokkos-core-wiki/keywords.html)
- [Slurm ドキュメント](https://slurm.schedmd.com/documentation.html)

---

## ライセンス

学習・研究目的で提供されるテンプレートです。無保証（as-is）で提供されます。

本テンプレートは [hodakamori/ml-tutorial](https://github.com/hodakamori/ml-tutorial) の
`055_parallel_cluster` を移植したものです。
