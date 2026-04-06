#!/bin/bash
# user_data.sh — runs on EC2 boot.
# Installs Java + Minecraft server, installs the watchdog, and wires up systemd.
#
# Templated variables (filled by OpenTofu):
#   ${minecraft_version}   — e.g. "1.20.4" or "latest"
#   ${minecraft_memory_mb} — e.g. 2048
#   ${inactivity_minutes}  — e.g. 20
#   ${domain_name}         — e.g. mc.example.com
#   ${hosted_zone_id}      — Route53 zone ID
#   ${aws_region}          — e.g. eu-west-1
#   ${artifacts_bucket}    — S3 bucket holding watchdog.py

set -euo pipefail
exec > >(tee /var/log/user_data.log | logger -t user_data) 2>&1

echo "=== server-spawn user_data starting ==="

# ── System packages ───────────────────────────────────────────────────────────
dnf update -y
dnf install -y java-25-amazon-corretto-headless python3-pip || \
  dnf install -y java-21-amazon-corretto-headless python3-pip

# ── World data volume ─────────────────────────────────────────────────────────
WORLD_DEVICE=/dev/xvdf
WORLD_MOUNT=/opt/minecraft/world

mkdir -p "$WORLD_MOUNT"

# Format only if the volume has no filesystem yet
if ! blkid "$WORLD_DEVICE" &>/dev/null; then
  mkfs.ext4 "$WORLD_DEVICE"
fi

# Mount and persist via fstab
if ! grep -q "$WORLD_DEVICE" /etc/fstab; then
  echo "$WORLD_DEVICE $WORLD_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi
mount -a

# ── Minecraft server ──────────────────────────────────────────────────────────
MC_DIR=/opt/minecraft
MC_USER=minecraft
MC_VERSION="${minecraft_version}"

if ! id "$MC_USER" &>/dev/null; then
  useradd -r -s /bin/false -d "$MC_DIR" "$MC_USER"
fi

mkdir -p "$MC_DIR"
chown -R "$MC_USER:$MC_USER" "$MC_DIR"

# Resolve "latest" to the actual version number via Mojang API
if [ "$MC_VERSION" = "latest" ]; then
  MC_VERSION=$(curl -fsSL https://launchermeta.mojang.com/mc/game/version_manifest.json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['latest']['release'])")
  echo "Resolved latest Minecraft version: $MC_VERSION"
fi

MC_JAR="$MC_DIR/server-$MC_VERSION.jar"

if [ ! -f "$MC_JAR" ]; then
  MANIFEST_URL=$(curl -fsSL https://launchermeta.mojang.com/mc/game/version_manifest.json \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for v in d['versions']:
    if v['id'] == '$MC_VERSION':
        print(v['url'])
        break
")
  SERVER_URL=$(curl -fsSL "$MANIFEST_URL" \
    | python3 -c "import sys, json; d=json.load(sys.stdin); print(d['downloads']['server']['url'])")
  curl -fsSL -o "$MC_JAR" "$SERVER_URL"
  echo "Downloaded Minecraft server $MC_VERSION"
fi

echo "eula=true" > "$MC_DIR/eula.txt"
chown "$MC_USER:$MC_USER" "$MC_DIR/eula.txt"

# ── Watchdog ──────────────────────────────────────────────────────────────────
WATCHDOG_DIR=/opt/watchdog
mkdir -p "$WATCHDOG_DIR"

pip3 install boto3 mcstatus --quiet

# Fetch watchdog.py from S3 artifacts bucket
aws s3 cp "s3://${artifacts_bucket}/watchdog/watchdog.py" "$WATCHDOG_DIR/watchdog.py" \
  --region "${aws_region}"

chmod +x "$WATCHDOG_DIR/watchdog.py"

# ── Resolve instance ID via IMDSv2 ────────────────────────────────────────────
TOKEN=$(curl -fsSL -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
INSTANCE_ID=$(curl -fsSL -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "Instance ID: $INSTANCE_ID"

# ── Minecraft systemd service ─────────────────────────────────────────────────
cat > /etc/systemd/system/minecraft.service << EOF
[Unit]
Description=Minecraft Java Server
After=network.target local-fs.target

[Service]
User=$MC_USER
WorkingDirectory=$MC_DIR
ExecStart=/usr/bin/java \
  -Xms${minecraft_memory_mb}M \
  -Xmx${minecraft_memory_mb}M \
  -XX:+UseG1GC \
  -XX:+ParallelRefProcEnabled \
  -XX:MaxGCPauseMillis=200 \
  -jar $MC_JAR nogui
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ── Watchdog systemd service ──────────────────────────────────────────────────
cat > /etc/systemd/system/minecraft-watchdog.service << EOF
[Unit]
Description=Minecraft Server Watchdog
After=minecraft.service
Requires=minecraft.service

[Service]
Environment="INSTANCE_ID=$INSTANCE_ID"
Environment="HOSTED_ZONE_ID=${hosted_zone_id}"
Environment="DOMAIN_NAME=${domain_name}"
Environment="AWS_REGION=${aws_region}"
Environment="INACTIVITY_MINUTES=${inactivity_minutes}"
ExecStart=/usr/bin/python3 $WATCHDOG_DIR/watchdog.py
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ── Start services ────────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable minecraft.service minecraft-watchdog.service
systemctl start minecraft.service minecraft-watchdog.service

echo "=== server-spawn user_data complete ==="
