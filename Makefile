# Reproducible bootstrap of the local platform.
#
#   make bootstrap   create the cluster and bring the whole stack up
#   make down        tear everything down
#   make help        list targets

KIND_CLUSTER   ?= open-idp
KIND_CONFIG    ?= 00-local/kind/cluster.yaml
KUBE_CONTEXT   ?= kind-$(KIND_CLUSTER)
ARGO_CHART     ?= 00-core/argo
ARGO_NAMESPACE ?= argo
COMPOSE_FILE   ?= 00-local/nginx/docker-compose.yaml

# Each KinD node needs its own share of the host inotify budget; the kernel
# defaults (128 instances) are not enough for a multi-node cluster.
MIN_INOTIFY_INSTANCES ?= 512
MIN_INOTIFY_WATCHES   ?= 524288

KUBECTL = kubectl --context $(KUBE_CONTEXT)

HELM_ARGO = helm upgrade --install argo $(ARGO_CHART) \
	--kube-context $(KUBE_CONTEXT) \
	--namespace $(ARGO_NAMESPACE) --create-namespace \
	--reset-values --wait --timeout 10m

.DEFAULT_GOAL := help
.PHONY: help bootstrap preflight cluster deps argo-init argo wait-traefik proxy status down clean argo-credentials grafana-credentials

help: ## List available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

bootstrap: preflight cluster deps argo-init argo proxy ## Full setup, from empty machine to running platform
	@echo
	@echo "Platform ready. Argo CD: http://k8s.com/argo (add 127.0.0.1 k8s.com to /etc/hosts)"
	@echo "Initial admin password:"
	@$(KUBECTL) -n $(ARGO_NAMESPACE) get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo

preflight: ## Check the host sysctls KinD nodes need
	@fail=0; \
	inst=$$(sysctl -n fs.inotify.max_user_instances); \
	if [ "$$inst" -lt $(MIN_INOTIFY_INSTANCES) ]; then \
		echo "fs.inotify.max_user_instances is $$inst, need >= $(MIN_INOTIFY_INSTANCES)"; fail=1; \
	fi; \
	watches=$$(sysctl -n fs.inotify.max_user_watches); \
	if [ "$$watches" -lt $(MIN_INOTIFY_WATCHES) ]; then \
		echo "fs.inotify.max_user_watches is $$watches, need >= $(MIN_INOTIFY_WATCHES)"; fail=1; \
	fi; \
	if [ "$$fail" = 1 ]; then \
		echo; \
		echo "Each KinD node runs systemd and a kubelet, which exhaust the default"; \
		echo "inotify budget: the node never reaches its Multi-User target and"; \
		echo "'kind create cluster' fails. Raise the limits with:"; \
		echo; \
		echo "  sudo tee /etc/sysctl.d/99-kind.conf >/dev/null <<'EOF'"; \
		echo "  fs.inotify.max_user_instances = $(MIN_INOTIFY_INSTANCES)"; \
		echo "  fs.inotify.max_user_watches = $(MIN_INOTIFY_WATCHES)"; \
		echo "  EOF"; \
		echo "  sudo sysctl --system"; \
		echo; \
		exit 1; \
	fi; \
	echo "preflight ok (inotify instances=$$inst watches=$$watches)"

cluster: preflight ## Create the KinD cluster (no-op if it already exists)
	@if kind get clusters 2>/dev/null | grep -qx '$(KIND_CLUSTER)'; then \
		echo "cluster '$(KIND_CLUSTER)' already exists, skipping"; \
	else \
		kind create cluster --config $(KIND_CONFIG); \
	fi

deps: ## Resolve the bootstrap chart dependencies
	helm dependency build $(ARGO_CHART)

argo-init: ## First install pass: Argo CD and its CRDs, without the Applications
	@if $(KUBECTL) get crd applications.argoproj.io >/dev/null 2>&1; then \
		echo "Argo CD CRDs already present, skipping the bootstrap pass"; \
	else \
		echo "installing Argo CD without Applications (its CRDs do not exist yet)"; \
		$(HELM_ARGO) --set app-of-apps.applications=null; \
	fi

argo: ## Install/upgrade the bootstrap layer (Argo CD + App of Apps)
	$(HELM_ARGO)

argo-credentials: ## Get the argo init credentials
	$(KUBECTL) get secret -n argo argocd-initial-admin-secret -ojson | jq '.data.password | @base64d' -r

wait-traefik: ## Block until Argo CD has synced Traefik (the ingress path)
	@echo "waiting for Argo CD to sync Traefik (CRD ingressroutes.traefik.io)..."
	@for i in $$(seq 1 120); do \
		if $(KUBECTL) get crd ingressroutes.traefik.io >/dev/null 2>&1; then \
			echo "Traefik CRDs are in place"; exit 0; \
		fi; \
		sleep 5; \
	done; \
	echo "timed out after 10m; check 'make status'"; exit 1

proxy: ## Start the host nginx reverse proxy
	docker compose -f $(COMPOSE_FILE) up -d

status: ## Show the Argo CD applications and their sync state
	@$(KUBECTL) -n $(ARGO_NAMESPACE) get applications.argoproj.io

down: ## Delete the cluster and stop the host proxy
	-docker compose -f $(COMPOSE_FILE) down
	kind delete cluster --name $(KIND_CLUSTER)

clean: down ## Alias for `down`, plus the vendored chart dependencies
	find . -name 'Chart.lock' -delete
	find . -path '*/charts/*.tgz' -delete

grafana-credentials: ## Get Grafana admin credentials
	$(KUBECTL) get secret -n grafana grafana -oyaml | yq '.data["admin-password"] | @base64d'
