#!/usr/bin/env bash
# Teacher checker for phase 1. Run as root on the student's VM:
#   sudo bash verify.sh            (auto-detects the SSH port)
# Prints PASS/FAIL per item and a score. Does not change anything.
export LC_ALL=C
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' W=$'\e[1m' N=$'\e[0m'
SCORE=0 MAX=0
t() {   # t points "description" command...
    local p=$1 d=$2; shift 2; MAX=$((MAX + p))
    if ( "$@" ) >/dev/null 2>&1; then SCORE=$((SCORE + p)); printf '%s PASS %s %-55s +%s\n' "$G" "$N" "$d" "$p"
    else printf '%s FAIL %s %-55s  0/%s\n' "$R" "$N" "$d" "$p"; fi
}
sec() { printf '\n%s== %s%s\n' "$W" "$1" "$N"; }
size_gb() { lsblk -bno SIZE "$(findmnt -no SOURCE "$1" | head -1)" 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024 + 0.5}'; }
near() { local s; s=$(size_gb "$1"); [ -n "$s" ] && [ "$s" -ge $(($2 - 1)) ] && [ "$s" -le $(($2 + 1)) ]; }
is_lvm() { [ "$(lsblk -no TYPE "$(findmnt -no SOURCE "$1")" 2>/dev/null | head -1)" = lvm ]; }
sshT() { sshd -T 2>/dev/null | grep -qix "$1"; }

SSH_PORT=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
echo "${W}Phase 1 check on $(hostname) - SSH port: ${SSH_PORT:-?}${N}"

sec "1. Install & partitions"
t 1 "Debian 13"                          grep -q '^VERSION_ID="13"' /etc/os-release
t 1 "/  ~10G"                            near / 10
t 1 "/home ~5G"                          near /home 5
t 1 "/var ~10G on LVM"                   bash -c "$(declare -f size_gb near is_lvm); near /var 10 && is_lvm /var"
t 1 "/opt ~6G on LVM"                    bash -c "$(declare -f size_gb near is_lvm); near /opt 6 && is_lvm /opt"
t 1 "swap ~4G"                           bash -c 'swapon --show=SIZE --bytes --noheadings | awk "{s+=\$1} END {exit !(s > 3.5*2^30 && s < 4.6*2^30)}"'
t 2 "/opt mounted with nodev,nosuid"     bash -c 'o=$(findmnt -no OPTIONS /opt); [[ $o == *nodev* && $o == *nosuid* ]]'
t 1 "/opt options also in /etc/fstab"    bash -c 'awk "\$2==\"/opt\" {print \$4}" /etc/fstab | grep nodev | grep -q nosuid'

sec "2. Users"
t 1 "user part exists"                   id part
t 1 "part is in sudo group"              bash -c 'id -nG part | grep -qw sudo'
t 1 "sudo is installed"                  command -v sudo
t 1 "maxlogins 5 for part"               bash -c "grep -Eq '^[[:space:]]*part[[:space:]]+(hard|-)[[:space:]]+maxlogins[[:space:]]+5' /etc/security/limits.conf /etc/security/limits.d/*.conf"
t 1 "official trixie repos"              bash -c 'grep -rhqs "deb.debian.org/debian" /etc/apt/sources.list /etc/apt/sources.list.d/ && grep -rhqs trixie /etc/apt/sources.list /etc/apt/sources.list.d/'
t 1 "no cdrom repo active"               bash -c '! grep -rhqs "^[[:space:]]*deb cdrom" /etc/apt/sources.list /etc/apt/sources.list.d/'
t 1 "hostname ep4-node"                  bash -c '[ "$(hostname)" = ep4-node ]'
t 1 "timezone Asia/Tehran"               bash -c '[ "$(readlink -f /etc/localtime)" = /usr/share/zoneinfo/Asia/Tehran ]'

sec "3. SSH"
t 1 "openssh-server installed"           dpkg -s openssh-server
t 1 "port changed from 22"               bash -c "[ -n '$SSH_PORT' ] && [ '$SSH_PORT' != 22 ]"
t 1 "sshd really listens on new port"    bash -c "ss -Htln | grep -q ':$SSH_PORT '"
t 1 "banner text"                        bash -c 'f=$(sshd -T | awk "\$1==\"banner\" {print \$2}"); grep -q "Hello from Emperor Penguin 4" "$f"'
t 1 "PermitRootLogin no"                 sshT "permitrootlogin no"
t 1 "AllowUsers part"                    sshT "allowusers part"
t 1 "ClientAliveInterval 300"            sshT "clientaliveinterval 300"

sec "4. NTP / sysctl"
t 1 "systemd-timesyncd active"           systemctl is-active systemd-timesyncd
t 1 "custom NTP server configured"       bash -c 'grep -rhqs "^NTP=." /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.d/'
t 1 "icmp_echo_ignore_all = 1 (now)"     bash -c '[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" = 1 ]'
t 1 "vm.swappiness = 10 (now)"           bash -c '[ "$(sysctl -n vm.swappiness)" = 10 ]'
t 1 "both saved in /etc/sysctl.d"        bash -c 'grep -rhqs "icmp_echo_ignore_all *= *1" /etc/sysctl.d/ && grep -rhqs "swappiness *= *10" /etc/sysctl.d/'

sec "5. Cron monitoring"
t 1 "cron service active"                systemctl is-active cron
t 1 "a */2 cron job exists"              bash -c 'grep -rhsE "^[^#]*\*/2[[:space:]]" /etc/crontab /etc/cron.d/ /var/spool/cron/crontabs/'
t 1 "/opt/data/sysinfo has files"        bash -c '[ -n "$(ls -A /opt/data/sysinfo 2>/dev/null)" ]'
t 2 "files updated in last 5 minutes"    bash -c '[ -n "$(find /opt/data/sysinfo -type f -mmin -5)" ]'

sec "6. nftables"
t 1 "nftables enabled at boot"           systemctl is-enabled nftables
t 1 "input policy drop"                  bash -c 'nft list ruleset | grep -A2 "hook input" | grep -q "policy drop"'
t 1 "SSH port allowed"                   bash -c "nft list ruleset | grep -q 'dport $SSH_PORT'"
t 1 "loopback allowed"                   bash -c 'nft list ruleset | grep -q "iif \"lo\" accept\|iifname \"lo\" accept"'
t 1 "counter for deb.debian.org"         bash -c 'nft list ruleset | grep -A40 "hook output" | grep -q counter'

echo
printf '%sScore: %d / %d%s\n' "$W" "$SCORE" "$MAX" "$N"
echo "${Y}Manual: ssh as root must fail; ping must not answer; reboot and run again.${N}"
