#!/bin/bash

set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

user_id=$(id -u)
if [[ "$user_id" -ne 0 ]]
then
	echo -e "${RED}Permission denied! Login as root${NC}"
	exit 1
fi

run_quietly() {
    local log_file
    log_file=$(mktemp)

    if "$@" >"$log_file" 2>&1; then
        rm -f "$log_file"
    else
        local status=$?
        cat "$log_file"
        rm -f "$log_file"
        return "$status"
    fi
}


configure_repositories() {
    local sources_dir="/etc/apt/sources.list.d"
    local backup_dir="/var/backups/ep4-apt-sources"

    echo -e "${BLUE}[INFO]${NC} Configuring Debian 13 repositories..."

    mkdir -p "$sources_dir" "$backup_dir"

    # Back up the existing repository configuration
    if [[ ! -e "$backup_dir/sources.list" ]]; then
        cp -a /etc/apt/sources.list "$backup_dir/sources.list" \
            2>/dev/null || true
    fi

    if [[ -e "$sources_dir/debian.sources" &&
          ! -e "$backup_dir/debian.sources" ]]; then
        cp -a "$sources_dir/debian.sources" "$backup_dir/debian.sources"
    fi

    # Disable other repository definition files
    local file
    for file in "$sources_dir"/*.list "$sources_dir"/*.sources; do
        [[ -e "$file" ]] || continue
        [[ "$file" == "$sources_dir/debian.sources" ]] && continue

        mv "$file" "$file.ep4-disabled"
    done

    # Keep the traditional sources.list free of duplicate entries
    cat > /etc/apt/sources.list <<'EOF'
# Debian repositories are managed in:
# /etc/apt/sources.list.d/debian.sources
EOF

    cat > "$sources_dir/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    echo -e "${BLUE}[INFO]${NC} Updating package lists..."

    if run_quietly apt-get update; then
        echo -e "${GREEN}[SUCCESS]${NC} Repositories configured successfully."
    else
        echo -e "${RED}[ERROR]${NC} Repository update failed."
        return 1
    fi
}

configure_repositories


# Upgrade installed packages
echo -e "${BLUE}[INFO]${NC} Upgrading installed packages..."

run_quietly env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo -e "${GREEN}[SUCCESS]${NC} Packages upgraded successfully."


echo -e "${BLUE}[INFO]${NC} Installing sudo..."
run_quietly apt-get install -y sudo

echo -e "${GREEN}[SUCCESS]${NC} sudo installed successfully."

# Create user part if it does not exists
if id part &>/dev/null; then
    echo -e "${BLUE}[INFO]${NC} User 'part' already exists."
else
    echo -e "${BLUE}[INFO]${NC} Creating user 'part'..."

    adduser --disabled-password --gecos "" part

    echo -e "${BLUE}[INFO]${NC} Set password for user 'part':"

    while ! passwd part; do
        echo -e "${RED}[ERROR]${NC} Passwords do not match or password setting failed. Try again."
    done

    echo -e "${GREEN}[SUCCESS]${NC} User 'part' created successfully."
fi

# Add part to the sudo group
if id -nG part | grep -qw sudo; then
    echo -e "${BLUE}[INFO]${NC} User 'part' is already in the sudo group."
else
    run_quietly usermod -aG sudo part
    echo -e "${GREEN}[SUCCESS]${NC} User 'part' added to the sudo group."
fi


# Configure maximum concurrent logins for user part
LIMITS_FILE="/etc/security/limits.conf"
LIMIT_RULE="part hard maxlogins 5"

if grep -Fxq "$LIMIT_RULE" "$LIMITS_FILE"; then
    echo -e "${BLUE}[INFO]${NC} Max logins limit is already configured."
else
    echo "$LIMIT_RULE" >> "$LIMITS_FILE"
    echo -e "${GREEN}[SUCCESS]${NC} Max logins set to 5 for user part."
fi


# Configure hostname
TARGET_HOSTNAME='ep4-vm'

if [[ "$(hostname)" == "$TARGET_HOSTNAME" ]]; then
    echo -e "${BLUE}[INFO]${NC} Hostname is already set to ${TARGET_HOSTNAME}."
else
    hostnamectl set-hostname "$TARGET_HOSTNAME"
    echo -e "${GREEN}[SUCCESS]${NC} Hostname set to ${TARGET_HOSTNAME}."
fi

# Configure timezone
TARGET_TIMEZONE="Asia/Tehran"

if [[ "$(timedatectl show --property=Timezone --value)" == "$TARGET_TIMEZONE" ]]; then
    echo -e "${BLUE}[INFO]${NC} Timezone is already set to ${TARGET_TIMEZONE}."
else
    timedatectl set-timezone "$TARGET_TIMEZONE"
    echo -e "${GREEN}[SUCCESS]${NC} Timezone set to ${TARGET_TIMEZONE}."
fi


echo -e "${BLUE}[INFO]${NC} Installing OpenSSH Server..."

run_quietly apt-get install -y openssh-server

run_quietly systemctl enable --now ssh

echo -e "${GREEN}[SUCCESS]${NC} OpenSSH Server installed and enabled."

echo "Hello from Emperor Penguin 4" > /etc/issue.net
chmod 644 /etc/issue.net



cat > /etc/ssh/sshd_config.d/ssh-ep4.conf <<'EOF'
Port 2222
PermitRootLogin no
AllowUsers part
Banner /etc/issue.net
ClientAliveInterval 300
ClientAliveCountMax 0
EOF

if run_quietly /usr/sbin/sshd -t; then
    run_quietly systemctl reload ssh
    echo -e "${GREEN}[SUCCESS]${NC} SSH configuration applied."
else
    echo -e "${RED}[ERROR]${NC} Invalid SSH configuration."
    exit 1
fi
sshd -T | grep -E '^(port|permitrootlogin|allowusers|banner|clientaliveinterval|clientalivecountmax) '


#Set NTP Server
echo -e "${BLUE}[INFO]${NC} Checking systemd-timesyncd..."

if ! dpkg -s systemd-timesyncd &>/dev/null; then
    echo -e "${BLUE}[INFO]${NC} Installing systemd-timesyncd..."
    run_quietly apt-get install -y systemd-timesyncd
    echo -e "${GREEN}[SUCCESS]${NC} systemd-timesyncd installed."
fi

echo -e "${BLUE}[INFO]${NC} Configuring NTP servers..."

cat > /etc/systemd/timesyncd.conf <<'EOF'
[Time]
NTP=2.ir.pool.ntp.org
FallbackNTP=pool.ntp.org
EOF

echo -e "${BLUE}[INFO]${NC} Enabling NTP service..."

run_quietly systemctl enable --now systemd-timesyncd
run_quietly systemctl restart systemd-timesyncd

echo -e "${GREEN}[SUCCESS]${NC} NTP service enabled and started."


# Optimizing kernel and sysctl

echo -e "${BLUE}[INFO]${NC} Configuring kernel parameters..."

SYSCTL_FILE="/etc/sysctl.d/99-ep4-security.conf"

cat > "$SYSCTL_FILE" <<'EOF'
# Ignore ICMP Echo requests (Ping)
net.ipv4.icmp_echo_ignore_all = 1

# Reduce kernel swappiness
vm.swappiness = 10
EOF

if run_quietly sysctl --load="$SYSCTL_FILE"; then
    echo -e "${GREEN}[SUCCESS]${NC} Kernel parameters configured."
else
    echo -e "${RED}[ERROR]${NC} Failed to configure kernel parameters."
    exit 1
fi


echo -e "${BLUE}[INFO]${NC} Installing nftables..."
run_quietly apt-get install -y nftables

echo -e "${BLUE}[INFO]${NC} Enabling nftables service..."
run_quietly systemctl enable nftables

echo -e "${GREEN}[SUCCESS]${NC} nftables installed and enabled."


cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet ep4 {
    set debian4 {
        type ipv4_addr
        flags interval
    }

    set debian6 {
        type ipv6_addr
        flags interval
    }

    chain input {
        type filter hook input priority 0;
        policy drop;

        iifname "lo" accept
        ct state established,related accept
        tcp dport 2222 ct state new accept
    }

    chain forward {
        type filter hook forward priority 0;
        policy drop;
    }

    chain output {
        type filter hook output priority 0;
        policy accept;

        ip daddr @debian4 counter comment "Traffic to deb.debian.org IPv4"
        ip6 daddr @debian6 counter comment "Traffic to deb.debian.org IPv6"
    }
}
EOF


touch /usr/local/sbin/ep4-update-debian-ips.sh
cat > /usr/local/sbin/ep4-update-debian-ips.sh <<'EOF'

#!/bin/bash

set -euo pipefail

DOMAIN="deb.debian.org"

mapfile -t IPV4 < <(
    getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u
)

mapfile -t IPV6 < <(
    getent ahostsv6 "$DOMAIN" | awk '{print $1}' | sort -u
)

nft flush set inet ep4 debian4
nft flush set inet ep4 debian6

if ((${#IPV4[@]})); then
    printf -v ELEMENTS '%s, ' "${IPV4[@]}"
    nft add element inet ep4 debian4 "{ ${ELEMENTS%, } }"
fi

if ((${#IPV6[@]})); then
    printf -v ELEMENTS '%s, ' "${IPV6[@]}"
    nft add element inet ep4 debian6 "{ ${ELEMENTS%, } }"
fi
EOF

chmod 750 /usr/local/sbin/ep4-update-debian-ips.sh

run_quietly nft -c -f /etc/nftables.conf
run_quietly systemctl restart nftables

run_quietly /usr/local/sbin/ep4-update-debian-ips.sh

cat > /etc/cron.d/ep4-update-debian-ips <<'EOF'
*/5 * * * * root /usr/local/sbin/ep4-update-debian-ips.sh
EOF

chmod 644 /etc/cron.d/ep4-update-debian-ips

# log

mkdir -p /opt/data/sysinfo
touch /usr/local/bin/sysinfo.sh
cat > /usr/local/bin/sysinfo.sh <<'EOF'
#!/bin/bash

set -euo pipefail

LOG_DIR="/opt/data/sysinfo"
LOG_FILE="$LOG_DIR/sysinfo.log"

mkdir -p "$LOG_DIR"

exec >> "$LOG_FILE" 2>&1

echo "========================================"
echo "System Information - $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

# Count root processes
echo
echo "[1] Number of root processes:"

ps -U root -u root --no-headers | wc -l

# Listening ports and processes
echo
echo "[2] Listening ports and processes:"

ss -lntup

# Users with UID below 1000
echo
echo "[3] Users with UID below 1000:"

awk -F: '$3 < 1000 {print $1 " (UID: " $3 ")"}' /etc/passwd

# RAM usage
echo
echo "[4] RAM Usage:"

free -m | awk '/^Mem:/ {
    printf "Used: %s MB / Total: %s MB (%.2f%%)\n",
    $3, $2, ($3 / $2) * 100
}'

# Free space in /opt
echo
echo "[5] Free space in /opt:"

df -P /opt | awk 'NR == 2 {
    used = $5
    gsub(/%/, "", used)
    printf "Free space: %.0f%%\n", 100 - used
}'

echo
EOF

chmod 750 /usr/local/bin/sysinfo.sh

/usr/local/bin/sysinfo.sh

echo -e "${BLUE}[INFO]${NC} Installing cron..."

run_quietly apt-get install -y cron

echo -e "${BLUE}[INFO]${NC} Configuring sysinfo cron job..."

cat > /etc/cron.d/ep4-sysinfo <<'EOF'
*/2 * * * * root /usr/local/bin/sysinfo.sh
EOF

chmod 644 /etc/cron.d/ep4-sysinfo

run_quietly systemctl enable --now cron

echo -e "${GREEN}[SUCCESS]${NC} Sysinfo cron job configured."

chmod 644 /etc/cron.d/ep4-sysinfo
run_quietly systemctl enable --now cron
