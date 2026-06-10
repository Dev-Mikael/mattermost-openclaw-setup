# mattermost-openclaw-setup

Production-oriented self-hosted **Mattermost + OpenClaw** on Kubernetes.

**Stack:** Terraform, AWS EC2 kubeadm, AWS NLB, FluxCD GitOps, CloudNativePG, AWS EBS CSI, External Secrets Operator, AWS Secrets Manager, AWS S3, cert-manager, nginx-ingress, OpenClaw

## Architecture

```
Your Machine
  +- terraform apply  -> VPC, EC2, NLB, S3, IAM, Secrets Manager
  +- kubeadm          -> Kubernetes control plane + workers over SSH, with SSM fallback for workers
  +- flux bootstrap   -> GitOps reconciliation from this repo
  +- ESO              -> AWS Secrets Manager -> Kubernetes Secrets
  +- CNPG             -> PostgreSQL primary + replicas for Mattermost
  +- OpenClaw setup   -> Mattermost bot token + OpenClaw deployment

Internet -> AWS NLB 80/443 -> worker NodePorts 30080/30443 -> nginx -> apps
```

Flux order:

```
infrastructure
  +- cert-manager-config
  +- external-secrets-config
  +- database
       +- apps
            +- openclaw
```

## Quick Start

```bash
cp .env.example .env
nano .env
aws configure

bash bootstrap.sh
```

`bootstrap.sh` automatically creates/uses the Terraform state bucket through
`scripts/02-terraform-provision.sh`. By default the bucket is named
`mattermost-openclaw-tfstate-<aws-account-id>`. Override with
`TF_STATE_BUCKET_NAME` in `.env` only if you want a custom state bucket name.

Create DNS records after Terraform prints the NLB DNS name:

| Host | Type | Value |
|------|------|-------|
| `@` or your Mattermost host | CNAME | NLB DNS name |
| `openclaw` | CNAME | NLB DNS name |

## Key Files

| File | Purpose |
|------|---------|
| `bootstrap.sh` | Full deploy: tools, Terraform, kubeadm, Flux, secrets, verify, OpenClaw |
| `teardown.sh` | Destroys Terraform-managed cloud infrastructure |
| `Makefile` | Convenience targets for deploy, validate, status, teardown |
| `terraform/state-backend/` | S3 backend bucket for Terraform state; created automatically by `scripts/02-terraform-provision.sh` |
| `terraform/environments/` | Staging and production Terraform roots |
| `terraform/modules/` | VPC, EC2, IAM, NLB, S3, Secrets Manager modules |
| `clusters/production/` | Flux Kustomization dependency chain |
| `infrastructure/` | Operators/controllers installed by Flux HelmReleases |
| `apps/database/` | CNPG Cluster and ESO database secrets |
| `apps/mattermost/` | Mattermost CR using CNPG + S3 |
| `apps/openclaw/` | Official-style OpenClaw Kustomize manifests, nginx ingress, network policy, ESO secret |
| `scripts/07-setup-openclaw.sh` | Creates Mattermost bot token and OpenClaw AWS secrets |
| `scripts/08-manage-bot.sh` | Day-2 bot/pairing/channel helper |

## Secrets

Set `SECRET_PREFIX=mattermost-openclaw-setup` in `.env`. The scripts write these AWS Secrets Manager entries:

```text
mattermost-openclaw-setup/db-password
mattermost-openclaw-setup/openclaw-gateway-token
mattermost-openclaw-setup/anthropic-api-key
mattermost-openclaw-setup/gemini-api-key
mattermost-openclaw-setup/mattermost-bot-token
```

ESO syncs those into Kubernetes at runtime. Secret values are not committed.

## Bootstrap Notes

`scripts/02-terraform-provision.sh` writes `WORKER_PUBLIC_IPS`,
`WORKER_PRIVATE_IPS`, and `WORKER_INSTANCE_IDS` into `.env`. The kubeadm step
tries SSH first for worker setup and join, then falls back to AWS SSM when a
worker's public SSH endpoint is not reachable yet.

## Useful Commands

```bash
make validate
make status
flux get kustomizations -A
kubectl get pods -n mattermost
kubectl get pods -n openclaw
bash scripts/08-manage-bot.sh
```

## Teardown

```bash
bash teardown.sh
```

The Terraform state backend is intentionally not destroyed by teardown.
