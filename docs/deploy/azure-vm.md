---
title: Azure VM (Budget)
summary: Run Paperclip 24/7 on a single Azure VM for ~$36-44/month
---

The cheapest robust way to run Paperclip 24/7 on Azure: one small VM running the Docker Compose stack from `docker/vm/` — Caddy (automatic HTTPS), the Paperclip server, and Postgres 17 — all on one machine. It is the Azure twin of the [AWS EC2 budget guide](aws-ec2.md) and uses the exact same compose stack and cloud-init template; only the provisioning differs.

Why a plain VM instead of Azure's managed options? For an always-on (no scale-to-zero) instance, Container Apps at 2 vCPU / 4 GiB plus a managed Postgres Flexible Server lands roughly at $60–150/mo depending on how active your agents keep the CPU, and App Service needs a separate managed database too. A burstable VM is a flat ~$36–44/mo, fits Paperclip's idle-mostly/bursty profile, and keeps Postgres and agent workspaces on fast local disk.

The default size is `Standard_B2s` (2 vCPU, 4 GiB, available in every region), which comfortably runs the server, Postgres, and a few concurrent local agents. `Standard_B2pls_v2` (ARM) is ~20% cheaper where available — the Paperclip image is multi-arch, and the deploy script picks the right OS image automatically.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) logged in (`az login`) with permission to create resource groups and VMs
- `openssl` and `curl` locally
- Optional but recommended: a domain (or subdomain) you control, for a browser-trusted certificate. Without one the deploy falls back to `<public-ip>.sslip.io` with a self-signed cert (browser warning; fine for evaluation).

> **Why not the free `<label>.<region>.cloudapp.azure.com` DNS name?** It isn't on the Public Suffix List, so every Azure customer shares one Let's Encrypt rate-limit bucket for it — public cert issuance is unreliable there. Use a domain you control for trusted certs, or the self-signed fallback for evaluation.

## Option A: One-Command Deploy

From the repo root:

```bash
ANTHROPIC_API_KEY=sk-ant-... \
./scripts/azure/deploy-vm.sh \
  --location westeurope \
  --domain paperclip.example.com \
  --acme-email you@example.com
```

The script provisions a dedicated resource group (`paperclip` — teardown is deleting it), a network security group (80/443 open, SSH restricted to your current IP), a static public IP, and the VM itself; cloud-init installs Docker and starts the stack on first boot. It prints the URL, the SSH command, and post-deploy steps, and writes them to `paperclip-deploy-info.txt`.

Useful flags: `--vm-size` (default `Standard_B2s`), `--disk-size` (default 64 GiB), `--name`, `--resource-group`, `--ssh-cidr`. Run with `--help` for all options. Omit `--domain` to use the sslip.io fallback.

**Recommended upgrade — managed database.** Add `--managed-db` to run Postgres on [Azure Database for PostgreSQL Flexible Server](https://learn.microsoft.com/azure/postgresql/flexible-server/) (`Standard_B1ms`, 32 GiB, Postgres 17) instead of a container on the VM:

```bash
./scripts/azure/deploy-vm.sh --location westeurope --managed-db \
  --domain paperclip.example.com --acme-email you@example.com
```

For ~$19/mo extra you get automated backups with 7-day point-in-time restore, patching, and storage autogrow — the database is the one piece of this stack where managed genuinely reduces risk. The script creates the server with public access restricted to the VM's static IP only, allow-lists the Postgres extensions the migrations need (`azure.extensions = PG_TRGM,FUZZYSTRMATCH` — Azure rejects `CREATE EXTENSION` otherwise), wires `DATABASE_URL` (with `sslmode=require`) into the server env, and disables the bundled Postgres container via compose profiles. Re-runs reuse the existing server (resetting its admin password to a fresh one). Provisioning adds ~5 minutes.

Point your DNS **A record** at the printed public IP right after the script finishes — Caddy obtains the Let's Encrypt certificate automatically once the name resolves.

## Option B: Manual Walkthrough

The script just automates the following.

**1. Resource group and static IP:**

```bash
export LOCATION=westeurope
az group create --name paperclip --location $LOCATION

az network public-ip create --resource-group paperclip --name paperclip-ip \
  --sku Standard --allocation-method Static --version IPv4
PUBLIC_IP=$(az network public-ip show --resource-group paperclip --name paperclip-ip \
  --query ipAddress --output tsv)
```

**2. Network security group** — allow 80/443 from anywhere, 22 from your IP:

```bash
az network nsg create --resource-group paperclip --name paperclip-nsg
MY_IP=$(curl -fsS https://checkip.amazonaws.com)

az network nsg rule create --resource-group paperclip --nsg-name paperclip-nsg \
  --name allow-https --priority 100 --protocol Tcp --destination-port-ranges 443 \
  --access Allow --direction Inbound --source-address-prefixes Internet
az network nsg rule create --resource-group paperclip --nsg-name paperclip-nsg \
  --name allow-http3 --priority 110 --protocol Udp --destination-port-ranges 443 \
  --access Allow --direction Inbound --source-address-prefixes Internet
az network nsg rule create --resource-group paperclip --nsg-name paperclip-nsg \
  --name allow-http --priority 120 --protocol Tcp --destination-port-ranges 80 \
  --access Allow --direction Inbound --source-address-prefixes Internet
az network nsg rule create --resource-group paperclip --nsg-name paperclip-nsg \
  --name allow-ssh --priority 130 --protocol Tcp --destination-port-ranges 22 \
  --access Allow --direction Inbound --source-address-prefixes ${MY_IP}/32
```

**3. Prepare custom data.** Fill in `docker/vm/paperclip.env.example` (generate secrets with `openssl rand -hex 32`, set `PAPERCLIP_DOMAIN`, set `CADDY_TLS_MODE` to your email for public certs) and save it as `/tmp/paperclip.env`. Then substitute the placeholders in the cloud-init template:

```bash
sed -e "s|__DOCKER_COMPOSE_B64__|$(base64 -w0 docker/vm/docker-compose.yml)|" \
    -e "s|__CADDYFILE_B64__|$(base64 -w0 docker/vm/Caddyfile)|" \
    -e "s|__ENV_B64__|$(base64 -w0 /tmp/paperclip.env)|" \
    docker/vm/cloud-init.yaml > /tmp/user-data.yaml
```

**4. Launch** (use image `Canonical:ubuntu-24_04-lts:server-arm64:latest` instead for ARM sizes like `Standard_B2pls_v2`):

```bash
az vm create \
  --resource-group paperclip \
  --name paperclip \
  --image Canonical:ubuntu-24_04-lts:server:latest \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-address paperclip-ip \
  --nsg paperclip-nsg \
  --os-disk-size-gb 64 \
  --storage-sku StandardSSD_LRS \
  --custom-data /tmp/user-data.yaml \
  --tags app=paperclip
```

**5. DNS:** create an A record for your domain pointing at `$PUBLIC_IP`.

## Verify

First boot takes about 3–5 minutes (Docker install + image pull).

```bash
# Health endpoint (add -k if using the self-signed sslip.io fallback)
curl -sf https://$PAPERCLIP_DOMAIN/api/health

# From the VM
ssh azureuser@$PUBLIC_IP
sudo docker compose -f /opt/paperclip/docker-compose.yml ps
sudo docker compose -f /opt/paperclip/docker-compose.yml logs -f server
sudo cat /var/log/cloud-init-output.log   # if something didn't come up
```

**Healthy indicators:**
- All three services `running`, server healthcheck `healthy`
- Server logs show `plugin job coordinator started` and `plugin-loader: loadAll complete`
- `/api/health` returns 200

**If `az vm create` is rejected before anything deploys** (often with an unhelpful CLI traceback): your subscription may simply not offer the chosen size in that region — common for `Standard_B2s` on sponsorship/partner-credit subscriptions. List what you can use and pick an equivalent (the `_v2` B-series are drop-in and often cheaper):

```bash
az vm list-skus --location westeurope --size Standard_B2 \
  --query "[].{name:name, restricted:length(restrictions)>\`0\`}" -o table
# then re-run with e.g. --vm-size Standard_B2als_v2
```

## Post-Deploy Security Hardening

The **first account to sign up gets the admin role** — sign up immediately, then disable public sign-up:

```bash
ssh azureuser@$PUBLIC_IP
sudo sed -i 's/^PAPERCLIP_AUTH_DISABLE_SIGN_UP=.*/PAPERCLIP_AUTH_DISABLE_SIGN_UP=true/' /opt/paperclip/.env
cd /opt/paperclip && sudo docker compose up -d
```

Use the invite flow to grant access to additional users afterwards. Also consider:

- Keep the SSH rule scoped to your IP (the script does this by default)
- Ubuntu's `unattended-upgrades` handles OS security patches automatically
- Secrets live in `/opt/paperclip/.env` (mode 600). Anything passed through cloud-init custom data is also readable from the instance metadata service by root on the VM itself; rotate secrets in `.env` if that bothers you (`docker compose up -d` applies changes)

## Cheaper Model Providers (Kimi, DeepSeek)

The Claude Code adapter honors `ANTHROPIC_BASE_URL`, so agents can run against any Anthropic-compatible API instead of Anthropic — at a fraction of the token price. In `/opt/paperclip/.env`, set the provider's API key as `ANTHROPIC_API_KEY` plus one of the blocks documented in `docker/vm/paperclip.env.example` (Kimi K2 via `https://api.moonshot.ai/anthropic`, DeepSeek via `https://api.deepseek.com/anthropic`, with `ANTHROPIC_MODEL` pinned accordingly), then `docker compose up -d`. The override is instance-wide: every Claude-adapter agent on the instance uses that endpoint. OpenAI-compatible-only providers can't use this path — wire those through the OpenCode adapter's custom provider config instead.

## Deploying Updates

```bash
ssh azureuser@$PUBLIC_IP
cd /opt/paperclip && sudo docker compose pull && sudo docker compose up -d
```

`latest` tracks stable releases. Pin `PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip:<version>` in `.env` for reproducible deploys (or `:canary` for master builds). Expect a few seconds of downtime while the server container restarts.

## Backups

**Managed-db deployments (`--managed-db`):** Flexible Server handles this — automated backups with 7-day point-in-time restore are on by default (extendable to 35 days). Nothing to set up for the database; only agent workspaces/uploads remain on the VM disk (snapshot it occasionally, see below).

**Local-db deployments:** nightly Postgres dumps with 7-day rotation, kept on the VM:

```bash
ssh azureuser@$PUBLIC_IP
sudo mkdir -p /opt/paperclip/backups
sudo tee /etc/cron.daily/paperclip-pgdump >/dev/null <<'EOF'
#!/bin/sh
cd /opt/paperclip && docker compose exec -T db \
  pg_dump -U paperclip paperclip | gzip \
  > "/opt/paperclip/backups/paperclip-$(date +%u).sql.gz"
EOF
sudo chmod +x /etc/cron.daily/paperclip-pgdump
```

Restore: `gunzip -c backups/paperclip-N.sql.gz | sudo docker compose exec -T db psql -U paperclip paperclip`

For off-VM backups, snapshot the OS disk (`az snapshot create`) or enable [Azure Backup](https://learn.microsoft.com/azure/backup/backup-azure-vms-first-look-arm) on the VM; agent workspaces and uploads live in the `paperclip-data` volume on the same disk.

## Resizing

If agents feel CPU/RAM constrained (e.g. many concurrent local agents), move up a size (`Standard_B2ms` = 2 vCPU / 8 GiB, ~2x the VM cost). The public IP and data survive; the resize reboots the VM:

```bash
az vm resize --resource-group paperclip --name paperclip --size Standard_B2ms
```

## Teardown

Everything lives in the dedicated resource group (including the Flexible Server if you used `--managed-db` — its backups are deleted with it, so take a final `pg_dump` first if the data matters):

```bash
az group delete --name paperclip --yes
```

## Cost Reference

Pay-as-you-go, West Europe (East US in parentheses), August 2026 pricing:

| Item | Config | Monthly |
|------|--------|---------|
| VM | Standard_B2s, 2 vCPU / 4 GiB, 24/7 | ~$35.00 (~$30.40) |
| OS disk | 64 GiB Standard SSD (E6) | ~$4.80 |
| Public IPv4 | Standard, static | ~$3.65 |
| Data transfer | first 100 GB/mo out | $0 |
| **Total** | | **~$43.50/mo (~$39/mo)** |

With `--managed-db`, add Azure Database for PostgreSQL Flexible Server:

| Item | Config | Monthly |
|------|--------|---------|
| Flexible Server | Standard_B1ms, 1 vCPU / 2 GiB | ~$14.55 |
| DB storage | 32 GiB | ~$4.40 |
| Backups | 7-day PITR within provisioned storage | $0 |
| **Total with managed db** | | **~$62/mo West Europe** |

Ways to pay less:

- **Standard_B2pls_v2** (ARM, 2 vCPU / 4 GiB): ~$28.00 (~$24.50) → **~$36.50/mo (~$33/mo)** total. Check regional availability; the deploy script handles the image switch automatically.
- **1-year Azure savings plan for compute** on the VM: B2s in West Europe drops to ~$26.60/mo → **~$35/mo total** (3-year: ~$19.30/mo → ~$27.70 total). Worth it the moment you know it's staying up 24/7. Note that B-series is covered by savings plans but not by reserved instances.

The `docker/vm/` stack is cloud-agnostic — see the [AWS EC2 budget guide](aws-ec2.md) for the same setup at ~$33/mo on AWS.
