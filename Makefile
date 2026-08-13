SHELL := /bin/bash

.PHONY: up down argocd-info argocd-render argocd-chart-values status marker-dev marker-stg unmark-dev unmark-stg eso-up marker-secrets unmark-secrets rotate

up:
	./scripts/00-prereqs.sh
	./scripts/01-clusters.sh
	./scripts/02-argocd.sh
	./scripts/03-gitea.sh
	./scripts/04-spokes.sh
	./scripts/05-bootstrap.sh
	./scripts/06-eso.sh
	@echo ""
	@echo "== 完了。次: make argocd-info で UI の URL とパスワードを表示 / make marker-dev でデモ開始 =="

argocd-info:
	@echo "admin パスワード: $$(kubectl --context kind-demo-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	@echo "RBAC デモ用ユーザー: demo-dev / demo12345 (sync 可・delete 不可。docs/05-handson.md の E)"
	@echo "https://localhost:8080 (NodePort 経由で常時アクセス可。証明書警告は無視してよい)"

# ArgoCD 本体のレンダリング結果 (chart デフォルト + values.yaml の差分をマージした最終形) を表示
argocd-render:
	kubectl kustomize --enable-helm hub/argocd

# chart のデフォルト values 全量を表示 (values.yaml はここからの差分だけを書く)。
# バージョンは hub/argocd/kustomization.yaml の pin を単一の正として拾う
argocd-chart-values:
	helm show values argo-cd --repo https://argoproj.github.io/argo-helm \
	  --version $$(awk '/^ *version:/{print $$2}' hub/argocd/kustomization.yaml)

status:
	@echo "== Applications (hub) =="
	@kubectl --context kind-demo-hub -n argocd get applications 2>/dev/null || true
	@echo "//////////////////////////////////////////////////////////////////"
	@echo "== spoke-dev demo-app =="
	@kubectl --context kind-demo-dev -n demo-app get deploy,pods 2>/dev/null || echo "(なし)"
	@echo "//////////////////////////////////////////////////////////////////"
	@echo "== spoke-stg demo-app =="
	@kubectl --context kind-demo-stg -n demo-app get deploy,pods 2>/dev/null || echo "(なし)"

marker-dev:
	./scripts/marker.sh add dev

marker-stg:
	./scripts/marker.sh add stg

unmark-dev:
	./scripts/marker.sh remove dev

unmark-stg:
	./scripts/marker.sh remove stg

# --- ESO 基盤の単体再実行用 (make up に含まれている。冪等) ---

eso-up:
	./scripts/06-eso.sh

marker-secrets:
	./scripts/marker.sh add dev demo-secrets

unmark-secrets:
	./scripts/marker.sh remove dev demo-secrets

# Vault の値を更新する (refreshInterval 15s 後に K8s Secret が追随する)
rotate:
	@test -n "$(MSG)" || (echo "usage: make rotate MSG=new-value"; exit 1)
	kubectl --context kind-demo-hub -n vault exec deploy/vault -- \
	  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
	  vault kv put secret/demo-app message="$(MSG)"

down:
	-kind delete cluster --name demo-hub
	-kind delete cluster --name demo-dev
	-kind delete cluster --name demo-stg
	rm -rf .work
