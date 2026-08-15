#!/usr/bin/env bash
# One-shot budget Paperclip deployment on a single EC2 instance.
#
# Provisions: security group, key pair, Elastic IP, and one Ubuntu 24.04
# instance that boots the docker/vm compose stack (Caddy + server + Postgres)
# via cloud-init. See docs/deploy/aws-ec2.md for the full guide and teardown.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-ant-... ./scripts/aws/deploy-ec2.sh \
#     --region eu-west-1 --domain paperclip.example.com --acme-email you@example.com
#
# With no --domain, the instance is reachable at https://<elastic-ip>.sslip.io
# with a self-signed certificate (browser trust warning, fine for evaluation).
#
# Requires: aws CLI v2 (authenticated), openssl, curl, base64.
set -euo pipefail

NAME="paperclip"
REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="t4g.medium" # 2 vCPU / 4 GiB Graviton — the image is multi-arch
VOLUME_SIZE_GB=64
DOMAIN=""
ACME_EMAIL=""
KEY_NAME=""
SSH_CIDR=""

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  --name NAME            Resource name prefix (default: paperclip)
  --region REGION        AWS region (default: \$AWS_REGION or us-east-1)
  --instance-type TYPE   EC2 instance type (default: t4g.medium)
  --volume-size GB       Root gp3 volume size (default: 64)
  --domain DOMAIN        Hostname you control; you must point an A record at
                         the printed Elastic IP (default: <elastic-ip>.sslip.io)
  --acme-email EMAIL     ACME contact for Let's Encrypt when --domain is set
                         (default: admin@DOMAIN)
  --key-name NAME        Existing EC2 key pair to use (default: create one)
  --ssh-cidr CIDR        CIDR allowed to SSH (default: your current IP /32)
  -h, --help             Show this help

Environment passthrough into the server (all optional at deploy time):
  ANTHROPIC_API_KEY, OPENAI_API_KEY, GITHUB_TOKEN
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --volume-size) VOLUME_SIZE_GB="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --key-name) KEY_NAME="$2"; shift 2 ;;
    --ssh-cidr) SSH_CIDR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="$SCRIPT_DIR/../../docker/vm"
AWS=(aws --region "$REGION")

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
"${AWS[@]}" sts get-caller-identity >/dev/null || { echo "aws CLI is not authenticated" >&2; exit 1; }

b64() { base64 <"$1" | tr -d '\n'; }
b64_str() { printf '%s' "$1" | base64 | tr -d '\n'; }

echo "==> Deploying '$NAME' ($INSTANCE_TYPE, ${VOLUME_SIZE_GB} GiB gp3) in $REGION"

# ── AMI: latest Ubuntu 24.04 LTS for the instance architecture ──────────────
FAMILY="${INSTANCE_TYPE%%.*}"
case "$FAMILY" in
  *g|*gd|*gn|*ge) SSM_ARCH="arm64" ;; # Graviton families end in g / gd / gn / ge
  *) SSM_ARCH="amd64" ;;
esac
AMI_ID=$("${AWS[@]}" ssm get-parameters \
  --names "/aws/service/canonical/ubuntu/server/24.04/stable/current/${SSM_ARCH}/hvm/ebs-gp3/ami-id" \
  --query 'Parameters[0].Value' --output text)
echo "==> AMI: $AMI_ID (ubuntu-24.04 $SSM_ARCH)"

# ── Networking: default VPC, a default subnet, one security group ────────────
VPC_ID=$("${AWS[@]}" ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
[[ "$VPC_ID" != "None" ]] || { echo "No default VPC in $REGION; create one or adapt the script" >&2; exit 1; }
SUBNET_ID=$("${AWS[@]}" ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)

SG_ID=$("${AWS[@]}" ec2 describe-security-groups \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="${NAME}-vm" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG_ID" == "None" ]]; then
  SG_ID=$("${AWS[@]}" ec2 create-security-group \
    --group-name "${NAME}-vm" --description "Paperclip single-VM" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  [[ -n "$SSH_CIDR" ]] || SSH_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
  "${AWS[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${SSH_CIDR}}]" >/dev/null
  echo "==> Security group $SG_ID created (SSH allowed from ${SSH_CIDR})"
else
  echo "==> Reusing security group $SG_ID"
fi

# ── Key pair ─────────────────────────────────────────────────────────────────
if [[ -z "$KEY_NAME" ]]; then
  KEY_NAME="${NAME}-key"
  PEM_PATH="$HOME/.ssh/${KEY_NAME}.pem"
  if ! "${AWS[@]}" ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    mkdir -p "$HOME/.ssh"
    "${AWS[@]}" ec2 create-key-pair --key-name "$KEY_NAME" \
      --query 'KeyMaterial' --output text > "$PEM_PATH"
    chmod 400 "$PEM_PATH"
    echo "==> Key pair created; private key saved to $PEM_PATH"
  elif [[ ! -f "$PEM_PATH" ]]; then
    echo "Key pair $KEY_NAME exists in AWS but $PEM_PATH is missing locally." >&2
    echo "Pass --key-name <a key you have>, or delete the AWS key pair and re-run." >&2
    exit 1
  fi
fi

# ── Elastic IP (reused across re-runs via Name tag) ──────────────────────────
ALLOC_ID=$("${AWS[@]}" ec2 describe-addresses \
  --filters Name=tag:Name,Values="$NAME" \
  --query 'Addresses[0].AllocationId' --output text)
if [[ "$ALLOC_ID" == "None" ]]; then
  ALLOC_ID=$("${AWS[@]}" ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}}]" \
    --query 'AllocationId' --output text)
fi
PUBLIC_IP=$("${AWS[@]}" ec2 describe-addresses --allocation-ids "$ALLOC_ID" \
  --query 'Addresses[0].PublicIp' --output text)
echo "==> Elastic IP: $PUBLIC_IP"

# ── TLS mode and hostname ────────────────────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
  CADDY_TLS_MODE="${ACME_EMAIL:-admin@${DOMAIN}}"
else
  DOMAIN="${PUBLIC_IP}.sslip.io"
  CADDY_TLS_MODE="internal"
  echo "==> No --domain given: using ${DOMAIN} with a self-signed certificate"
fi

# ── Secrets and server .env ──────────────────────────────────────────────────
POSTGRES_PASSWORD=$(openssl rand -hex 32)
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
TOOL_SIGNING_SECRET=$(openssl rand -hex 32)

ENV_CONTENT=$(cat <<EOF
PAPERCLIP_DOMAIN=${DOMAIN}
CADDY_TLS_MODE=${CADDY_TLS_MODE}
PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip:latest
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
INSTANCE_ID=$("${AWS[@]}" ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${VOLUME_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true}" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
  --user-data "file://$USER_DATA_FILE" \
  --query 'Instances[0].InstanceId' --output text)
echo "==> Instance $INSTANCE_ID launching..."

"${AWS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"
"${AWS[@]}" ec2 associate-address --allocation-id "$ALLOC_ID" --instance-id "$INSTANCE_ID" >/dev/null
echo "==> Instance running; Elastic IP associated"

# ── Summary ──────────────────────────────────────────────────────────────────
INFO_FILE="${NAME}-deploy-info.txt"
cat > "$INFO_FILE" <<EOF
Paperclip deployment ($(date -u +%Y-%m-%dT%H:%M:%SZ))
  URL:          https://${DOMAIN}
  Elastic IP:   ${PUBLIC_IP}
  Instance:     ${INSTANCE_ID} (${INSTANCE_TYPE}, ${REGION})
  SSH:          ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}
  Server env:   /opt/paperclip/.env on the instance (secrets live there)
EOF
chmod 600 "$INFO_FILE"

cat <<EOF

Done. Summary written to ${INFO_FILE}.

  URL:  https://${DOMAIN}
  SSH:  ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}

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
