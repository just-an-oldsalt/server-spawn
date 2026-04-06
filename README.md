# server-spawn

On-demand Minecraft Java server on AWS. The server starts automatically when a player does a DNS lookup and hibernates after a configurable idle period — you only pay for EC2 when someone is actually playing.

## How it works

```
Player DNS lookup → Route53 query log → CloudWatch → Lambda → EC2 resumes
EC2 boot → watchdog → updates Route53 A record with real IP → server ready
No players for N minutes → watchdog hibernates the instance
```

World data lives on a separate EBS volume and persists between restarts. Hibernation preserves the JVM state on the root volume so the server resumes in seconds rather than cold-booting.

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.6
- AWS account with credentials configured (`aws configure sso` recommended)
- A domain name — either fully managed by Route53, or with a subdomain delegated to Route53 (see [DNS setup](#dns-setup) below)

## Deploy

```bash
cd tofu
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set domain_name and availability_zone

tofu init
tofu plan
tofu apply
```

## DNS setup

Route53 must handle DNS for the Minecraft subdomain — this is what triggers the Lambda on lookup.

**If your domain is at Cloudflare (or another registrar):** delegate just the subdomain to Route53 rather than moving the whole domain. After `tofu apply`, take the nameservers from the `nameservers` output and add four NS records in Cloudflare:

| Type | Name | Content |
|------|------|---------|
| NS | mc | ns-xxx.awsdns-xx.com |
| NS | mc | ns-xxx.awsdns-xx.net |
| NS | mc | ns-xxx.awsdns-xx.org |
| NS | mc | ns-xxx.awsdns-xx.co.uk |

Set proxy to **DNS only** (grey cloud). Verify with `dig NS mc.yourdomain.com`.

**If your domain is already in Route53:** set `hosted_zone_id` in `terraform.tfvars` to your existing zone ID and leave `domain_name` as the full subdomain (e.g. `mc.example.com`).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `domain_name` | — | Full domain players connect to, e.g. `mc.example.com` |
| `availability_zone` | — | AZ for EC2 and EBS volume — must match. Check your EBS volume if migrating |
| `aws_region` | `eu-west-1` | Region for EC2 and most resources |
| `hosted_zone_id` | `""` | Existing Route53 zone ID, or leave empty to create a new zone |
| `instance_type` | `t3.medium` | EC2 instance type — `m7i.large` recommended for 10+ players |
| `minecraft_version` | `latest` | Server version, e.g. `1.21.4`. Pin this to avoid Java version surprises |
| `minecraft_memory_mb` | `2048` | JVM heap size in MB |
| `inactivity_minutes` | `20` | Minutes of zero players before the server hibernates |
| `root_volume_size_gb` | `30` | Root EBS volume size — must be >= 30GB and large enough to hold instance RAM for hibernation |
| `data_volume_size_gb` | `10` | World data EBS volume size |
| `hibernate` | `true` | Hibernate on idle shutdown for fast resume. Cannot be combined with `spot_instance` |
| `spot_instance` | `false` | Use Spot pricing — cheaper but may be interrupted. Disables hibernation |
| `key_name` | `""` | EC2 key pair name for SSH access. Leave empty to disable SSH |

## Instance sizing

Minecraft's main game loop is largely single-threaded so clock speed matters more than core count. `t3` instances are burstable and will throttle under sustained load from multiple players.

| Players | Recommended | RAM | Notes |
|---------|-------------|-----|-------|
| 1–4 | `t3.medium` | 4GB | Fine for light use, may burst |
| 5–10 | `m7i.large` | 8GB | Consistent performance, no throttling |
| 10+ | `c7i.xlarge` | 16GB | Compute-optimised, highest clock speed |

## In-game commands

Players type these in normal chat (not as `/` commands):

| Command | Effect |
|---------|--------|
| `!shutdown` | Broadcasts a 30-second countdown then hibernates the server |
| `!extend` | Cancels a pending shutdown and adds 1 hour to the idle timer |

The watchdog also broadcasts warnings at **5 minutes** and **1 minute** before an idle shutdown.

## SSH access

Set `key_name` to an existing EC2 key pair name in `terraform.tfvars`. This opens port 22 in the security group and attaches the key pair to the instance.

```bash
ssh -i ~/.ssh/your-key.pem ec2-user@mc.yourdomain.com
```

## Logs

```bash
# Lambda start events — Lambda runs in us-east-1 due to Route53 constraint
aws logs tail /aws/lambda/server-spawn --region us-east-1 --follow

# Watchdog and Minecraft on the instance
ssh ec2-user@<ip>
journalctl -u minecraft-watchdog -f
journalctl -u minecraft -f

# Boot log (user_data.sh output)
cat /var/log/user_data.log
```

## World backups

The world data EBS volume ID is in the `world_data_volume_id` output. The volume has `prevent_destroy = true` so it won't be accidentally deleted by `tofu destroy`. For disaster recovery, take manual snapshots or configure AWS Backup targeting that volume ID.

## Replacing the EC2 instance

Some changes (instance type, key pair, hibernation) are immutable and require instance replacement. The world data volume is unaffected.

```bash
cd tofu
tofu taint aws_instance.minecraft
tofu apply
```
