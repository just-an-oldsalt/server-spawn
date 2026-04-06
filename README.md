# server-spawn

On-demand Minecraft Java server on AWS. The server starts automatically when a player does a DNS lookup and shuts itself down after a configurable idle period.

## How it works

```
Player DNS lookup → Route53 query log → CloudWatch → Lambda → EC2 starts
EC2 boot → watchdog.py → updates Route53 A record → server ready
No players for 20 min → watchdog stops the instance
```

World data lives on a separate EBS volume and persists between restarts.

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.6
- AWS credentials configured
- A domain name with nameservers pointed at Route53 (or an existing hosted zone)

## Deploy

```bash
cd tofu
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your domain and settings

tofu init
tofu plan
tofu apply
```

If you created a new Route53 hosted zone, point your domain's nameservers at the values in the `nameservers` output.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `domain_name` | — | Full domain, e.g. `mc.example.com` |
| `hosted_zone_id` | `""` | Existing zone ID, or leave empty to create one |
| `aws_region` | `eu-west-1` | Region for the EC2 instance |
| `instance_type` | `t3.medium` | EC2 instance type |
| `inactivity_minutes` | `20` | Minutes of zero players before shutdown |
| `minecraft_version` | `latest` | Server version, e.g. `1.20.4` |
| `spot_instance` | `false` | Use Spot pricing (cheaper, may be interrupted) |
| `minecraft_memory_mb` | `2048` | JVM heap size |

## Architecture decisions vs. doctorwho8035/minecraft-ondemand

| Area | Original | This repo |
|---|---|---|
| Compute | ECS Fargate | EC2 |
| Storage | EFS (network) | EBS (local) — no TPS lag |
| Watchdog | Bash script | Python — proper error handling |
| IAM | Wildcard `ecs:*` | Scoped to specific resource ARNs |
| Lambda validation | `os.environ.get()` (broken) | `os.environ[]` (raises on missing) |
| Edition | Java + Bedrock | Java only |

## Logs

```bash
# Lambda start events (Lambda runs in us-east-1 due to Route53 constraint)
aws logs tail /aws/lambda/server-spawn --region us-east-1 --follow

# Watchdog + Minecraft on the instance
ssh ec2-user@<ip>
journalctl -u minecraft-watchdog -f
journalctl -u minecraft -f

# user_data boot log
cat /var/log/user_data.log
```

## World backups

The world data EBS volume ID is in the `world_data_volume_id` output. Take manual snapshots or configure AWS Backup targeting that volume ID.
