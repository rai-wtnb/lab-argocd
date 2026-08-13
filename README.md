# lab-argocd

ArgoCD をローカルでまるごと体験するハンズオンラボ。kind クラスタ 3 つで
**hub-spoke(マルチクラスタ)構成 + git generator による Application 量産**を再現する。

- 1 つの ArgoCD(hub)が複数の宛先クラスタ(spoke)へデプロイする構成
- `app.argocd.yaml`(以下「マーカー」と呼ぶ)を Git リポジトリに置くだけで
  Application が自動生成される opt-in 方式(ApplicationSet の git files generator)
- selfHeal / prune / AppProject 区画 / External Secrets Operator まで一通り試せる

## 3 Clusters 構成

```
1. kind-demo-hub(management cluster)
  ├── ArgoCD(非HA)
  ├── Gitea(GitOps のソースになる Git サーバ。http://localhost:3000)
  ├── Vault(ESO 用の外部シークレットストア)
  ├── ApplicationSet(app/*/overlay/{dev,stg}/*/app.argocd.yaml を監視)
  ├── AppProject demo(チーム区画)/ platform(基盤区画)
  ├── 手書き Application ×2(gitea / vault を hub 自身 = in-cluster へ同期)
  └── cluster Secret ×2(spoke-dev / spoke-stg の登録)
2. kind-demo-dev(spoke。宛先クラスタ)── demo-app ns + 最小権限 RBAC
3. kind-demo-stg(spoke。宛先クラスタ)── 同上
```

Gitea と Vault は単なる土台ではなく、それ自体が ArgoCD の**手書き Application** の教材になっている
(ApplicationSet が量産する demo 側との対比。Gitea は「Git サーバ自身を GitOps 管理する」
鶏と卵になるため、初回だけスクリプトが直接 apply して以後 ArgoCD が adopt する)。

## 登場するコンポーネント

| コンポーネント | 何者か | このラボでの役割 |
|---|---|---|
| **ArgoCD** | GitOps の CD ツール。Git の宣言と実クラスタの状態を比較し続け、差分を同期する | 主役。hub に置き、2 つの spoke へデプロイする |
| **Gitea** | 軽量なセルフホスト Git サービス(GitHub 相当の UI/API を単一バイナリで提供) | GitOps のソースリポジトリ。API でリポジトリ作成をスクリプト化でき、public リポジトリは匿名 clone できるので ArgoCD 側の認証設定が不要になる |
| **Vault** | HashiCorp のシークレット管理ツール(値の保管・動的発行・監査)。dev モードはインメモリ+固定 root token の使い捨て構成 | ESO ハンズオンの外部シークレットストア。ESO の公式プロバイダの中でローカル完結できる最軽量の選択 |
| **ESO** (External Secrets Operator) | 外部ストアの値を K8s Secret に同期し続けるオペレータ | 「Git には宣言だけ、値は外部ストア」パターンの実演 |
| **podinfo** | Kubernetes / GitOps のデモ用に作られた小さな Go 製 Web アプリ(UI・ヘルスチェック・メトリクスを備える) | デプロイ対象のデモアプリ `demo-app` の実体。`PODINFO_UI_MESSAGE` で環境差(dev / stg)を画面上の文言として可視化し、readyz / healthz が ArgoCD の Health 判定の材料になる |
| **kind** | docker コンテナをノードに見立てて K8s クラスタを作るツール | クラスタ 3 つ(hub/spoke×2)の実体 |
| **colima** | macOS 上に Linux VM + docker ランタイムを提供(Docker Desktop 代替) | kind が動く土台 |

## ディレクトリ構成

```
├── Makefile        # 入口 (up / argocd-info / argocd-render / status / marker-* / eso-up / vault-get / rotate / down)
├── docs/           # ドキュメント (事前知識 / ArgoCD / CRD / ESO / ハンズオンシナリオ)
├── kind/           # 各クラスタの kind 設定 (ArgoCD / Gitea / demo-app の NodePort をホストへ公開)
├── hub/            # hub クラスタに置くもの
│   ├── argocd/     #   ArgoCD 本体 (kustomize + helmCharts。values.yaml が設定)
│   ├── appproject.yaml      # チーム区画 demo (同期先の許可リスト)
│   ├── platform.yaml        # 基盤区画: AppProject platform + 手書き Application (gitea / vault)
│   ├── clusters.yaml        # クラスタ登録 Secret のテンプレート (動的な値と秘密は 04-spokes.sh が埋める)
│   └── applicationset.yaml  # マーカーを読んで Application を量産する仕組み
├── spoke/          # 宛先クラスタ側に置くもの
│   ├── rbac.yaml        #   最小権限 RBAC + 接続用 ServiceAccount
│   └── eso-values.yaml  #   ESO の values (全て既定のまま。把握すべき既定値の解説をコメントで抜粋)
├── seed-repo/      # Gitea に初期投入するリポジトリの中身
│                   #   (app/ = デモアプリの base/overlay、platform/ = Gitea / Vault 自身のマニフェスト)
├── scripts/        # セットアップの実体 (下表。00〜06 を make up が順に呼ぶ)
└── .work/          # 実行時の生成物 (リポジトリの clone、token 入り kubeconfig。git 管理外)
```

### scripts/ の中身

すべて冪等(途中で失敗しても再実行すれば続きから通る)。

| スクリプト | やること |
|---|---|
| `00-prereqs.sh` | 必要 CLI(docker / kind / kubectl / git / curl / jq)の存在と docker デーモンへの疎通を確認。足りなければ brew コマンド付きで失敗する |
| `01-clusters.sh` | kind クラスタ 3 つ(demo-hub / demo-dev / demo-stg)を `kind/*.yaml` の設定で作成(hub は ArgoCD と Gitea、spoke は demo-app の NodePort をホストへ公開)。作成済みならスキップ。最後に podinfo イメージをホスト側 docker で pull して spoke へ搬入する(Pod 起動時の pull がクラスタ内 egress の不調で ImagePullBackOff になるのを防ぐ) |
| `02-argocd.sh` | `hub/argocd/` を `kubectl kustomize --enable-helm` でレンダリングし、server-side apply で hub へ適用(CRD が巨大で client-side apply の上限を超えるため)。全コンポーネントの rollout 完了を待つ |
| `03-gitea.sh` | Gitea を hub へ配置(`seed-repo/platform/gitea/` を直接 apply = 鶏と卵のブートストラップ)→ healthz 待ち → 管理ユーザー `demo` 作成 → public リポジトリ `manifests` を API で作成 → `seed-repo/` の内容を main ブランチへ push |
| `04-spokes.sh` | 各 spoke へ `spoke/rbac.yaml` を適用 → ServiceAccount の token と kind の内部エンドポイント+CA を取得 → `hub/clusters.yaml`(テンプレート)に埋めて cluster Secret(`spoke-dev` / `spoke-stg`)を hub へ登録 |
| `05-bootstrap.sh` | AppProject `demo`/`platform`・手書き Application(`gitea`/`vault`)・ApplicationSet `managed-apps` を hub へ適用。gitea は既存リソースを adopt、vault はここから GitOps で新規作成される。demo 側はマーカーが無いので Application 0 件 |
| `06-eso.sh` | Vault の起動(Application `vault` の sync)を待って初期値を投入 → ESO を spoke-dev へ helm で導入(values: `spoke/eso-values.yaml`)→ SecretStore の認証用 `vault-token` Secret を作成(単体再実行は `make eso-up`) |
| `marker.sh` | マーカー(`app.argocd.yaml`)の追加/削除。Gitea のリポジトリを `.work/manifests` に clone/pull → マーカーを生成 or 削除 → commit & push。`make marker-dev` 等はこれのラッパー(`add\|remove × dev\|stg × アプリ名`) |

## クラスタ別リソース一覧

`make up` と各ステップで、どのクラスタに何ができるかの全量。

**kind-demo-hub(management cluster)**

| namespace | リソース | できるタイミング |
|---|---|---|
| argocd | ArgoCD 一式(Deployment: server / repo-server / applicationset-controller / redis、StatefulSet: application-controller)+ CRD 3 種 | make up |
| argocd | AppProject `demo` / `platform`、ApplicationSet `managed-apps` | make up |
| argocd | 手書き Application `gitea` / `vault`(宛先は in-cluster = hub 自身) | make up |
| argocd | cluster Secret `cluster-spoke-dev` / `cluster-spoke-stg`(spoke の登録) | make up |
| argocd | Application `demo-app` / `demo-app-stg` / `demo-secrets`(**Application リソース自体は hub に居る**。実体は spoke に作られる) | 各マーカー push 後に自動生成 |
| gitea | Gitea(Deployment + Service NodePort 30300 + PVC)。初回はスクリプトが apply し、以後 Application `gitea` が管理(adopt) | make up |
| vault | Vault dev モード(Deployment + Service NodePort 30201)。Application `vault` の sync が作る | make up |

**kind-demo-dev(spoke)**

| namespace | リソース | できるタイミング |
|---|---|---|
| kube-system | ServiceAccount `argocd-manager` + 長期 token Secret | make up |
| (cluster) | ClusterRole `argocd-manager` / `argocd-app-writer` + Binding | make up |
| demo-app | RoleBinding(app-writer を ns 限定付与) | make up |
| demo-app | Deployment `demo-app`(replicas 2)+ Service | make marker-dev 後 |
| external-secrets | ESO 一式(controller / webhook / cert-controller) | make up |
| demo-app | `vault-token` Secret(SecretStore の認証用) | make up |
| demo-app | SecretStore `vault` + ExternalSecret `demo-app` → 生成物 Secret `demo-app-secret` | make marker-secrets 後 |

**kind-demo-stg(spoke)**

| namespace | リソース | できるタイミング |
|---|---|---|
| kube-system / (cluster) / demo-app | dev と同じ RBAC セット | make up |
| demo-app | Deployment `demo-app`(replicas 1)+ Service | make marker-stg 後 |

## エンドポイント / UI 一覧

| 何 | URL | 認証 | 備考 |
|---|---|---|---|
| ArgoCD UI | https://localhost:8080 | admin / `make argocd-info` が表示するパスワード | 常時(kind の extraPortMappings 経由)。自己署名証明書の警告は無視してよい |
| Gitea UI | http://localhost:3000 | demo / demo12345 | 常時(kind の extraPortMappings 経由)。マーカーのコミットが積まれる様子を見られる |
| demo-app(podinfo の UI) | dev: http://localhost:9898 / stg: http://localhost:9899 | なし | 常時(kind の extraPortMappings 経由)。マーカー同期後に画面へ "hello from DEV" / "hello from STG" が出る |
| Vault | ホスト非公開 | root token `root` | 値の確認は `make vault-get`、更新は `make rotate`(いずれも `kubectl exec` 経由)。クラスタ間からは `demo-hub-control-plane:30201` |

## 事前準備

必要なツール(すべて Homebrew で入る):

| ツール | 用途 |
|---|---|
| colima | ローカル VM + docker ランタイム(Docker Desktop 代替) |
| docker | CLI(デーモンは colima の VM 内で動く) |
| kind | VM 内に Kubernetes クラスタを 3 つ作る |
| kubectl | クラスタ操作 |
| jq | セットアップスクリプト内の JSON 加工 |
| helm | ArgoCD 本体のレンダリング(kustomize --enable-helm)と ESO 導入で使用 |

git / curl / make は macOS 標準のものでよい。

```bash
brew install colima docker kind kubectl jq helm
colima start argocd-lab --cpu 4 --memory 8 --disk 30
```

専用プロファイル `argocd-lab` の VM を作る(普段使いの colima default には触れない)。
起動すると docker context が `colima-argocd-lab` に自動で切り替わる。

## 起動

```bash
make up      # kind×3 作成 → ArgoCD → Gitea+シードrepo → spoke登録 → bootstrap(5〜10分)
make argocd-info   # UI の URL と admin パスワードを表示
```

Gitea: <http://localhost:3000>(demo / demo12345)

## ハンズオン

シナリオは [docs/05-handson.md](docs/05-handson.md) に集約している
(第 1 部: 基本 / 第 2 部: 応用実験 / 第 3 部: 「もし〜するなら」の拡張解説)。

## このラボと本番運用の違い

ラボは自己完結を優先して簡略化している。本番で置き換わる部品:

| 要素 | このラボ | 本番でよくある構成 |
|---|---|---|
| クラスタ登録の認証 | ServiceAccount の bearer token(**本物の秘密。コミット禁止**) | クラウドの IAM 連携(GKE なら Connect Gateway + Workload Identity)にすると cluster Secret から秘密を消せる |
| Git リポジトリ | クラスタ内 Gitea(public repo・認証なし) | GitHub 等 + App/デプロイキーの repo-creds |
| ArgoCD 本体の管理 | Helm チャートを kustomize で展開しスクリプトが apply | 同じ展開方式 + self-management(ArgoCD が自分自身を同期し続ける) |
| マーカー反映の速さ | ポーリング(30秒〜3分) | Git webhook(即時)+ ポーリング(フォールバック) |
| 宛先 RBAC | wildcard の app-writer | デプロイするリソース種別を列挙した最小権限 |
| 外部シークレットストア | Vault dev モード | クラウドのシークレットマネージャ + IAM 認証 |

## 片付け

```bash
make down                 # kind クラスタ 3 つ削除 + .work 削除
colima stop argocd-lab    # VM 停止
colima delete argocd-lab  # VM ごと完全削除する場合
```
