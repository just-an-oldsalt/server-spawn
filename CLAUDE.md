# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

**server-spawn** is an on-demand Minecraft Java server on AWS. It starts automatically when a player performs a DNS lookup and shuts down after a configurable idle period. No Makefile, test suite, or CI/CD pipeline exists — this is purely infrastructure-as-code with supporting Lambda/watchdog scripts.

## Deploying Infrastructure

All infrastructure lives in `tofu/` and is managed with OpenTofu (Terraform-compatible).

```bash
cd tofu
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your domain and settings

tofu init
tofu plan
tofu apply
```

## Viewing Logs

```bash
# Lambda (must use us-east-1 — Route53 query log constraint)
aws logs tail /aws/lambda/server-spawn --region us-east-1 --follow

# Watchdog and Minecraft on the running EC2 instance
ssh ec2-user@<ip>
journalctl -u minecraft-watchdog -f
journalctl -u minecraft -f
cat /var/log/user_data.log   # EC2 boot log
```

## Architecture

The trigger chain: **DNS lookup → Route53 query log → CloudWatch → Lambda → EC2 start → user_data.sh → watchdog**

**Dual-region constraint:** Route53 query logging only works with CloudWatch in `us-east-1`, so the Lambda function and its CloudWatch subscription filter are always deployed there, regardless of `var.aws_region`.

**Component responsibilities:**

| Component | File | Purpose |
|-----------|------|---------|
| Lambda | `lambda/start_server.py` | Triggered by CloudWatch subscription filter; starts EC2 instance |
| Bootstrap | `scripts/user_data.sh` | Runs on first EC2 boot; installs Java/Python, mounts EBS world volume, creates systemd services |
| Watchdog | `watchdog/watchdog.py` | Runs on EC2; updates Route53 A record with instance IP, polls player count, stops instance after idle threshold |
| Infrastructure | `tofu/*.tf` | All AWS resources |

**World data persistence:** A dedicated EBS volume (separate from root) is mounted at `/opt/minecraft/world` and has `prevent_destroy = true`. The EC2 instance has `ignore_changes = [user_data, ami]` to prevent replacement when the bootstrap script changes — only the EBS volume persists game data, not the instance.

**Key variables in `terraform.tfvars`:**
- `domain_name` — e.g. `mc.example.com`
- `hosted_zone_id` — leave empty to create a new Route53 zone
- `aws_region` — where EC2 and most resources live
- `inactivity_minutes` — idle time before auto-shutdown (default: 20)
- `spot_instance` — set `true` for cheaper spot pricing
- `minecraft_version` — `"latest"` or a specific version like `"1.20.4"`

**S3 artifacts bucket:** `watchdog.py` is uploaded to S3 by Terraform and downloaded by `user_data.sh` on EC2 boot. Changes to `watchdog.py` require `tofu apply` to re-upload.

**IAM is scoped to specific ARNs** — Lambda can only start the specific Minecraft EC2 instance; EC2 can only stop itself and update the specific Route53 record.
