# manifests (ラボ用シードリポジトリ)

`app/<kind>/overlay/<env>/<app>/` 構造で Kubernetes マニフェストを管理するリポジトリ。

- `app.argocd.yaml`(マーカー)を overlay ディレクトリに置くと、hub の ApplicationSet が
  Application を自動生成してこの overlay を同期する(opt-in)。
- マーカーの追加/削除は demo リポジトリ側の `make marker-dev` / `make unmark-dev` などで行う。

`platform/` は hub 上の基盤コンポーネント(Gitea / Vault)のマニフェスト。こちらはマーカー方式
ではなく、手書きの Application(hub の `platform.yaml`)が同期する。Gitea は自分自身のマニフェスト
をこのリポジトリで持つ鶏と卵の関係なので、初回のみセットアップスクリプトが直接 apply している。
