.DEFAULT_GOAL := help
SHELL := /bin/bash
.ONESHELL:

REGION      ?= us-east-1
PROJECT     ?= llm-d-on-eks
CLUSTER     ?= $(PROJECT)
TF          ?= terraform
BOOTSTRAP   := terraform/00-bootstrap
CLUSTER_DIR := terraform/10-cluster
INFER_DIR   := terraform/20-inference

# Pinned to llm-d v1.0.0. Keep aligned with the table in README.md.
export LLMD_VERSION        ?= v1.0.0
export GATEWAY_API_VERSION ?= v1.6.2
export GAIE_VERSION        ?= v1.6.2
export ISTIO_VERSION       ?= 1.29.4
export ROUTER_CHART        ?= oci://ghcr.io/llm-d/charts/llm-d-router-standalone
export SIM_IMAGE           ?= ghcr.io/llm-d/llm-d-inference-sim:v1.0.0
export VLLM_IMAGE          ?= docker.io/vllm/vllm-openai:v0.30.0

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS=":.*##"; printf "\nllm-d-on-eks\n"} \
	/^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Cost & safety

.PHONY: prices
prices: ## Re-measure current spot prices for the instance types this project uses
	@./scripts/prices.sh $(REGION)

.PHONY: cost
cost: ## Actual spend to date, attributed by the Project tag
	@start=$$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%d)
	@end=$$(date -u +%Y-%m-%d)
	aws ce get-cost-and-usage --region us-east-1 \
	  --time-period Start=$$start,End=$$end \
	  --granularity MONTHLY --metrics UnblendedCost \
	  --filter '{"Tags":{"Key":"Project","Values":["$(PROJECT)"]}}' \
	  --group-by Type=DIMENSION,Key=SERVICE \
	  --query 'ResultsByTime[].Groups[].{Service:Keys[0],USD:Metrics.UnblendedCost.Amount}' \
	  --output table

.PHONY: quota
quota: ## Show G/VT GPU quota and any pending increase requests
	@echo "== current limits ($(REGION)) — note: denominated in vCPUs, g6.xlarge is 4"
	aws service-quotas list-service-quotas --service-code ec2 --region $(REGION) \
	  --query 'Quotas[?contains(QuotaName,`G and VT`)].{Code:QuotaCode,Name:QuotaName,vCPUs:Value}' \
	  --output table
	@echo "== pending requests"
	aws service-quotas list-requested-service-quota-change-history \
	  --service-code ec2 --region $(REGION) \
	  --query 'RequestedQuotas[].{Name:QuotaName,Desired:DesiredValue,Status:Status,Case:CaseId}' \
	  --output table

.PHONY: whats-running
whats-running: ## Anything in this account currently costing money for this project
	@echo "== EKS clusters"; aws eks list-clusters --region $(REGION) --query clusters --output text
	@echo "== EC2 instances"; aws ec2 describe-instances --region $(REGION) \
	  --filters Name=instance-state-name,Values=running,pending \
	  --query 'Reservations[].Instances[].{Type:InstanceType,Id:InstanceId,Life:InstanceLifecycle}' --output table
	@echo "== load balancers"; aws elbv2 describe-load-balancers --region $(REGION) \
	  --query 'LoadBalancers[].{Name:LoadBalancerName,Type:Type}' --output table
	@echo "== NAT gateways (should be empty — they are the big leak)"
	aws ec2 describe-nat-gateways --region $(REGION) \
	  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text

##@ Bootstrap

.PHONY: bootstrap
bootstrap: ## Create the remote state bucket (run once)
	cd $(BOOTSTRAP) && $(TF) init -input=false && \
	  $(TF) apply -input=false -var region=$(REGION) -var project=$(PROJECT)

##@ Tiers

.PHONY: sim-local
sim-local: ## T0 ($0): kind + llm-d-inference-sim on your laptop
	@echo "not implemented yet — see 'Build order' in README.md"; exit 1

.PHONY: sim-eks
sim-eks: ## T1 (~$0.15/hr): EKS + llm-d-inference-sim, no GPU
	@echo "not implemented yet — see 'Build order' in README.md"; exit 1

.PHONY: gpu
gpu: ## T2 (~$0.60/hr): EKS + real vLLM on g6.xlarge spot
	@echo "not implemented yet — see 'Build order' in README.md"; exit 1

.PHONY: load
load: ## Fire k6 at the endpoint and watch replicas scale
	@echo "not implemented yet — see 'Build order' in README.md"; exit 1

##@ Teardown

.PHONY: down
down: ## Destroy the inference layer only — GPU gone, cluster warm ($0.10/hr)
	cd $(INFER_DIR) && $(TF) destroy -input=false -auto-approve

.PHONY: nuke
nuke: ## Destroy everything except remote state — $0.00/hr
	-cd $(INFER_DIR) && $(TF) destroy -input=false -auto-approve
	cd $(CLUSTER_DIR) && $(TF) destroy -input=false -auto-approve
	@echo ""
	@echo "Verifying nothing is still billing:"
	@$(MAKE) --no-print-directory whats-running

##@ Checks

.PHONY: fmt validate lint
fmt: ## terraform fmt across all layers
	$(TF) fmt -recursive terraform/

validate: ## terraform validate across all layers
	@for d in $(BOOTSTRAP) $(CLUSTER_DIR) $(INFER_DIR); do \
	  [ -f "$$d/versions.tf" ] || continue; \
	  echo "== $$d"; \
	  (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate) || exit 1; \
	done

lint: ## Security and policy scan
	@command -v trivy >/dev/null && trivy config terraform/ || echo "trivy not installed, skipping"
	@command -v tflint >/dev/null && tflint --recursive terraform/ || echo "tflint not installed, skipping"
