---
title: AWS EC2 (Budget)
summary: Run Paperclip 24/7 on a single EC2 instance for ~$33/month
---

The cheapest robust way to run Paperclip 24/7 on AWS: one small EC2 instance running the Docker Compose stack from `docker/vm/` — Caddy (automatic HTTPS), the Paperclip server, and Postgres 17 — all on one machine.

Compare with the [ECS Fargate guide](aws-ecs.md) (~$110/mo) which buys you managed compute, a load balancer, managed Postgres, and easy horizontal scaling. For a single-team instance that just needs to be on 24/7, the single-VM setup is about a third of the price:

| | EC2 single VM (this guide) | ECS Fargate |
|---|---|---|
| Monthly cost | **~$33** (~$24 reserved) | ~$110 |
| Postgres | Container on the VM | Managed RDS |
| TLS | Caddy + Let's Encrypt | ALB + ACM |
| Scaling | Resize the instance | Task count / size |
| Ops model | One VM to keep healthy | Fully managed |

The instance defaults to `t4g.medium` (2 vCPU, 4 GiB, Graviton — the Paperclip image is multi-arch), which comfortably runs the server, Postgres, and a few concurrent local agents.

## Prerequisites

- AWS CLI v2 authenticated with permissions for EC2 and SSM
- `openssl` and `curl` locally
- Optional but recommended: a domain (or subdomain) you control, for a browser-trusted certificate. Without one the deploy falls back to `<elastic-ip>.sslip.io` with a self-signed cert (browser warning; fine for evaluation).

## Option A: One-Command Deploy

From the repo root:

```bash
ANTHROPIC_API_KEY=sk-ant-... \
./scripts/aws/deploy-ec2.sh \
  --region eu-west-1 \
  --domain paperclip.example.com \
  --acme-email you@example.com
```

The script provisions a security group (80/443 open, SSH restricted to your current IP), a key pair, an Elastic IP, and the instance itself; cloud-init installs Docker and starts the stack on first boot. It prints the URL, the SSH command, and post-deploy steps, and writes them to `paperclip-deploy-info.txt`.

Useful flags: `--instance-type` (default `t4g.medium`), `--volume-size` (default 64 GiB), `--name` (resource prefix), `--ssh-cidr`. Run with `--help` for all options. Omit `--domain` to use the sslip.io fallback.

Point your DNS **A record** at the printed Elastic IP right after the script finishes — Caddy obtains the Let's Encrypt certificate automatically once the name resolves.

## Option B: Manual Walkthrough

The script just automates the following. Set up shell variables:

```bash
export AWS_REGION=eu-west-1
export PAPERCLIP_DOMAIN=paperclip.example.com
```

**1. Security group** (default VPC) — allow 80/443 from anywhere, 22 from your IP:

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name paperclip-vm --description "Paperclip single-VM" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)

MY_IP=$(curl -fsS https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --ip-permissions \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32}]"
```

**2. Key pair and Elastic IP:**

```bash
aws ec2 create-key-pair --key-name paperclip-key \
  --query 'KeyMaterial' --output text > ~/.ssh/paperclip-key.pem
chmod 400 ~/.ssh/paperclip-key.pem

ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids $ALLOC_ID \
  --query 'Addresses[0].PublicIp' --output text)
```

**3. Prepare user data.** Fill in `docker/vm/paperclip.env.example` (generate secrets with `openssl rand -hex 32`, set `PAPERCLIP_DOMAIN`, set `CADDY_TLS_MODE` to your email for public certs) and save it as `/tmp/paperclip.env`. Then substitute the placeholders in the cloud-init template:

```bash
sed -e "s|__DOCKER_COMPOSE_B64__|$(base64 -w0 docker/vm/docker-compose.yml)|" \
    -e "s|__CADDYFILE_B64__|$(base64 -w0 docker/vm/Caddyfile)|" \
    -e "s|__ENV_B64__|$(base64 -w0 /tmp/paperclip.env)|" \
    docker/vm/cloud-init.yaml > /tmp/user-data.yaml
```

**4. Launch** (latest Ubuntu 24.04 arm64 via SSM):

```bash
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id \
  --query 'Parameters[0].Value' --output text)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t4g.medium \
  --key-name paperclip-key \
  --security-group-ids $SG_ID \
  --associate-public-ip-address \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=64,VolumeType=gp3,DeleteOnTermination=true}" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=paperclip}]" \
  --user-data file:///tmp/user-data.yaml \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID
aws ec2 associate-address --allocation-id $ALLOC_ID --instance-id $INSTANCE_ID
```

**5. DNS:** create an A record for `$PAPERCLIP_DOMAIN` pointing at `$PUBLIC_IP`.

## Verify

First boot takes about 3–5 minutes (Docker install + image pull).

```bash
# Health endpoint (add -k if using the self-signed sslip.io fallback)
curl -sf https://$PAPERCLIP_DOMAIN/api/health

# From the instance
ssh -i ~/.ssh/paperclip-key.pem ubuntu@$PUBLIC_IP
sudo docker compose -f /opt/paperclip/docker-compose.yml ps
sudo docker compose -f /opt/paperclip/docker-compose.yml logs -f server
sudo cat /var/log/cloud-init-output.log   # if something didn't come up
```

**Healthy indicators:**
- All three services `running`, server healthcheck `healthy`
- Server logs show `plugin job coordinator started` and `plugin-loader: loadAll complete`
- `/api/health` returns 200

## Post-Deploy Security Hardening

The **first account to sign up gets the admin role** — sign up immediately, then disable public sign-up:

```bash
ssh -i ~/.ssh/paperclip-key.pem ubuntu@$PUBLIC_IP
sudo sed -i 's/^PAPERCLIP_AUTH_DISABLE_SIGN_UP=.*/PAPERCLIP_AUTH_DISABLE_SIGN_UP=true/' /opt/paperclip/.env
cd /opt/paperclip && sudo docker compose up -d
```

Use the invite flow to grant access to additional users afterwards. Also consider:

- Keep the SSH rule scoped to your IP (the script does this by default)
- Ubuntu's `unattended-upgrades` handles OS security patches automatically
- Secrets live in `/opt/paperclip/.env` (mode 600). Note that anything passed through cloud-init user data is also readable from the instance metadata service by root on the VM itself; rotate secrets in `.env` if that bothers you (`docker compose up -d` applies changes)

## Deploying Updates

```bash
ssh -i ~/.ssh/paperclip-key.pem ubuntu@$PUBLIC_IP
cd /opt/paperclip && sudo docker compose pull && sudo docker compose up -d
```

`latest` tracks stable releases. Pin `PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip:<version>` in `.env` for reproducible deploys (or `:canary` for master builds). Expect a few seconds of downtime while the server container restarts.

## Backups

Nightly Postgres dumps with 7-day rotation, kept on the instance:

```bash
ssh -i ~/.ssh/paperclip-key.pem ubuntu@$PUBLIC_IP
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

For off-instance backups, snapshot the EBS volume (`aws ec2 create-snapshot`) or schedule it with Amazon Data Lifecycle Manager; agent workspaces and uploads live in the `paperclip-data` volume on the same disk.

Alternatively, move the database to managed Postgres (e.g. RDS `db.t4g.micro`, ~$15/mo extra) for automated backups and point-in-time restore: set `DATABASE_URL=postgres://...?sslmode=require` and `COMPOSE_PROFILES=` (empty) in `/opt/paperclip/.env`, then `docker compose up -d` — the bundled Postgres container stays off. The [Azure guide](azure-vm.md) automates this pattern with its `--managed-db` flag.

## Resizing

If agents feel CPU/RAM constrained (e.g. many concurrent local agents), move up a size (`t4g.large` = 2 vCPU / 8 GiB, ~2x the instance cost). The Elastic IP and data survive:

```bash
aws ec2 stop-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID
aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID \
  --instance-type '{"Value": "t4g.large"}'
aws ec2 start-instances --instance-ids $INSTANCE_ID
```

## Teardown

```bash
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID   # volume auto-deletes
aws ec2 release-address --allocation-id $ALLOC_ID
aws ec2 delete-security-group --group-id $SG_ID
aws ec2 delete-key-pair --key-name paperclip-key
```

## Cost Reference

On-demand, us-east-1 (eu-west-1 in parentheses), August 2026 pricing:

| Item | Config | Monthly |
|------|--------|---------|
| EC2 | t4g.medium, 2 vCPU / 4 GiB, 24/7 | ~$24.50 (~$26.90) |
| EBS | 64 GiB gp3 | ~$5.10 (~$5.60) |
| Public IPv4 | Elastic IP | ~$3.65 |
| Data transfer | first 100 GB/mo out | $0 |
| **Total** | | **~$33/mo (~$36/mo)** |

Ways to pay less:

- **1-year no-upfront reservation / savings plan** on the instance: t4g.medium drops to ~$15.40/mo → **~$24/mo total**. Worth it the moment you know it's staying up 24/7.
- **t4g.small** (2 GiB + the 2 GiB swap the cloud-init sets up): ~$21/mo total. Fine for evaluation or a single light-use agent team; upgrade with the resize steps above when it gets tight.

The `docker/vm/` stack is cloud-agnostic — the same compose file, Caddyfile, and cloud-init template work on any Ubuntu VM; only the provisioning commands differ. See the [Azure VM guide](azure-vm.md) for the Azure twin of this setup (~$36-44/mo, `scripts/azure/deploy-vm.sh`).
