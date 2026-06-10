# Makefile — convenience targets for the Mattermost GitOps project
# Usage: make <target>
.PHONY: help deploy teardown state-backend validate watch status

help:
	@echo ""
	@echo "  Mattermost GitOps — Available targets:"
	@echo ""
	@echo "  First-time setup:"
	@echo "    make state-backend     Optional: pre-create S3 bucket for Terraform state"
	@echo ""
	@echo "  Main workflow:"
	@echo "    make deploy            Run full bootstrap (Terraform + kubeadm + Flux)"
	@echo "    make teardown          Destroy all infrastructure"
	@echo ""
	@echo "  Development helpers:"
	@echo "    make validate          Validate all Kubernetes YAML (dry-run)"
	@echo "    make watch             Watch Flux reconciliation and pod status"
	@echo "    make status            Show current state of all components"
	@echo "    make plan ENV=staging  Terraform plan without applying"
	@echo ""

state-backend:
	@set -a; [ -f .env ] && . ./.env; set +a; \
	AWS_REGION=$${AWS_REGION:-us-east-1}; \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \
	BUCKET=$${TF_STATE_BUCKET_NAME:-mattermost-openclaw-tfstate-$$ACCOUNT_ID}; \
	echo "Creating Terraform state backend: $$BUCKET"; \
	terraform -chdir=terraform/state-backend init -upgrade; \
	terraform -chdir=terraform/state-backend apply -auto-approve \
	  -var="aws_region=$$AWS_REGION" \
	  -var="state_bucket_name=$$BUCKET"; \
	echo ""; \
	echo "scripts/02-terraform-provision.sh will use this bucket automatically."

deploy:
	bash bootstrap.sh

teardown:
	bash teardown.sh

plan:
	@ENV=$${ENV:-production}; \
	echo "Planning for environment: $$ENV"; \
	terraform -chdir=terraform/environments/$$ENV plan

validate:
	@echo "Validating Kubernetes manifests..."
	kubectl kustomize clusters/staging >/dev/null
	kubectl kustomize clusters/production >/dev/null
	kubectl kustomize infrastructure >/dev/null
	kubectl kustomize apps/database >/dev/null
	kubectl kustomize apps/mattermost >/dev/null
	kubectl kustomize apps/openclaw >/dev/null
	@echo "Validation complete"

watch:
	@echo "Watching Flux and pods (Ctrl+C to exit)..."
	@echo ""
	watch -n5 'echo "=== Flux ===" && flux get kustomizations -A 2>/dev/null; echo ""; echo "=== Pods ===" && kubectl get pods -A --field-selector=status.phase!=Running --field-selector=status.phase!=Succeeded 2>/dev/null | head -20'

status:
	@echo ""
	@echo "=== Nodes ==="
	@kubectl get nodes -o wide
	@echo ""
	@echo "=== Flux Kustomizations ==="
	@flux get kustomizations -A
	@echo ""
	@echo "=== Pods (non-running) ==="
	@kubectl get pods -A | grep -v Running | grep -v Completed || echo "  All pods Running"
	@echo ""
	@echo "=== Mattermost ==="
	@kubectl get mattermost -n mattermost 2>/dev/null || echo "  Not deployed yet"
	@echo ""
	@echo "=== CNPG Cluster ==="
	@kubectl get cluster -n mattermost 2>/dev/null || echo "  Not deployed yet"
	@echo ""
	@echo "=== OpenClaw ==="
	@kubectl get deployment openclaw -n openclaw 2>/dev/null || echo "  Not deployed yet"
