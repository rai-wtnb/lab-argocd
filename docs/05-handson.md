# ハンズオンシナリオ集

`make up` 済みであることが前提。3 部構成:

- **第 1 部(基本)**: GitOps の基本動作を一巡する。全員がやる
- **第 2 部(応用)**: ArgoCD の挙動を深掘りする実験。すべてこのラボで実施できる
- **第 3 部(拡張)**: 「もし〜するなら何が必要か」の解説。読むだけ(実際には行わない)

3 つの画面を開いたまま進めると変化が追いやすい:
ArgoCD UI(https://localhost:8080)/ Gitea(http://localhost:3000)/ podinfo(http://localhost:9898)

---

## 第 1 部: 基本シナリオ

### 1. opt-in の証明

- **目的**: Application は「マーカーを置いた分だけ」生成されることを確認する
- **手順**: ArgoCD UI を開く
- **観察**: Applications に居るのは platform 区画の `gitea` / `vault`(手書き Application。`hub/platform.yaml`)の 2 件だけで、demo 区画は 0 件。AppProject `demo` と ApplicationSet `managed-apps` は居るのに Application が無い — 機構は待機中で、入力(マーカー)が無い状態

### 2. マーカーで生成 → 同期

- **目的**: 「ファイルを 1 個 push しただけでアプリがデプロイされる」を体感する
- **手順**: `make marker-dev` → Gitea でコミットが積まれたのを見る → UI を眺めて待つ(30 秒〜3 分)
- **置かれるもの**: `scripts/marker.sh` が以下の内容を
  `app/web/overlay/dev/demo-app/app.argocd.yaml` として生成し push する
  (Gitea UI か `.work/manifests/` で実物を確認できる):
  ```yaml
  # ApplicationSet (hub/applicationset.yaml) の files generator が読むマーカー
  name: demo-app       # Application 名 (hub 内で一意)
  team: demo           # 所有チーム (label になる)
  project: demo        # 所属する AppProject
  namespace: demo-app  # 同期先 namespace
  env: dev             # 同期先クラスタの解決に使う (spoke-<env>)
  ```
- **観察**:
  - Application `demo-app` が出現し、OutOfSync → Syncing → **Synced / Healthy** と遷移する
  - ツリービューに Deployment / Service / Pod がぶら下がる(リソースの親子関係)
  - `kubectl --context kind-demo-dev -n demo-app get pods` で spoke 側に実体があること
  - http://localhost:9898 に "hello from DEV" が出ること

### 3. selfHeal — 手動変更は巻き戻る

- **目的**: 「Git が唯一の真実」の強制力を見る
- **手順**:
  ```bash
  kubectl --context kind-demo-dev -n demo-app scale deploy/demo-app --replicas=5
  watch kubectl --context kind-demo-dev -n demo-app get deploy
  ```
- **観察**: 数十秒で replicas が 2 に戻る。UI の Application イベントに sync の記録が残る。
  「クラスタを直接いじる運用」がこの世界では成立しないことの体感

### 4. Git 経由の変更が唯一の変更手段

- **目的**: 正規の変更フロー(編集 → push → 自動反映)を体験する
- **手順**: `.work/manifests/app/web/overlay/dev/demo-app/kustomization.yaml` の
  `replicas: 2` を `3` に変えて commit & push(または message の文言を変える)
- **観察**: ポーリング後に sync され、Pod が 3 つに増える(message を変えた場合は
  podinfo の画面文言が変わる — Deployment の env 変更なので Pod は作り直される)

### 5. stg 展開と Application 名の一意性

- **目的**: 同じ hub が複数環境を管理するときの名前設計を知る
- **手順**: `make marker-stg`
- **観察**: Application は `demo-app-stg` という**別名**で生成され、spoke-stg に同期される
  (http://localhost:9899 に "hello from STG")。Application 名は 1 つの ArgoCD 内で一意のため、
  複数環境を同居させるなら名前に環境を織り込む必要がある(マーカーの `name` がその置き場)

### 6. AppProject 区画 — 同期先の制限

- **目的**: AppProject が「越境デプロイ」を止めることを確認する
- **手順**: `.work/manifests` の dev マーカーの `namespace: demo-app` を `namespace: default` に
  書き換えて push
- **観察**: Application が Sync エラーになる(`destination ... is not permitted in project demo`)。
  AppProject の destinations 許可リストに無い宛先は、マニフェストがどう頑張っても同期されない。
  確認後は `namespace: demo-app` に戻して push(復旧も Git 経由)

### 7. prune — マーカー削除 = アプリ削除

- **目的**: 「Git から消えたものは実体も消える」と、revert がロールバックになる理由を掴む
- **手順**: `make unmark-dev`
- **観察**: Application `demo-app` ごと消え、spoke-dev の Deployment / Pod も削除される。
  http://localhost:9898 が応答しなくなる。逆に言えば、切替コミットを revert すれば
  元の状態に完全に戻る — これが GitOps のロールバック

### 8〜10. ESO — 秘密を Git に置かずに配る

基盤(Vault = 外部ストア、ESO)は `make up` で導入済み。

```bash
make marker-secrets  # 8. ExternalSecret を"2個目のマーカーアプリ"として配布
kubectl --context kind-demo-dev -n demo-app get secret demo-app-secret -o jsonpath='{.data.message}' | base64 -d
                     # 9. 生成された Secret の値を確認 (=> s3cr3t-from-vault-v1)
make rotate MSG=v2   # 10. 正本 (Vault) を更新 → refreshInterval(15秒) 後に Secret が追随
```

- **観察**:
  - Git のどこにも秘密の値が現れないまま、K8s Secret が生成・更新される(詳細は [04-eso.md](04-eso.md))
  - マーカー 1 ファイルで 2 個目のアプリが生えた = 量産機構の再演(`app/secrets/` は
    `app/web/` と別ディレクトリだが、generator の glob が自動で拾う)
  - 観察ポイント: ArgoCD 上で ExternalSecret が **CRD スキーマ既定値により恒常 OutOfSync** に
    なることがある。ApplicationSet template に annotation
    `argocd.argoproj.io/compare-options: ServerSideDiff=true` を足すと解消する
    (本番運用で ServerSideDiff が推奨される理由の実演)

---

## 第 2 部: 応用シナリオ(挙動の深掘り)

### A. Synced と Healthy は独立している

- **目的**: 「Git 通りに apply された(Synced)」と「アプリが元気(Healthy)」は別物だと知る
- **手順**: `.work/manifests/app/web/overlay/dev/demo-app/kustomization.yaml` に
  存在しないイメージタグへの上書きを足して push:
  ```yaml
  images:
    - name: ghcr.io/stefanprodan/podinfo
      newTag: 0.0.0-broken
  ```
- **観察**: sync は成功し **Synced** になるが、Pod が ImagePullBackOff になり
  **Progressing → Degraded** に落ちる。「Synced = 安全」ではないことの実例
- **復旧**: `git -C .work/manifests revert HEAD --no-edit && git -C .work/manifests push`
  → revert コミットが sync され Healthy に戻る(第 1 部 7 の「revert = ロールバック」の実践)

### B. 生成された Application は手で編集できない

- **目的**: ApplicationSet の所有権(ポリシーは template、データはマーカー)を体感する
- **手順**: 生成物を直接書き換えてみる:
  ```bash
  kubectl --context kind-demo-hub -n argocd patch application demo-app --type merge \
    -p '{"spec":{"source":{"path":"app/web/overlay/stg/demo-app"}}}'
  kubectl --context kind-demo-hub -n argocd get application demo-app -o jsonpath='{.spec.source.path}' -w
  ```
- **観察**: applicationset-controller が template 通りの値に巻き戻す。
  selfHeal(spoke のリソースを守る)と同じ構図が、Application リソース自身にも効いている —
  変更したければマーカーか template を変えるしかない

### C. 名前の衝突を起こしてみる

- **目的**: hub 内で Application 名が重複するとどうなるかを安全に確認する
- **手順**: `.work/manifests` の stg マーカーの `name: demo-app-stg` を `name: demo-app` に
  書き換えて push(dev マーカーが生きている状態で)
- **観察**: ApplicationSet が重複を検出し、`kubectl --context kind-demo-hub -n argocd describe
  applicationset managed-apps` の status conditions にエラーが記録される。
  片方の定義が勝ち、もう片方は反映されない(どちらが勝つかは保証されない — だから設計で防ぐ)
- **復旧**: `name: demo-app-stg` に戻して push

### D. Refresh / Hard Refresh / Sync の違い

- **目的**: UI のボタンの意味を正しく知る
- **手順**: UI で Application を開き、それぞれを押して挙動を見る

| 操作 | 何をするか | いつ使うか |
|---|---|---|
| Refresh | Git を読み直して render し、diff を再計算する(apply はしない) | push したのに反映が見えない時 |
| Hard Refresh | render キャッシュを破棄して Refresh | kustomize の出力が怪しい時 |
| Sync | diff を apply する | automated を待たず即時反映したい時 |

- **補足**: このラボは automated sync + ポーリング短縮(20〜30 秒)なので普段はボタン不要。
  本番では Git の webhook を配線して push 起点の即時 Refresh にするのが定石(第 3 部 X6)

### E. ArgoCD の RBAC(policy.csv)— 人間側の権限境界

- **目的**: K8s RBAC(同期の実行主体の権限)とは別レイヤの、
  「人間が ArgoCD の UI/API で何をできるか」の認可を体感する
- **前提知識**: 権限は `argocd-rbac-cm` の `policy.csv`(Casbin 形式)で定義される:
  ```
  p, role:team-demo, applications, sync, demo/*, allow   # p 行: role への許可 (project demo 配下に限定)
  g, demo-dev, role:team-demo                            # g 行: ユーザー → role の割り当て
  ```
  既定は拒否(policy.default が空)で、admin だけは RBAC を素通しする superuser
- **手順**: シークレットウィンドウで https://localhost:8080 を開き、
  **demo-dev / demo12345** でログイン(`hub/argocd/values.yaml` で定義したローカルアカウント)
  1. Application 一覧・詳細・ログが**見える**(get / logs 許可)
  2. Sync ボタン → **成功する**(sync 許可)
  3. Delete → **permission denied**(delete は許可していない)
  4. platform 区画の `gitea` / `vault` は**一覧に出ない**(許可が `demo/*` 限定のため、
     他プロジェクトは存在ごと見えない)
- **観察**: admin タブと並べると同じ画面で押せるボタンが違う。
  本番ではこの `g` 行の subject をローカルユーザーではなく SSO(IdP)のチーム・グループにして、
  「チーム X は project X の Application しか触れない」というマルチテナント区画を作るのが定石

### F. 失敗した自動 sync は同一リビジョンでは再試行されない

- **目的**: 「automated + selfHeal なら何をしても勝手に直る」わけではない境界を知る
- **手順**: platform 区画の Vault を namespace ごと消す
  ```bash
  kubectl --context kind-demo-hub delete ns vault
  ```
- **観察**: selfHeal が即座に sync を始めるが、ns の終了処理と競合して
  Deployment/Service の作成が `namespaces "vault" not found` で失敗することがある。
  このとき数回のリトライは**失敗したタスクだけ**を再適用するため
  (成功扱いになった Namespace は作り直されず)失敗が確定し、以後
  **同一リビジョンに対する自動 sync は再試行されない** — アプリは SyncError のまま止まる
- **復旧**: 手動 sync(UI の Sync ボタン)で新しい operation を起こせば一発で直る。
  `make eso-up` でもよい(スクリプトが同じことを kubectl の operation patch で行い、
  Vault の初期値も入れ直す。dev モードの Vault はインメモリなので pod が消えると値も消える)
- **教訓**: 自動 sync の再試行は「新しいコミット」か「live 状態の新たな変化」が引き金。
  失敗で止まったら人間(または新コミット)が operation を起こす必要がある

---

## 第 3 部: 拡張シナリオ(解説のみ。実際には行わない)

### X1. spoke クラスタを増やすなら

新しい宛先クラスタ 1 つにつき、5 つの関門を開ける:

1. **接続** — クラスタ登録 Secret(`argocd.argoproj.io/secret-type: cluster`)を hub に置く。
   name / server URL / 認証(このラボは SA token、本番は IAM 連携)
2. **書き込み権限** — 宛先クラスタ側に argocd-manager(read + Namespace)と
   app-writer(アプリの kind への write)の RBAC を敷く
3. **許可** — AppProject の destinations に「新クラスタ × namespace」を追加
4. **発見** — ApplicationSet がその環境のマーカーを読めるか(このラボの generator は
   dev / stg のパスを列挙しているので、新環境ならパス追加が要る。X4 参照)
5. **名前** — hub 内で Application 名が一意になる命名を決める

このラボでは `scripts/04-spokes.sh` + `hub/appproject.yaml` がこの一式に対応している。
チェックどれか 1 つが欠けると「生成されない / 同期拒否 / リソース不可視 / apply forbidden」と
**別々の症状**で止まるので、症状から欠けた関門を逆引きできるようになると強い。

### X2. アプリを増やすなら

1. seed-repo 側に `app/<kind>/base/<新アプリ>/` と `app/<kind>/overlay/<env>/<新アプリ>/` を作る
2. 別 namespace に置くなら: AppProject の destinations と spoke の RoleBinding に namespace を追加
   (demo-app namespace のままなら基盤変更ゼロ)
3. マーカーを置く — 以上

「アプリ追加のコストがマーカー 1 ファイルに漸近する」のが量産機構の狙い。
実はこのラボの `demo-secrets`(ESO)が 2 個目のアプリの実例になっている。

### X3. 対象ディレクトリ(app/<kind>)を増やすなら

**何もしなくてよい**。generator のパスは `app/*/overlay/dev/*/app.argocd.yaml` と
ワイルドカードなので、`app/api/` や `app/batch/` を新設しても自動で対象になる。
実例: このラボの `app/web/`(demo-app)と `app/secrets/`(demo-secrets)は
ApplicationSet に一切手を入れず共存している。
「増やすときに基盤を触らせない」ための glob 設計 — 逆に対象を絞りたくなったら
パスを列挙式に変える、というトレードオフ。

### X4. 環境(prod)を増やすなら

X1(クラスタ追加)に加えて:

1. ApplicationSet の files に `app/*/overlay/prod/*/app.argocd.yaml` を追加
   (env のパスは明示列挙 — 環境の追加は意図的な操作であるべき、という設計)
2. destination 解決(`spoke-{{ .env }}`)は env フィールド駆動なので template 変更は不要
3. 本番だけ挙動を変えたい場合(例: automated を外して手動 Sync にする)は
   template が全アプリ共通である以上、ApplicationSet を環境別に分けることになる —
   「型が割れるなら ApplicationSet を分ける」が定石

### X5. private リポジトリにするなら

Gitea のリポジトリを private にすると ArgoCD は clone できなくなる。対処は
`argocd.argoproj.io/secret-type: repository`(個別リポジトリ)または `repo-creds`
(URL プレフィックス単位の認証テンプレート)の Secret を hub に置く。
詳細は [03-argocd-crds.md](03-argocd-crds.md) の登録簿 Secret の節。

### X6. push 起点の即時反映にするなら

ポーリングを待たず push で即 Refresh させるには、Git サーバの webhook を 2 本配線する:

1. Application の refresh 用: `https://<argocd-server>/api/webhook`
2. ApplicationSet(マーカー検出)用: applicationset-controller の webhook(port 7000)

このラボはポーリング間隔の短縮(`timeout.reconciliation` / requeue)で代替している。

### X7. 通知を足すなら

notifications-controller を有効化し(このラボの values では無効)、
trigger(on-sync-failed 等)と template(メッセージ)を設定した上で、
Application の annotation(`notifications.argoproj.io/subscribe.<trigger>.<service>: <宛先>`)で購読する。
ApplicationSet 経由なら template の annotations に入れて全アプリ一括購読にできる。
運用の定石は「失敗系のみ通知(正常時は無音)」— 全イベント通知は必ずノイズ化する。

### X8. 本番に向けて残る差分

このラボと本番構成の差は README の「このラボと本番運用の違い」の表を参照。
特に大きい 3 つ:

- **認証の秘密レス化**: SA token → クラウド IAM 連携(cluster Secret から秘密が消える)
- **self-management**: ArgoCD 自身も ArgoCD の Application として管理し、
  本体のアップグレードも GitOps に乗せる(app-of-apps パターン)
- **SSO(IdP 連携)**: `policy.csv` によるチーム区画自体はシナリオ E で体験済み。本番で変わるのは
  `g` 行の subject をローカルユーザー(demo-dev)から IdP のチーム・グループに置き換える点と、
  admin ログイン・ローカルアカウントを無効化する点
