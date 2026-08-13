# ArgoCD の CRD

## そもそも CRD とは

CustomResourceDefinition。Kubernetes API に**独自のリソース型を追加する**仕組み。

- CRD を入れると `kubectl get <新型>` ができるようになる(= API とデータ置き場が増える)
- ただし CRD は「型の定義」でしかなく、**それを読んで動く controller とペアで初めて意味を持つ**
  (この「独自リソース + controller」の組をオペレータパターンと呼ぶ)
- ArgoCD のインストールは「CRD 3 つ + それを reconcile するコントローラ群」の導入、と読める

```bash
kubectl --context kind-demo-hub get crd | grep argoproj
# applications.argoproj.io / applicationsets.argoproj.io / appprojects.argoproj.io
```

## 1. Application — 「何を・どこへ・どう同期するか」の宣言

ArgoCD の中心リソース。1 Application = 1 つのデプロイ単位。

```yaml
spec:
  project: demo                    # 所属する AppProject (認可の区画)
  source:                          # 何を (Git のどこを render するか)
    repoURL: http://gitea.../manifests.git
    targetRevision: HEAD
    path: app/web/overlay/dev/demo-app
  destination:                     # どこへ
    name: spoke-dev                # クラスタ登録名 (または server: URL)
    namespace: demo-app
  syncPolicy:                      # どう同期するか (automated / prune / selfHeal ...)
```

見るべき status は 2 軸: `sync.status`(Synced / OutOfSync = Git と一致しているか)と
`health.status`(Healthy / Progressing / Degraded = リソース自体が元気か)。
「Synced だが Degraded」(Git 通りに apply したがアプリが落ちている)もあり得る — 2 軸は独立。

このラボには Application の作られ方が 2 通りある:

- **ApplicationSet が生成**(demo-app 等): マーカー起点の量産。次々節
- **手で書いて apply**(`hub/platform.yaml` の `gitea` / `vault`): 少数の基盤はこれで十分。
  宛先は `name: in-cluster` — ArgoCD が自分の居るクラスタを指す組み込みの登録名
  (`https://kubernetes.default.svc`)で、hub が自分自身へ配る形になる。
  Gitea は「Git サーバ自身のマニフェストをその Git で管理する」鶏と卵なので、
  初回だけスクリプトが直接 apply し、Application は既存リソースを **adopt** する
  (同名のリソースが live に居れば ArgoCD はそのまま管理を引き継ぐ)

## 2. AppProject — Application の認可境界

「このプロジェクトに属する Application は、どのリポジトリをソースにでき、
どのクラスタ×namespace へ同期でき、どのクラスタスコープリソースを作れるか」の許可リスト。

```yaml
spec:
  sourceRepos: [http://gitea.../manifests.git]   # ソースにできるリポジトリ
  destinations:                                   # 同期先の許可リスト
    - name: spoke-dev
      namespace: demo-app
  clusterResourceWhitelist:                       # cluster スコープはここに列挙した型のみ
    - group: ""
      kind: Namespace
```

- チーム単位の**マルチテナント区画**として使うのが定番(RBAC と組み合わせて
  「チーム X は project X の Application しか触れない」を作る)
- 範囲外への同期は sync 時に拒否される — ラボの台本 6 で体感できる
- `default` プロジェクトは制限なしなので、実運用では使わないのが常套

## 3. ApplicationSet — Application の量産機構

**generator(データ源)× template(Application の雛形)**で Application を大量生成する。

```yaml
spec:
  generators:
    - git:                       # git generator (files): リポジトリ内の設定ファイルを探す
        repoURL: http://gitea.../manifests.git
        files:
          - path: "app/*/overlay/dev/*/app.argocd.yaml"
  template:                      # 見つかった 1 ファイル = 1 Application
    metadata:
      name: '{{ .name }}'        # ファイル内容が変数として流し込まれる
    spec:
      source:
        path: '{{ .path.path }}' # ファイルの置き場所も変数になる
      ...
```

このラボの `app.argocd.yaml`(マーカー)がこの設定ファイル。押さえるべき性質:

- **opt-in**: ファイルを置いたアプリだけ生成される。置く=デプロイ開始、消す=Application ごと削除
- **ファイルの中身が template parameters になる**(name / namespace / env など)。
  置き場所(パス)自体もデータ(`{{ .path.path }}`)
- 生成された Application は ApplicationSet の所有物 — 手で編集しても template 通りに戻される。
  つまり「ポリシーは template(管理者)、素性データは設定ファイル(利用者)」という分業になる
- generator は git files 以外にも list / cluster / matrix など多数。「N 個の類似アプリ」
  「M クラスタ × N アプリ」のような fan-out が数行で書ける

## CRD ではないが対で覚える: ラベル付き Secret による登録簿

ArgoCD は接続先の登録に CRD ではなく **`argocd.argoproj.io/secret-type` ラベル付きの Secret** を使う。

| secret-type | 何の登録か |
|---|---|
| `cluster` | 宛先クラスタ(name / server URL / 認証) |
| `repository` | 個別リポジトリの接続情報 |
| `repo-creds` | URL プレフィックス単位の認証テンプレート(配下の全 repo に適用) |

このラボでは cluster 登録のみ使用。Secret の構造は `hub/clusters.yaml`(テンプレート)にあり、
動的な値(server)と秘密(bearer token)は `scripts/04-spokes.sh` がセットアップ時に埋める。
Gitea のリポジトリは public なので repository / repo-creds は不要になっている。

## 次に読むもの

- [04-eso.md](04-eso.md) — External Secrets Operator(Secret を GitOps に乗せる方法)
