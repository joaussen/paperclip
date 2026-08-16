#!/usr/bin/env bash
# One-shot budget Paperclip deployment on a single Azure VM.
#
# Provisions: a dedicated resource group, network security group, static
# public IP, and one Ubuntu 24.04 VM that boots the docker/vm compose stack
# (Caddy + server + Postgres) via cloud-init. See docs/deploy/azure-vm.md for
# the full guide and teardown.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-ant-... ./scripts/azure/deploy-vm.sh \
#     --location westeurope --domain paperclip.example.com --acme-email you@example.com
#
# With no --domain, the VM is reachable at https://<public-ip>.sslip.io with a
# self-signed certificate (browser trust warning, fine for evaluation).
#
# Requires: az CLI (logged in), openssl, curl, base64.
set -euo pipefail

NAME="paperclip"
RESOURCE_GROUP=""
LOCATION="westeurope"
VM_SIZE="Standard_B2s" # 2 vCPU / 4 GiB burstable; Standard_B2pls_v2 (ARM) is ~20% cheaper
DISK_SIZE_GB=64
ADMIN_USER="azureuser"
DOMAIN=""
ACME_EMAIL=""
SSH_CIDR=""
MANAGED_DB=false
DB_SKU="Standard_B1ms" # 1 vCPU / 2 GiB burstable
DB_STORAGE_GB=32

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  --name NAME            Resource name prefix and VM name (default: paperclip)
  --resource-group NAME  Resource group to use (default: same as --name;
                         created if missing — teardown is deleting this group)
  --location LOCATION    Azure region (default: westeurope)
  --vm-size SIZE         VM size (default: Standard_B2s; ARM sizes like
                         Standard_B2pls_v2 are detected automatically)
  --disk-size GB         OS disk size, Standard SSD (default: 64)
  --domain DOMAIN        Hostname you control; you must point an A record at
                         the printed public IP (default: <public-ip>.sslip.io)
  --acme-email EMAIL     ACME contact for Let's Encrypt when --domain is set
                         (default: admin@DOMAIN)
  --ssh-cidr CIDR        CIDR allowed to SSH (default: your current IP /32)
  --managed-db           Use Azure Database for PostgreSQL Flexible Server
                         (managed backups/PITR, patching) instead of the
                         Postgres container on the VM. Adds ~\$19/mo.
  --db-sku SKU           Flexible Server compute (default: Standard_B1ms)
  --db-storage-gb GB     Flexible Server storage (default: 32)
  -h, --help             Show this help

Environment passthrough into the server (all optional at deploy time):
  ANTHROPIC_API_KEY, OPENAI_API_KEY, GITHUB_TOKEN
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --vm-size) VM_SIZE="$2"; shift 2 ;;
    --disk-size) DISK_SIZE_GB="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --ssh-cidr) SSH_CIDR="$2"; shift 2 ;;
    --managed-db) MANAGED_DB=true; shift ;;
    --db-sku) DB_SKU="$2"; shift 2 ;;
    --db-storage-gb) DB_STORAGE_GB="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done
RESOURCE_GROUP="${RESOURCE_GROUP:-$NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="$SCRIPT_DIR/../../docker/vm"

command -v az >/dev/null || { echo "az CLI not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
az account show >/dev/null || { echo "az CLI is not logged in (run: az login)" >&2; exit 1; }

b64() { base64 <"$1" | tr -d '\n'; }
b64_str() { printf '%s' "$1" | base64 | tr -d '\n'; }

DB_MODE_LABEL="postgres container on the VM"
[[ "$MANAGED_DB" == true ]] && DB_MODE_LABEL="managed Flexible Server ($DB_SKU)"
echo "==> Deploying '$NAME' ($VM_SIZE, ${DISK_SIZE_GB} GiB Standard SSD, db: ${DB_MODE_LABEL}) in $LOCATION (resource group: $RESOURCE_GROUP)"

# ── Image: Ubuntu 24.04 LTS, arch derived from the VM size ──────────────────
# Azure ARM (Cobalt/Ampere) sizes carry a 'p' after the family digits, e.g.
# Standard_B2pls_v2, Standard_D2ps_v5.
if [[ "$VM_SIZE" =~ ^Standard_[A-Z]+[0-9]+p ]]; then
  IMAGE="Canonical:ubuntu-24_04-lts:server-arm64:latest"
else
  IMAGE="Canonical:ubuntu-24_04-lts:server:latest"
fi
echo "==> Image: $IMAGE"

# ── Resource group (dedicated: teardown = delete the group) ─────────────────
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# ── Static public IP (reused across re-runs) ────────────────────────────────
IP_NAME="${NAME}-ip"
if ! az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$IP_NAME" --output none 2>/dev/null; then
  az network public-ip create --resource-group "$RESOURCE_GROUP" --name "$IP_NAME" \
    --sku Standard --allocation-method Static --version IPv4 --output none
fi
PUBLIC_IP=$(az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$IP_NAME" \
  --query ipAddress --output tsv)
echo "==> Public IP: $PUBLIC_IP"

# ── Network security group: 80/443 open, SSH scoped ─────────────────────────
NSG_NAME="${NAME}-nsg"
if ! az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" --output none 2>/dev/null; then
  [[ -n "$SSH_CIDR" ]] || SSH_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
  az network nsg create --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" --output none
  az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --name allow-https --priority 100 --access Allow --protocol Tcp --direction Inbound \
    --destination-port-ranges 443 --source-address-prefixes Internet --output none
  az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --name allow-http3 --priority 110 --access Allow --protocol Udp --direction Inbound \
    --destination-port-ranges 443 --source-address-prefixes Internet --output none
  az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --name allow-http --priority 120 --access Allow --protocol Tcp --direction Inbound \
    --destination-port-ranges 80 --source-address-prefixes Internet --output none
  az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --name allow-ssh --priority 130 --access Allow --protocol Tcp --direction Inbound \
    --destination-port-ranges 22 --source-address-prefixes "$SSH_CIDR" --output none
  echo "==> Security group $NSG_NAME created (SSH allowed from ${SSH_CIDR})"
else
  echo "==> Reusing security group $NSG_NAME"
fi

# ── TLS mode and hostname ────────────────────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
  CADDY_TLS_MODE="${ACME_EMAIL:-admin@${DOMAIN}}"
else
  DOMAIN="${PUBLIC_IP}.sslip.io"
  CADDY_TLS_MODE="internal"
  echo "==> No --domain given: using ${DOMAIN} with a self-signed certificate"
fi

# ── Managed database (optional): Azure Database for PostgreSQL Flexible ─────
DB_LINES="COMPOSE_PROFILES=local-db"
DB_SERVER=""
if [[ "$MANAGED_DB" == true ]]; then
  # Flexible Server password policy needs 3+ character classes; the prefix
  # keeps the hex tail compliant while staying URL-safe.
  DB_PASSWORD="Pp1!$(openssl rand -hex 24)"
  DB_SERVER=$(az postgres flexible-server list --resource-group "$RESOURCE_GROUP" \
    --query "[?starts_with(name, '${NAME}-db')].name | [0]" --output tsv)
  if [[ -z "$DB_SERVER" ]]; then
    DB_SERVER="${NAME}-db-$(openssl rand -hex 3)"
    echo "==> Creating managed Postgres $DB_SERVER ($DB_SKU, ${DB_STORAGE_GB} GiB) — takes ~5 min..."
    az postgres flexible-server create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$DB_SERVER" \
      --location "$LOCATION" \
      --tier Burstable \
      --sku-name "$DB_SKU" \
      --storage-size "$DB_STORAGE_GB" \
      --version 17 \
      --admin-user paperclip \
      --admin-password "$DB_PASSWORD" \
      --public-access "$PUBLIC_IP" \
      --yes --output none
  else
    echo "==> Reusing managed Postgres $DB_SERVER (resetting admin password)"
    az postgres flexible-server update --resource-group "$RESOURCE_GROUP" \
      --name "$DB_SERVER" --admin-password "$DB_PASSWORD" --output none
    az postgres flexible-server firewall-rule create --resource-group "$RESOURCE_GROUP" \
      --server-name "$DB_SERVER" --name allow-paperclip-vm \
      --start-ip-address "$PUBLIC_IP" --end-ip-address "$PUBLIC_IP" --output none
  fi
  # Azure blocks CREATE EXTENSION until the extension is allow-listed on the
  # server; the Paperclip migrations use pg_trgm and fuzzystrmatch.
  az postgres flexible-server parameter set --resource-group "$RESOURCE_GROUP" \
    --server-name "$DB_SERVER" --name azure.extensions \
    --value PG_TRGM,FUZZYSTRMATCH --output none
  # Ensure the application database exists (ARM PUT — safe if it already does).
  az postgres flexible-server db create --resource-group "$RESOURCE_GROUP" \
    --server-name "$DB_SERVER" --name paperclip --output none
  DB_FQDN=$(az postgres flexible-server show --resource-group "$RESOURCE_GROUP" \
    --name "$DB_SERVER" --query fullyQualifiedDomainName --output tsv)
  DB_LINES="COMPOSE_PROFILES=
DATABASE_URL=postgres://paperclip:${DB_PASSWORD}@${DB_FQDN}:5432/paperclip?sslmode=require"
  echo "==> Managed Postgres ready at $DB_FQDN (firewall: VM IP only)"
fi

# ── Secrets and server .env ──────────────────────────────────────────────────
POSTGRES_PASSWORD=$(openssl rand -hex 32)
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
TOOL_SIGNING_SECRET=$(openssl rand -hex 32)

ENV_CONTENT=$(cat <<EOF
PAPERCLIP_DOMAIN=${DOMAIN}
CADDY_TLS_MODE=${CADDY_TLS_MODE}
PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip:latest
${DB_LINES}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=${TOOL_SIGNING_SECRET}
PAPERCLIP_AUTH_DISABLE_SIGN_UP=false
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
EOF
)

USER_DATA_FILE=$(mktemp)
trap 'rm -f "$USER_DATA_FILE"' EXIT
sed -e "s|__DOCKER_COMPOSE_B64__|$(b64 "$VM_DIR/docker-compose.yml")|" \
    -e "s|__CADDYFILE_B64__|$(b64 "$VM_DIR/Caddyfile")|" \
    -e "s|__ENV_B64__|$(b64_str "$ENV_CONTENT")|" \
    "$VM_DIR/cloud-init.yaml" > "$USER_DATA_FILE"

# ── Launch ───────────────────────────────────────────────────────────────────
echo "==> Creating VM (this takes a minute or two)..."
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NAME" \
  --image "$IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --public-ip-address "$IP_NAME" \
  --nsg "$NSG_NAME" \
  --os-disk-size-gb "$DISK_SIZE_GB" \
  --storage-sku StandardSSD_LRS \
  --custom-data "$USER_DATA_FILE" \
  --tags app=paperclip \
  --output none
echo "==> VM running; cloud-init is bringing the stack up"

# ── Summary ──────────────────────────────────────────────────────────────────
INFO_FILE="${NAME}-deploy-info.txt"
cat > "$INFO_FILE" <<EOF
Paperclip deployment ($(date -u +%Y-%m-%dT%H:%M:%SZ))
  URL:            https://${DOMAIN}
  Public IP:      ${PUBLIC_IP}
  VM:             ${NAME} (${VM_SIZE}, ${LOCATION})
  Resource group: ${RESOURCE_GROUP}
  Database:       ${DB_SERVER:-postgres container on the VM}
  SSH:            ssh ${ADMIN_USER}@${PUBLIC_IP}
  Server env:     /opt/paperclip/.env on the VM (secrets live there)
  Teardown:       az group delete --name ${RESOURCE_GROUP}
EOF
chmod 600 "$INFO_FILE"

cat <<EOF

Done. Summary written to ${INFO_FILE}.

  URL:  https://${DOMAIN}
  SSH:  ssh ${ADMIN_USER}@${PUBLIC_IP}

Next steps:
  1. First boot takes ~3-5 minutes (cloud-init installs Docker and pulls the
     image). Then check: curl -k https://${DOMAIN}/api/health
EOF
if [[ "$CADDY_TLS_MODE" != "internal" ]]; then
  cat <<EOF
  2. Create a DNS A record NOW: ${DOMAIN} -> ${PUBLIC_IP}
     (Caddy obtains the Let's Encrypt certificate once DNS resolves.)
EOF
fi
cat <<EOF
  3. Open https://${DOMAIN} and sign up — the FIRST account becomes admin.
  4. Then disable public sign-up: SSH in and run
       sudo sed -i 's/^PAPERCLIP_AUTH_DISABLE_SIGN_UP=.*/PAPERCLIP_AUTH_DISABLE_SIGN_UP=true/' /opt/paperclip/.env
       cd /opt/paperclip && sudo docker compose up -d
  5. If you didn't pass API keys, add ANTHROPIC_API_KEY / OPENAI_API_KEY to
     /opt/paperclip/.env the same way.
EOF
