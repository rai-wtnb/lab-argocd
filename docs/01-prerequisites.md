# 事前知識: 登場するツールの層構造

ArgoCD に入る前に、このラボで使う道具が「どの層で何をしているか」を押さえる。

```
macOS
 └── colima (lima の VM)        ← Linux カーネルを用意する層
      └── docker デーモン       ← コンテナを動かす層
           └── kind             ← コンテナをノードに見立てて K8s クラスタを作る層
                └── Kubernetes  ← ここに ArgoCD とアプリが乗る
```

## lima / colima — macOS に Linux を用意する

コンテナは Linux カーネルの機能(namespace / cgroup)で動くため、macOS 上では直接実行できず、必ずどこかに Linux VM が要る。

- **lima**: macOS 用の軽量 Linux VM マネージャ。VM の作成・ファイル共有・ポート転送を面倒みる
- **colima**: lima を docker / containerd / k8s 用途向けにパッケージしたラッパー。`colima start` 一発で「Linux VM + docker デーモン + ホストから使える docker CLI 設定」まで揃う。Docker Desktop の代替としてよく使われる

## kind — docker コンテナで K8s クラスタを作る

**K**ubernetes **in** **D**ocker。docker コンテナ 1 個を「ノード 1 台」に見立ててクラスタを作る。

- 起動が速い(数十秒)、複数クラスタを並べられる、消すのも一瞬 — 検証・CI 向き
- クラスタ間は同じ docker ネットワーク上にあるため、コンテナ名で相互に到達できる
  (このラボの hub→spoke 接続や spoke→Vault 接続はこの性質を使っている)
- `kind create cluster` は `~/.kube/config` に context を追加し、current-context を切り替える点に注意

## kubectl と context

kubectl は「どのクラスタに話すか」を kubeconfig の **context** で決める。クラスタが 3 つあるこのラボでは、
事故防止のため全コマンドで `--context kind-demo-dev` のように明示している。

## helm — テンプレート型のパッケージマネージャ

K8s マニフェストの配布形式。**chart**(テンプレート群)に **values**(設定値)を流し込んで
マニフェストを生成(render)する。

- 世の中のミドルウェアは chart で配布されることが多い(ArgoCD も ESO も chart が公式配布物)
- `helm install` はリリース管理(履歴・rollback)まで行うが、render だけ使う運用もある(次項)

## kustomize — パッチ型のマニフェスト合成

テンプレートを使わず、**素の YAML(base)に差分(overlay / patch)を重ねて**合成する。kubectl に内蔵
(`kubectl kustomize`, `kubectl apply -k`)。

- `base/` に共通定義、`overlay/dev/` `overlay/stg/` に環境差分、という構成が定番
- このラボの seed-repo(デモアプリ)がこの構成

**helm との合流点**: kustomize には `helmCharts` 機構があり、`--enable-helm` を付けると
「chart を values で render した結果」を kustomize の素材として取り込める。
このラボの ArgoCD 本体(`hub/argocd/`)はこの方式 — chart の配布力と kustomize の合成力の併用で、
helm のリリース管理は使わない(適用は kubectl の server-side apply)。

| | helm | kustomize |
|---|---|---|
| 方式 | テンプレートに値を流し込む | YAML にパッチを重ねる |
| 得意 | 配布物の受け取り・大量の設定点 | 自作マニフェストの環境差分管理 |
| このラボ | ArgoCD / ESO の導入 | デモアプリの base/overlay、ArgoCD の設定合成 |

## 次に読むもの

- [02-argocd.md](02-argocd.md) — ArgoCD とは何か(GitOps・アーキテクチャ・sync の意味)
