#!/bin/bash
# ============================================================
# collect_equipment_info.sh
# Collecte automatique d'informations pour la Fiche Équipement
# À exécuter DIRECTEMENT sur l'hôte Proxmox / équipement physique
# Usage : bash collect_equipment_info.sh
# ============================================================

# ── Couleurs ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Variables ───────────────────────────────────────────────
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
HOSTNAME_VAL=$(hostname)
OUTPUT_FILE="/root/fiche_equipement_${HOSTNAME_VAL}_${TIMESTAMP}.md"

# ── Fonctions utilitaires ───────────────────────────────────
print_section() {
    echo -e "\n${CYAN}${BOLD}>>> $1${NC}"
}

print_ok() {
    echo -e "  ${GREEN}✔${NC} $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

print_err() {
    echo -e "  ${RED}✘${NC} $1"
}

cmd_or_na() {
    local result
    result=$(eval "$1" 2>/dev/null)
    [[ -z "$result" ]] && echo "N/A" || echo "$result"
}

# ── Vérification root ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERREUR]${NC} Ce script doit être exécuté en root."
    echo "  → sudo bash $0"
    exit 1
fi

# ── Détection des outils disponibles ───────────────────────
check_tool() {
    command -v "$1" &>/dev/null
}

# Installation automatique des outils manquants
install_missing_tools() {
    local tools=("dmidecode" "smartmontools" "lshw" "ipmitool" "hdparm" "pciutils" "usbutils")
    local missing=()

    for tool in "${tools[@]}"; do
        if ! check_tool "$tool" && ! dpkg -l "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Outils manquants détectés : ${missing[*]}${NC}"
        echo -e "${YELLOW}Installation automatique...${NC}"
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq "${missing[@]}" 2>/dev/null
    fi
}

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║    COLLECTE FICHE ÉQUIPEMENT — HOMELAB DOCS         ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo -e "  Équipement : ${YELLOW}$HOSTNAME_VAL${NC}"
echo -e "  Output     : ${YELLOW}$OUTPUT_FILE${NC}"
echo ""

install_missing_tools

# ════════════════════════════════════════════════════════════
# COLLECTE DES DONNÉES
# ════════════════════════════════════════════════════════════

# ── 1. Identité système ─────────────────────────────────────
print_section "Identité système"

OS_NAME=$(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME_HUMAN=$(uptime -p 2>/dev/null || uptime)
TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || echo "$HOSTNAME_VAL")
DOMAIN=$(hostname -d 2>/dev/null || echo "N/A")

# Proxmox spécifique
IS_PROXMOX=false
PVE_VERSION="N/A"
if check_tool pveversion; then
    IS_PROXMOX=true
    PVE_VERSION=$(pveversion 2>/dev/null | head -1)
    print_ok "Proxmox VE détecté : $PVE_VERSION"
fi

print_ok "Hostname   : $HOSTNAME_VAL"
print_ok "FQDN       : $HOSTNAME_FQDN"
print_ok "OS         : $OS_NAME"
print_ok "Kernel     : $KERNEL"
print_ok "Arch       : $ARCH"
print_ok "Timezone   : $TIMEZONE"
print_ok "Uptime     : $UPTIME_HUMAN"

# ── 2. Hardware — DMI/SMBIOS ────────────────────────────────
print_section "Informations matérielles (DMI)"

if check_tool dmidecode; then
    MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | head -1)
    PRODUCT_NAME=$(dmidecode -s system-product-name 2>/dev/null | head -1)
    PRODUCT_VERSION=$(dmidecode -s system-version 2>/dev/null | head -1)
    SERIAL_NUMBER=$(dmidecode -s system-serial-number 2>/dev/null | head -1)
    BIOS_VERSION=$(dmidecode -s bios-version 2>/dev/null | head -1)
    BIOS_DATE=$(dmidecode -s bios-release-date 2>/dev/null | head -1)
    CHASSIS_TYPE=$(dmidecode -s chassis-type 2>/dev/null | head -1)

    print_ok "Constructeur  : $MANUFACTURER"
    print_ok "Modèle        : $PRODUCT_NAME"
    print_ok "Version       : $PRODUCT_VERSION"
    print_ok "Numéro série  : $SERIAL_NUMBER"
    print_ok "BIOS version  : $BIOS_VERSION"
    print_ok "BIOS date     : $BIOS_DATE"
    print_ok "Type châssis  : $CHASSIS_TYPE"
else
    print_warn "dmidecode non disponible — informations matérielles limitées"
    MANUFACTURER="N/A"
    PRODUCT_NAME="N/A"
    SERIAL_NUMBER="N/A"
    BIOS_VERSION="N/A"
    BIOS_DATE="N/A"
    CHASSIS_TYPE="N/A"
fi

# ── 3. CPU ──────────────────────────────────────────────────
print_section "Processeur(s)"

CPU_MODEL=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
CPU_SOCKETS=$(grep 'physical id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
CPU_CORES_PHYS=$(grep 'cpu cores' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
CPU_THREADS_TOTAL=$(nproc --all 2>/dev/null)
CPU_FREQ_BASE=$(grep 'cpu MHz' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs | awk '{printf "%.0f MHz", $1}')
CPU_VENDOR=$(grep 'vendor_id' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
CPU_CACHE=$(grep 'cache size' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
CPU_FLAGS_VT=$(grep -o 'vmx\|svm' /proc/cpuinfo 2>/dev/null | head -1)
CPU_FLAGS_IOMMU=$(grep -o 'ept\|npt' /proc/cpuinfo 2>/dev/null | head -1)
CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)

# NUMA
NUMA_NODES=$(numactl --hardware 2>/dev/null | grep 'available:' | awk '{print $2}')

# Température CPU
CPU_TEMP="N/A"
if check_tool sensors; then
    CPU_TEMP=$(sensors 2>/dev/null | grep -i 'core 0\|Tctl\|CPU Temp\|Package id' | head -1 | awk '{print $NF}')
fi

print_ok "Modèle          : $CPU_MODEL"
print_ok "Vendor          : $CPU_VENDOR"
print_ok "Sockets         : ${CPU_SOCKETS:-1}"
print_ok "Cores physiques : $CPU_CORES_PHYS par socket"
print_ok "Threads totaux  : $CPU_THREADS_TOTAL"
print_ok "Fréquence       : $CPU_FREQ_BASE"
print_ok "Cache L3        : $CPU_CACHE"
print_ok "Virtualisation  : ${CPU_FLAGS_VT:-Non détectée} | IOMMU : ${CPU_FLAGS_IOMMU:-N/A}"
print_ok "NUMA nodes      : ${NUMA_NODES:-N/A}"
print_ok "Température     : $CPU_TEMP"
print_ok "Load average    : $CPU_LOAD"

# Vérification IOMMU Proxmox
if $IS_PROXMOX; then
    IOMMU_STATUS=$(dmesg 2>/dev/null | grep -i iommu | head -3)
    print_ok "IOMMU kernel : ${IOMMU_STATUS:-Non détecté dans dmesg}"
fi

# ── 4. Mémoire RAM ──────────────────────────────────────────
print_section "Mémoire RAM"

RAM_TOTAL=$(free -h | awk '/^Mem:/{print $2}')
RAM_USED=$(free -h | awk '/^Mem:/{print $3}')
RAM_FREE=$(free -h | awk '/^Mem:/{print $4}')
RAM_PERCENT=$(free | awk '/^Mem:/{printf "%.1f%%", $3/$2*100}')
SWAP_TOTAL=$(free -h | awk '/^Swap:/{print $2}')
SWAP_USED=$(free -h | awk '/^Swap:/{print $3}')

print_ok "RAM Total  : $RAM_TOTAL | Utilisé : $RAM_USED ($RAM_PERCENT)"
print_ok "Swap       : $SWAP_TOTAL | Utilisé : $SWAP_USED"

# Détail des barrettes RAM via dmidecode
if check_tool dmidecode; then
    print_ok "Détail barrettes RAM :"
    RAM_SLOTS_TOTAL=$(dmidecode -t memory 2>/dev/null | grep -c 'Memory Device$')
    RAM_SLOTS_USED=$(dmidecode -t memory 2>/dev/null | grep -A5 'Memory Device$' | grep -v 'No Module' | grep -c 'Size:.*[0-9].*MB\|Size:.*[0-9].*GB')
    echo "      Slots total : $RAM_SLOTS_TOTAL | Occupés : $RAM_SLOTS_USED"

    dmidecode -t memory 2>/dev/null | awk '
    /Memory Device$/ { in_device=1; slot++; size=""; type=""; speed=""; mfr=""; part="" }
    in_device && /Size:/ { size=$0 }
    in_device && /Type:/ && !/Form Factor|Error|Type Detail/ { type=$0 }
    in_device && /Speed:/ && !/Configured/ { speed=$0 }
    in_device && /Manufacturer:/ { mfr=$0 }
    in_device && /Part Number:/ { part=$0 }
    in_device && /^$/ && in_device {
        if (size !~ /No Module/) {
            gsub(/^[ \t]+/, "", size)
            gsub(/^[ \t]+/, "", type)
            gsub(/^[ \t]+/, "", speed)
            gsub(/^[ \t]+/, "", mfr)
            gsub(/^[ \t]+/, "", part)
            printf "      [Slot %d] %s | %s | %s | %s | %s\n", slot, size, type, speed, mfr, part
        }
        in_device=0
    }' 2>/dev/null | head -24
fi

# ── 5. Stockage — Disques ───────────────────────────────────
print_section "Stockage — Disques physiques"

print_ok "Vue globale (lsblk) :"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,VENDOR,ROTA,TRAN 2>/dev/null | while read -r line; do
    echo "      $line"
done

print_ok ""
print_ok "Détail par disque :"
for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
    [[ ! -b "$disk" ]] && continue

    DISK_SIZE=$(lsblk -dn -o SIZE "$disk" 2>/dev/null)
    DISK_MODEL=$(lsblk -dn -o MODEL "$disk" 2>/dev/null | xargs)
    DISK_VENDOR=$(lsblk -dn -o VENDOR "$disk" 2>/dev/null | xargs)
    DISK_ROTA=$(lsblk -dn -o ROTA "$disk" 2>/dev/null)
    DISK_TRAN=$(lsblk -dn -o TRAN "$disk" 2>/dev/null | xargs)
    DISK_TYPE=$([[ "$DISK_ROTA" == "0" ]] && echo "SSD/NVMe" || echo "HDD")

    # SMART
    if check_tool smartctl; then
        SMART_STATUS=$(smartctl -H "$disk" 2>/dev/null | grep 'SMART overall-health' | awk '{print $NF}')
        SMART_TEMP=$(smartctl -A "$disk" 2>/dev/null | grep -i 'temperature\|Airflow_Temperature' | head -1 | awk '{print $10"°C"}')
        SMART_POH=$(smartctl -A "$disk" 2>/dev/null | grep 'Power_On_Hours' | awk '{print $10" h"}')
        SMART_REALLOCATED=$(smartctl -A "$disk" 2>/dev/null | grep 'Reallocated_Sector' | awk '{print $10}')
    else
        SMART_STATUS="N/A"
        SMART_TEMP="N/A"
        SMART_POH="N/A"
        SMART_REALLOCATED="N/A"
    fi

    echo "      📀 $disk — $DISK_VENDOR $DISK_MODEL | $DISK_SIZE | $DISK_TYPE | $DISK_TRAN"
    echo "         SMART: ${SMART_STATUS:-N/A} | Temp: $SMART_TEMP | Power-on: $SMART_POH | Reallocated: ${SMART_REALLOCATED:-N/A}"
done

# ── 6. ZFS ──────────────────────────────────────────────────
print_section "ZFS — Pools et datasets"

if check_tool zpool; then
    print_ok "Statut des pools :"
    zpool list -o name,size,alloc,free,cap,health,altroot 2>/dev/null | while read -r line; do
        echo "      $line"
    done

    print_ok "Détail santé des pools :"
    zpool status 2>/dev/null | grep -E 'pool:|state:|status:|scan:|errors:|NAME|ata-|sd[a-z]|nvme' | while read -r line; do
        echo "      $line"
    done

    print_ok "Datasets :"
    zfs list -o name,used,avail,refer,mountpoint,compression,recordsize 2>/dev/null | while read -r line; do
        echo "      $line"
    done
else
    print_warn "ZFS non disponible sur ce système"
fi

# ── 7. Stockage Proxmox ─────────────────────────────────────
if $IS_PROXMOX; then
    print_section "Stockage Proxmox (pvesm)"

    pvesm status 2>/dev/null | while read -r line; do
        echo "      $line"
    done
fi

# ── 8. Partitions montées ───────────────────────────────────
print_section "Partitions montées (df)"

df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null | \
    grep -v tmpfs | grep -v devtmpfs | grep -v udev | while read -r line; do
    echo "      $line"
done

# ── 9. Réseau ───────────────────────────────────────────────
print_section "Configuration réseau"

print_ok "Interfaces physiques :"
ip -o link show 2>/dev/null | grep -v lo | awk '{print $2, $9}' | while read -r iface state; do
    mac=$(ip link show "${iface%%:*}" 2>/dev/null | grep 'link/ether' | awk '{print $2}')
    speed=$(cat /sys/class/net/"${iface%%:*}"/speed 2>/dev/null || echo "N/A")
    echo "      ${iface%%:*} | Statut: $state | MAC: $mac | Speed: ${speed}Mb"
done

print_ok ""
print_ok "Adresses IP configurées :"
ip -o addr show 2>/dev/null | grep -v '^[0-9]*: lo' | awk '{print "      " $2, $3, $4}' | while read -r line; do
    echo "$line"
done

GATEWAY=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1)
DNS_SERVERS=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd ', ')
print_ok "Gateway         : ${GATEWAY:-N/A}"
print_ok "DNS servers     : ${DNS_SERVERS:-N/A}"

# Config /etc/network/interfaces (Proxmox / Debian)
if [[ -f /etc/network/interfaces ]]; then
    print_ok "Contenu /etc/network/interfaces :"
    cat /etc/network/interfaces | while read -r line; do
        echo "      $line"
    done
fi

# Bridges
print_ok "Bridges Linux :"
brctl show 2>/dev/null | while read -r line; do
    echo "      $line"
done

# VLANs
print_ok "VLANs configurés :"
cat /proc/net/vlan/config 2>/dev/null | while read -r line; do
    echo "      $line"
done || print_warn "Aucun VLAN configuré ou /proc/net/vlan/config absent"

# Bonds
print_ok "Bonds (agrégations) :"
if ls /proc/net/bonding/ &>/dev/null; then
    for bond in /proc/net/bonding/*; do
        echo "      $(basename $bond) :"
        cat "$bond" 2>/dev/null | grep -E 'Mode|Slave|Speed|Status|MII' | while read -r line; do
            echo "        $line"
        done
    done
else
    print_warn "Aucun bond configuré"
fi

# ── 10. Cartes PCIe ─────────────────────────────────────────
print_section "Bus PCI — Cartes d'extension"

if check_tool lspci; then
    print_ok "Tous les périphériques PCI :"
    lspci 2>/dev/null | while read -r line; do
        echo "      $line"
    done

    print_ok ""
    print_ok "Cartes réseau détectées :"
    lspci 2>/dev/null | grep -i 'ethernet\|network\|wireless' | while read -r line; do
        echo "      $line"
    done

    print_ok "GPUs détectés :"
    lspci 2>/dev/null | grep -i 'vga\|display\|3d\|2d\|nvidia\|amd\|radeon' | while read -r line; do
        echo "      $line"
    done

    print_ok "Contrôleurs de stockage :"
    lspci 2>/dev/null | grep -i 'raid\|storage\|sata\|nvme\|scsi\|ahci' | while read -r line; do
        echo "      $line"
    done
else
    print_warn "lspci non disponible"
fi

# IOMMU groups (Proxmox passthrough)
if $IS_PROXMOX; then
    print_ok "IOMMU Groups (passthrough) :"
    if [[ -d /sys/kernel/iommu_groups ]]; then
        for d in /sys/kernel/iommu_groups/*/devices/*; do
            n=${d#*/iommu_groups/*}; n=${n%%/*}
            echo "      IOMMU Group $n: $(lspci -nns "${d##*/}" 2>/dev/null)"
        done | sort -t' ' -k3 -n | head -30
    else
        print_warn "IOMMU non activé (ajouter intel_iommu=on ou amd_iommu=on dans /etc/default/grub)"
    fi
fi

# ── 11. Alimentation ────────────────────────────────────────
print_section "Alimentation et consommation"

if check_tool ipmitool; then
    print_ok "Alimentation via IPMI :"
    ipmitool sdr type 'Power Supply' 2>/dev/null | while read -r line; do
        echo "      $line"
    done
    print_ok "Puissance consommée :"
    ipmitool dcmi power reading 2>/dev/null | while read -r line; do
        echo "      $line"
    done
else
    print_warn "ipmitool non disponible — consommation non mesurable"
fi

# Lecture /sys pour l'alimentation AC
if check_tool upower; then
    upower -i /org/freedesktop/UPower/devices/line_power_AC 2>/dev/null | while read -r line; do
        echo "      $line"
    done
fi

# ── 12. Température et ventilation ──────────────────────────
print_section "Températures et ventilation"

if check_tool sensors; then
    print_ok "Sensors complet :"
    sensors 2>/dev/null | while read -r line; do
        echo "      $line"
    done
else
    print_warn "lm-sensors non installé (apt install lm-sensors)"
fi

if check_tool ipmitool; then
    print_ok "Températures IPMI :"
    ipmitool sdr type Temperature 2>/dev/null | while read -r line; do
        echo "      $line"
    done
    print_ok "Vitesse ventilateurs IPMI :"
    ipmitool sdr type Fan 2>/dev/null | while read -r line; do
        echo "      $line"
    done
fi

# Températures disques
if check_tool smartctl; then
    print_ok "Températures disques :"
    for disk in /dev/sd[a-z]; do
        [[ ! -b "$disk" ]] && continue
        temp=$(smartctl -A "$disk" 2>/dev/null | grep -i 'Temperature_Celsius\|Airflow_Temperature' | awk '{print $10}')
        [[ -n "$temp" ]] && echo "      $disk : ${temp}°C"
    done
fi

# ── 13. VMs et LXC Proxmox ──────────────────────────────────
if $IS_PROXMOX; then
    print_section "VMs et LXC Proxmox"

    print_ok "VMs (qm list) :"
    qm list 2>/dev/null | while read -r line; do
        echo "      $line"
    done

    print_ok ""
    print_ok "LXC (pct list) :"
    pct list 2>/dev/null | while read -r line; do
        echo "      $line"
    done

    print_ok ""
    print_ok "Résumé des ressources par VM/LXC :"
    for vmid in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
        VM_NAME=$(qm config "$vmid" 2>/dev/null | grep '^name:' | cut -d' ' -f2)
        VM_MEM=$(qm config "$vmid" 2>/dev/null | grep '^memory:' | cut -d' ' -f2)
        VM_CORES=$(qm config "$vmid" 2>/dev/null | grep '^cores:' | cut -d' ' -f2)
        VM_STATUS=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        echo "      VM $vmid | $VM_NAME | Status: $VM_STATUS | CPU: $VM_CORES cores | RAM: ${VM_MEM}MB"
    done

    for ctid in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
        CT_NAME=$(pct config "$ctid" 2>/dev/null | grep '^hostname:' | cut -d' ' -f2)
        CT_MEM=$(pct config "$ctid" 2>/dev/null | grep '^memory:' | cut -d' ' -f2)
        CT_CORES=$(pct config "$ctid" 2>/dev/null | grep '^cores:' | cut -d' ' -f2)
        CT_STATUS=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
        echo "      LXC $ctid | $CT_NAME | Status: $CT_STATUS | CPU: ${CT_CORES:-N/A} cores | RAM: ${CT_MEM:-N/A}MB"
    done

    print_section "Configuration PBS (si applicable)"
    if check_tool proxmox-backup-client || systemctl list-units --type=service 2>/dev/null | grep -q proxmox-backup; then
        print_ok "Service PBS :"
        systemctl status proxmox-backup 2>/dev/null | grep -E 'Active|Main PID' | while read -r line; do
            echo "      $line"
        done
    fi
fi

# ── 14. Sécurité ────────────────────────────────────────────
print_section "Sécurité"

SSH_ROOT=$(grep '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
SSH_PWAUTH=$(grep '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
SSH_PORT=$(grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
SSH_KEYS=$(ls /root/.ssh/authorized_keys 2>/dev/null && wc -l < /root/.ssh/authorized_keys || echo "0")

print_ok "SSH Root Login    : ${SSH_ROOT:-non défini}"
print_ok "SSH Password Auth : ${SSH_PWAUTH:-non défini}"
print_ok "SSH Port          : ${SSH_PORT:-22}"
print_ok "SSH Clés autorisées (root) : $SSH_KEYS"

# Fail2ban
check_tool fail2ban-client && \
    print_ok "Fail2ban : $(fail2ban-client status 2>/dev/null | grep 'Number of jail' | xargs)" || \
    print_warn "Fail2ban non installé"

# Pare-feu Proxmox
if $IS_PROXMOX; then
    PVE_FW=$(pve-firewall status 2>/dev/null | head -1)
    print_ok "Proxmox Firewall : ${PVE_FW:-Non disponible}"
fi

# Dernière connexion SSH
print_ok "Dernières connexions SSH :"
last | head -5 | while read -r line; do
    echo "      $line"
done

# ── 15. Packages et mises à jour ────────────────────────────
print_section "Mises à jour et packages"

UPDATES_AVAILABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "N/A")
print_ok "Mises à jour disponibles : $UPDATES_AVAILABLE"

print_ok "Derniers packages installés/mis à jour :"
grep -E ' install | upgrade ' /var/log/dpkg.log 2>/dev/null | tail -15 | while read -r line; do
    echo "      $line"
done

# ── 16. Crontabs et tâches planifiées ───────────────────────
print_section "Tâches planifiées"

ROOT_CRON=$(crontab -l 2>/dev/null)
if [[ -n "$ROOT_CRON" ]]; then
    print_ok "Crontab root :"
    echo "$ROOT_CRON" | while read -r line; do echo "      $line"; done
else
    print_warn "Crontab root vide"
fi

print_ok "Crons système (/etc/cron.d/) :"
for f in /etc/cron.d/*; do
    [[ -f "$f" ]] && echo "      $(basename $f)"
done

# ── 17. Logs système récents ────────────────────────────────
print_section "Logs système récents (erreurs)"

print_ok "Erreurs kernel (dmesg) :"
dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -10 | while read -r line; do
    echo "      $line"
done

print_ok "Erreurs systemd (journal) :"
journalctl -p err -n 10 --no-pager 2>/dev/null | while read -r line; do
    echo "      $line"
done

# ════════════════════════════════════════════════════════════
# GÉNÉRATION DU FICHIER MARKDOWN
# ════════════════════════════════════════════════════════════

print_section "Génération du fichier Markdown → $OUTPUT_FILE"

cat > "$OUTPUT_FILE" << MARKDOWN
# 🖥️ FICHE ÉQUIPEMENT — ${HOSTNAME_VAL^^}

> **Généré automatiquement le :** $(date '+%d/%m/%Y à %H:%M:%S')
> **Script :** collect_equipment_info.sh
> **Statut :** 🔵 À compléter manuellement

---

## 1. 📋 IDENTITÉ

| Champ | Valeur |
|-------|--------|
| **Nom d'hôte** | $HOSTNAME_VAL |
| **FQDN** | $HOSTNAME_FQDN |
| **Rôle principal** | _À compléter_ |
| **Catégorie** | _Serveur / Réseau / Stockage / SBC_ |
| **Constructeur** | $MANUFACTURER |
| **Modèle** | $PRODUCT_NAME |
| **Numéro de série** | $SERIAL_NUMBER |
| **BIOS version** | $BIOS_VERSION |
| **BIOS date** | $BIOS_DATE |
| **Type châssis** | $CHASSIS_TYPE |
| **OS / Hyperviseur** | $OS_NAME |
| **Kernel** | $KERNEL |
| **Architecture** | $ARCH |
| **Timezone** | $TIMEZONE |
| **Uptime** | $UPTIME_HUMAN |
$(if $IS_PROXMOX; then echo "| **Proxmox VE** | $PVE_VERSION |"; fi)

---

## 2. ⚙️ PROCESSEUR

| Champ | Valeur |
|-------|--------|
| **Modèle CPU** | $CPU_MODEL |
| **Vendor** | $CPU_VENDOR |
| **Sockets** | ${CPU_SOCKETS:-1} |
| **Cores physiques** | $CPU_CORES_PHYS (par socket) |
| **Threads totaux** | $CPU_THREADS_TOTAL |
| **Fréquence** | $CPU_FREQ_BASE |
| **Cache L3** | $CPU_CACHE |
| **Virtualisation** | ${CPU_FLAGS_VT:-N/A} |
| **IOMMU** | ${CPU_FLAGS_IOMMU:-N/A} |
| **NUMA nodes** | ${NUMA_NODES:-N/A} |
| **Température (idle)** | $CPU_TEMP |
| **Load average** | $CPU_LOAD |

---

## 3. 🧠 MÉMOIRE RAM

| Champ | Valeur |
|-------|--------|
| **Capacité totale** | $RAM_TOTAL |
| **RAM utilisée** | $RAM_USED ($RAM_PERCENT) |
| **RAM libre** | $RAM_FREE |
| **Swap total** | $SWAP_TOTAL |
| **Swap utilisé** | $SWAP_USED |
| **Slots total** | ${RAM_SLOTS_TOTAL:-N/A} |
| **Slots occupés** | ${RAM_SLOTS_USED:-N/A} |

**Détail barrettes :**
\`\`\`
$(dmidecode -t memory 2>/dev/null | awk '
/Memory Device$/ { in_device=1; slot++; size=""; type=""; speed=""; mfr=""; part="" }
in_device && /Size:/ { size=$0 }
in_device && /Type:/ && !/Form Factor|Error|Type Detail/ { type=$0 }
in_device && /Speed:/ && !/Configured/ { speed=$0 }
in_device && /Manufacturer:/ { mfr=$0 }
in_device && /Part Number:/ { part=$0 }
in_device && /^$/ {
    if (size !~ /No Module/ && size != "") {
        gsub(/^[ \t]+/, "", size)
        gsub(/^[ \t]+/, "", type)
        gsub(/^[ \t]+/, "", speed)
        gsub(/^[ \t]+/, "", mfr)
        gsub(/^[ \t]+/, "", part)
        printf "[Slot %d] %s | %s | %s | %s | %s\n", slot, size, type, speed, mfr, part
    }
    in_device=0
}' 2>/dev/null)
\`\`\`

---

## 4. 💾 STOCKAGE

\`\`\`
$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,VENDOR,ROTA,TRAN 2>/dev/null)
\`\`\`

**Détail SMART par disque :**
$(for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
    [[ ! -b "$disk" ]] && continue
    DISK_SIZE=$(lsblk -dn -o SIZE "$disk" 2>/dev/null)
    DISK_MODEL=$(lsblk -dn -o MODEL "$disk" 2>/dev/null | xargs)
    DISK_VENDOR=$(lsblk -dn -o VENDOR "$disk" 2>/dev/null | xargs)
    DISK_ROTA=$(lsblk -dn -o ROTA "$disk" 2>/dev/null)
    DISK_TRAN=$(lsblk -dn -o TRAN "$disk" 2>/dev/null | xargs)
    DISK_TYPE=$([[ "$DISK_ROTA" == "0" ]] && echo "SSD/NVMe" || echo "HDD")
    if check_tool smartctl; then
        SMART_STATUS=$(smartctl -H "$disk" 2>/dev/null | grep 'SMART overall-health' | awk '{print $NF}')
        SMART_TEMP=$(smartctl -A "$disk" 2>/dev/null | grep -i 'temperature\|Airflow_Temperature' | head -1 | awk '{print $10"°C"}')
        SMART_POH=$(smartctl -A "$disk" 2>/dev/null | grep 'Power_On_Hours' | awk '{print $10" h"}')
        SMART_REALLOCATED=$(smartctl -A "$disk" 2>/dev/null | grep 'Reallocated_Sector' | awk '{print $10}')
    fi
    echo "- **$disk** — $DISK_VENDOR $DISK_MODEL | $DISK_SIZE | $DISK_TYPE | $DISK_TRAN"
    echo "  - SMART: ${SMART_STATUS:-N/A} | Temp: ${SMART_TEMP:-N/A} | Power-on: ${SMART_POH:-N/A} | Reallocated: ${SMART_REALLOCATED:-N/A}"
done)

---

## 5. 🌐 RÉSEAU

**Interfaces :**
\`\`\`
$(ip -o link show 2>/dev/null | grep -v lo)
\`\`\`

**Adresses IP :**
\`\`\`
$(ip -o addr show 2>/dev/null | grep -v '^[0-9]*: lo')
\`\`\`

**Routes :**
\`\`\`
$(ip route show 2>/dev/null)
\`\`\`

| Champ | Valeur |
|-------|--------|
| **Gateway** | ${GATEWAY:-N/A} |
| **DNS** | ${DNS_SERVERS:-N/A} |

**Configuration /etc/network/interfaces :**
\`\`\`
$(cat /etc/network/interfaces 2>/dev/null || echo "N/A")
\`\`\`

---

## 6. 🔌 BUS PCI

\`\`\`
$(lspci 2>/dev/null || echo "N/A")
\`\`\`

---

## 7. 🌡️ TEMPÉRATURES

\`\`\`
$(sensors 2>/dev/null || echo "lm-sensors non disponible")
\`\`\`

$(if check_tool ipmitool; then
echo "**IPMI Températures :**"
echo "\`\`\`"
ipmitool sdr type Temperature 2>/dev/null
echo "\`\`\`"
echo "**IPMI Ventilateurs :**"
echo "\`\`\`"
ipmitool sdr type Fan 2>/dev/null
echo "\`\`\`"
fi)

---

$(if $IS_PROXMOX; then
cat << 'PROXMOX_SECTION'
## 8. 🖥️ PROXMOX — VMs & LXC

PROXMOX_SECTION

echo "**VMs :**"
echo "\`\`\`"
qm list 2>/dev/null
echo "\`\`\`"
echo ""
echo "**LXC :**"
echo "\`\`\`"
pct list 2>/dev/null
echo "\`\`\`"
echo ""
echo "**Stockage Proxmox :**"
echo "\`\`\`"
pvesm status 2>/dev/null
echo "\`\`\`"
echo ""
echo "---"
echo ""
fi)

## 9. 🔒 SÉCURITÉ

| Champ | Valeur |
|-------|--------|
| **SSH Root Login** | ${SSH_ROOT:-non défini} |
| **SSH Password Auth** | ${SSH_PWAUTH:-non défini} |
| **SSH Port** | ${SSH_PORT:-22} |
| **SSH Clés root** | $SSH_KEYS |

---

## 10. 📝 NOTES / OBSERVATIONS

_À compléter manuellement_

- [ ] Vérification SMART des disques
- [ ] Test réseau complet
- [ ] Validation sauvegardes
- [ ] Mise à jour firmware/BIOS

---

## 11. 📅 HISTORIQUE DES INTERVENTIONS

| Date | Intervenant | Action |
|------|-------------|--------|
| $(date '+%d/%m/%Y') | Script auto | Génération fiche initiale |

MARKDOWN

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✔  Fiche générée avec succès !${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "  📄 Fichier : ${YELLOW}$OUTPUT_FILE${NC}"
echo -e "  📏 Taille  : $(du -sh "$OUTPUT_FILE" 2>/dev/null | cut -f1)"
echo ""
echo -e "  💡 Prochaines étapes :"
echo -e "     1. Compléter les champs '_À compléter_' dans le fichier"
echo -e "     2. Vérifier les informations collectées"
echo -e "     3. Intégrer dans votre documentation homelab"
echo ""
