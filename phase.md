# Deployment Phase Notes

Last updated: 2026-06-10

This document records the current working phase for `mattermost-openclaw-setup`: what is already deployed, the settings that made it work, the important errors encountered, and the next phases to tackle after a teardown/rebuild.

## Current Phase

The project now deploys a self-hosted Mattermost + OpenClaw stack on AWS-backed kubeadm infrastructure.

Completed scope:

- Terraform provisions AWS infrastructure for the selected environment.
- kubeadm builds a multi-node Kubernetes cluster on EC2.
- FluxCD bootstraps GitOps from this repository.
- External Secrets Operator syncs secrets from AWS Secrets Manager.
- CloudNativePG provides PostgreSQL for Mattermost.
- Mattermost is deployed through the Mattermost Operator.
- S3 is used for Mattermost file storage.
- nginx-ingress and cert-manager expose Mattermost and OpenClaw over HTTPS.
- OpenClaw is deployed from local Kustomize manifests and connected to Mattermost as `openclaw-bot`.
- The bot is able to reply in Mattermost after pairing and prompt cleanup.

## Infrastructure Provisioning

Terraform environment roots live under:

- `terraform/environments/staging/`
- `terraform/environments/production/`

Modules live under `terraform/modules/`:

- `vpc`: VPC and public subnets.
- `iam`: instance profiles and IAM access for S3 and Secrets Manager.
- `ec2-cluster`: control plane and worker EC2 instances plus SSH key output.
- `nlb`: internet-facing Network Load Balancer forwarding TCP 80/443 to nginx NodePorts.
- `s3`: Mattermost file storage bucket with public access blocked, versioning, SSE, CORS, and lifecycle transition.
- `secrets`: AWS Secrets Manager entries that receive values from scripts, not Terraform state.

Terraform state backend:

- `terraform/state-backend/` creates the S3 state bucket.
- Environment backends use S3 native lockfiles with `use_lockfile = true`.
- The older `dynamodb_table` backend setting was removed because Terraform now warns that it is deprecated.
- `scripts/02-terraform-provision.sh` creates/ensures the state bucket automatically, then runs `terraform init -reconfigure` with `-backend-config` values.
- Default state bucket name is `mattermost-openclaw-tfstate-<aws-account-id>`. Override with `TF_STATE_BUCKET_NAME` in `.env` only if needed.
- Terraform version is now pinned at `>= 1.10.0` where lockfile support is expected.

Important infrastructure fixes already applied:

- Fixed `terraform/modules/s3/variables.tf` so `force_destroy` is a valid multi-line Terraform variable block.
- Added an explicit empty lifecycle `filter { prefix = "" }` in the S3 lifecycle rule to avoid provider warnings.
- Shortened NLB target group names to stay under AWS's 32-character target group name limit.
- `scripts/02-terraform-provision.sh` writes Terraform outputs back into `.env`, including node IPs, SSH key path, NLB DNS, and S3 bucket.

## kubeadm Cluster Bootstrap

`scripts/03-kubeadm-setup.sh` builds the cluster after Terraform completes.

Current behavior:

- Installs containerd, kubeadm, kubelet, and kubectl on the control plane and worker nodes.
- Initializes Kubernetes on the control plane.
- Installs Flannel CNI.
- Installs local-path-provisioner and marks it as the default StorageClass.
- Fetches kubeconfig locally to `~/.kube/config`.
- Fetches the worker join command using a sudo fallback when direct `scp` cannot read `/tmp/kubeadm-join.sh`.
- Joins workers and waits for all nodes to become Ready.

Important bootstrap notes:

- Early SSH retries can happen while EC2 cloud-init is still finishing. That is normal.
- Worker public IPs must come from Terraform outputs; rerun `scripts/02-terraform-provision.sh` if `.env` is stale.
- The control plane remains tainted so regular workloads run on worker nodes.

## Flux Bootstrap

`scripts/04-bootstrap-flux.sh` bootstraps Flux into the cluster.

Current behavior:

- Renders `clusters/<CLUSTER_NAME>/cluster-config.yaml` with postBuild substitution values.
- Bootstraps Flux against the GitHub repo configured in `.env`.
- Pulls Flux-generated `gotk-*` manifests back into the repo.
- Applies `cluster-values` immediately so first reconciliation can substitute values.

Flux dependency chain:

```text
infrastructure
  -> cert-manager-config
  -> external-secrets-config
  -> database
       -> apps
            -> openclaw
```

Important Flux notes:

- If bootstrap is interrupted or rerun too early, `flux-system` objects may briefly be missing. Re-run the reconcile commands after Flux components settle.
- `cluster-config.yaml` is generated and safe to commit because it contains values, not secrets.
- The GitHub token is used only for bootstrap/push and reset out of the git remote afterward.

## External Secrets And AWS Secrets Manager

Secrets are stored in AWS Secrets Manager and synced to Kubernetes by External Secrets Operator.

Current secret prefix:

```text
mattermost-openclaw-setup
```

Current AWS Secrets Manager entries:

```text
mattermost-openclaw-setup/db-password
mattermost-openclaw-setup/openclaw-gateway-token
mattermost-openclaw-setup/anthropic-api-key
mattermost-openclaw-setup/gemini-api-key
mattermost-openclaw-setup/mattermost-bot-token
```

Secret flow:

- `scripts/05-create-secrets.sh` writes the database password.
- `apps/database/external-secret.yaml` feeds CNPG and Mattermost database credentials.
- `scripts/07-setup-openclaw.sh` creates or finds the Mattermost bot, creates the bot token, and writes OpenClaw secrets.
- `apps/openclaw/external-secret.yaml` syncs gateway/model/bot secrets into `openclaw-secrets`.

Important secret notes:

- Secret values are not committed.
- `scripts/07-setup-openclaw.sh` no longer prints the gateway token in the final URL. Use `OPENCLAW_GATEWAY_TOKEN` from local `.env` when opening the Control UI.
- Production secrets have a recovery window. If destroyed, names may not be immediately reusable.

## Mattermost Setup And Functionality

Mattermost is managed by the Mattermost Operator using `apps/mattermost/mattermost.yaml`.

Current settings:

- Image: `mattermost/mattermost-team-edition`
- Version: `10.11.14`
- Ingress host: `${DOMAIN}`
- TLS issuer: `letsencrypt-prod`
- Database: CNPG through `mattermost-db-credentials`
- File storage: Terraform-managed S3 bucket through IAM instance profile
- User access tokens enabled for the OpenClaw bot token
- Bot account creation enabled for `openclaw-bot`
- WebSocket nginx annotations are set for real-time updates
- Push notification test server is configured for Team Edition

Current verified behavior:

- Mattermost is reachable at `https://${DOMAIN}`.
- TLS can be issued once DNS points to the AWS NLB.
- The admin account can be used by `scripts/07-setup-openclaw.sh` to create/find `openclaw-bot`.
- The bot can be added to `town-square` or other configured channels.

## OpenClaw Bot Setup

OpenClaw manifests live under `apps/openclaw/`.

Current approach:

- Use Kustomize manifests in this repo, not the old third-party KubeClaw Helm chart.
- Use existing nginx-ingress, not Envoy Gateway.
- Expose OpenClaw Control UI at `https://openclaw.${DOMAIN}`.
- Use the public Mattermost URL `https://${DOMAIN}` for Mattermost API access.
- Keep Mattermost chat enabled through the bundled Mattermost channel plugin.

Current model settings:

```text
Primary:  google/gemini-2.5-flash-lite
Fallback: google/gemini-2.5-flash
```

Claude/Anthropic notes:

- Claude fallback is not active right now because the Anthropic API account has no credits.
- `ANTHROPIC_API_KEY` stays optional for future use.
- Gemini daily request quotas reset at midnight Pacific time, per Google project.

Current safety settings:

- `tools.profile` is `messaging`.
- `tools.exec.security` is `deny`.
- `tools.elevated.enabled` is `false`.
- OpenClaw sandbox mode is `off` in this Kubernetes deployment.

Why sandbox mode is off:

- The OpenClaw slim container does not include Docker.
- OpenClaw's Docker-based sandbox is only needed when sandboxing is enabled.
- With sandbox mode `non-main`, every Mattermost message failed before reaching Gemini with `spawn docker ENOENT`.
- For this phase, command execution remains denied, so chat works without granting shell access from Mattermost.

Bot interaction settings:

- DM policy is currently `pairing`.
- Use `scripts/08-manage-bot.sh` to list and approve pending pairings.
- After approving a pairing, DM conversations work.
- In channels, mention `@openclaw-bot` so the bot knows to respond.

Important OpenClaw fixes already applied:

- Replaced old KubeClaw/LiteLLM/Envoy manifests with `apps/openclaw/` Kustomize manifests.
- Used public `https://${DOMAIN}` for Mattermost API access to avoid OpenClaw SSRF blocking the internal Kubernetes service hostname.
- Added `gateway.controlUi.allowedOrigins` for `https://openclaw.${DOMAIN}`.
- Disabled native slash command registration for now.
- Switched model from Gemini Pro to Gemini Flash-Lite/Flash to avoid higher-cost/quota pressure.
- Disabled Docker sandbox mode because the slim image has no Docker runtime.
- Updated `AGENTS.md` prompt so the bot answers normal knowledge questions instead of claiming it can only use tools.

No slash commands for now:

- Native slash command registration failed with Mattermost API 403.
- This does not block normal DM/channel chat.
- Keep slash commands disabled until bot permissions and callback security are intentionally designed.

DNS and TLS notes:

- Create both DNS records in Cloudflare:

```text
${DOMAIN}           CNAME -> AWS NLB DNS name
openclaw.${DOMAIN}  CNAME -> AWS NLB DNS name
```

- For HTTP-01 challenges, DNS-only records are the least confusing during initial issuance.
- If Chrome shows HSTS/certificate errors, nginx may be serving its temporary fake certificate because cert-manager has not issued TLS yet.
- One issue encountered: CoreDNS cached `NXDOMAIN` for `openclaw.${DOMAIN}` after DNS was added. Restarting CoreDNS flushed the stale lookup and cert-manager issued the certificate.

## Successful Rebuild After Teardown

After a teardown, the intended rebuild path is:

1. Confirm `.env` has current non-secret settings and required secret values.
2. Confirm AWS credentials with `aws sts get-caller-identity`.
3. Run `bash bootstrap.sh`; Terraform state backend creation is automatic.
4. After Terraform outputs the NLB DNS name, create/update Cloudflare CNAME records for `${DOMAIN}` and `openclaw.${DOMAIN}`.
5. Watch Flux: `flux get kustomizations -A --watch`.
6. Watch Mattermost: `kubectl get pods -n mattermost --watch`.
7. Watch OpenClaw: `kubectl get pods -n openclaw --watch`.
8. Confirm TLS: `kubectl get certificates -A`.
9. Pair the Mattermost DM user if needed: `bash scripts/08-manage-bot.sh`.
10. Test Mattermost DM and channel mention.

Validation commands:

```bash
make validate
bash -n scripts/*.sh scripts/lib/*.sh bootstrap.sh teardown.sh
terraform fmt -check -recursive terraform
flux get kustomizations -A
kubectl get pods -A
```

## Important Errors And Fixes Logged So Far

Terraform:

- `force_destroy` variable in the S3 module failed because multiple arguments were placed in a single-line variable block. Fixed by making it a multi-line block.
- S3 lifecycle configuration warned about a missing `filter`/`prefix`. Fixed with `filter { prefix = "" }`.
- NLB target group names exceeded AWS's 32-character limit. Fixed by shortening names.
- Terraform S3 backend warned that `dynamodb_table` is deprecated. Fixed by moving environment backends to `use_lockfile = true`.

kubeadm:

- SSH can take several minutes after EC2 creation. The wait/retry loop is expected.
- Direct `scp` of `/tmp/kubeadm-join.sh` can fail due permissions. Fixed with sudo `cat` fallback.

Flux:

- Flux objects can be temporarily missing during bootstrap/rerun. Reconcile after components settle.
- `cluster-values` ConfigMap must exist early for postBuild substitutions.

Mattermost:

- Bot creation requires `MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION=true`.
- Bot access token creation requires `MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=true`.
- Channel messages require the bot to be in the channel and usually mentioned.

OpenClaw:

- Internal Mattermost service URL was blocked by OpenClaw SSRF protection. Use public `https://${DOMAIN}` for the Mattermost API in this phase.
- The old Envoy Gateway approach was removed because nginx-ingress already handles ingress.
- Native slash commands are intentionally disabled for now because registration needs additional Mattermost permission/callback design.
- Gemini Pro quota was exhausted. Switched to Gemini Flash-Lite primary and Gemini Flash fallback.
- Claude fallback failed because Anthropic has no API credits. Claude is not active in the current fallback chain.
- Sandbox mode `non-main` failed because Docker is not available in the OpenClaw slim container. Sandbox is off while exec tools remain denied.
- The first prompt caused over-refusal. Updated the agent prompt to answer normal knowledge questions from model knowledge.

DNS/TLS:

- `openclaw.${DOMAIN}` must exist before cert-manager can finish HTTP-01 issuance.
- If CoreDNS caches a missing record, cert-manager self-check can keep failing from inside the cluster. Restart CoreDNS to flush stale NXDOMAIN cache.

## Next Phases

Planned next work:

1. Multi-agent design
   - Create three dedicated OpenClaw agents:
     - HR
     - Engineering
     - Sales & Content
   - Decide per-agent prompts, allowed tools, Mattermost channel routing, and access policy.

2. Backups and restore
   - CNPG scheduled backups and restore drills.
   - S3 lifecycle/retention for Mattermost files.
   - OpenClaw PVC backup strategy.
   - Terraform state backup expectations.

3. CI/CD pipelines
   - GitHub Actions validation for shell syntax, Terraform fmt/validate, and Kustomize build.
   - Optional Flux reconcile checks.
   - Pull request gate before applying infrastructure changes.

4. Observability and monitoring
   - Metrics stack decision: kube-prometheus-stack or a lighter setup.
   - Alerting for pods, certificates, Flux failures, CNPG health, disk usage, and node health.
   - Centralized logs for Mattermost, OpenClaw, Flux, cert-manager, and CNPG.

5. OpenClaw hardening
   - Decide whether to keep sandbox off or add a real sandbox backend.
   - Add web/search only if needed and with clear policy.
   - Revisit slash commands only after Mattermost permissions and callback source restrictions are designed.
   - Consider Cloudflare WAF/rate limiting for `openclaw.${DOMAIN}`.

6. Production readiness
   - Resource requests/limits review.
   - Upgrade process for Mattermost, operators, OpenClaw, Kubernetes, and Terraform providers.
   - Disaster recovery runbook.
   - Cost review for EC2, NLB, S3, Secrets Manager, and model APIs.
