#!/bin/bash
# =============================================================================
# asahi-fairydust-uninstall.sh
#
# Cleanly removes the fairydust kernel and reverts to the stock Fedora Asahi
# kernel. Run this from the STOCK kernel (not the fairydust kernel).
#
# USAGE:
#   chmod +x asahi-fairydust-uninstall.sh
#   ./asahi-fairydust-uninstall.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

confirm() {
    read -rp "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

echo ""
echo "============================================================"
echo "  Asahi Linux Fairydust Kernel Uninstaller"
echo "============================================================"
echo ""

# Safety check — don't uninstall while running fairydust
if uname -r | grep -q "fairydust"; then
    error "You are currently running the fairydust kernel ($(uname -r)).
Reboot into your stock Fedora Asahi kernel first, then run this script."
fi

info "Current kernel: $(uname -r)"
echo ""

# Find fairydust kernel version(s)
FAIRYDUST_KVERS=$(ls /usr/lib/modules/ 2>/dev/null | grep fairydust || true)
if [[ -z "$FAIRYDUST_KVERS" ]]; then
    info "No fairydust kernel found. Nothing to uninstall."
    exit 0
fi

echo "Found fairydust kernel(s):"
for kver in $FAIRYDUST_KVERS; do
    echo "  - $kver"
done
echo ""

if ! confirm "Remove the fairydust kernel and all associated files?"; then
    info "Aborted."
    exit 0
fi

for KVER in $FAIRYDUST_KVERS; do
    info "Removing kernel: $KVER"

    # Remove kernel files from /boot
    sudo rm -f "/boot/vmlinuz-$KVER"
    sudo rm -f "/boot/initramfs-$KVER.img"
    sudo rm -f "/boot/System.map-$KVER"
    sudo rm -f "/boot/config-$KVER"

    # Remove modules
    sudo rm -rf "/usr/lib/modules/$KVER"

    # Remove DTBs
    sudo rm -rf "/boot/dtbs/$KVER"

    ok "Removed $KVER"
done

# Remove typec module autoload
if [[ -f /etc/modules-load.d/fairydust-typec.conf ]]; then
    sudo rm -f /etc/modules-load.d/fairydust-typec.conf
    ok "Removed typec module autoload config"
fi

# Remove udev hotplug rule
if [[ -f /etc/udev/rules.d/95-fairydust-hotplug.rules ]]; then
    sudo rm -f /etc/udev/rules.d/95-fairydust-hotplug.rules
    sudo udevadm control --reload-rules
    ok "Removed udev hotplug rule"
fi

# Remove display script and autostart
if [[ -f "$HOME/display-setup.sh" ]]; then
    rm -f "$HOME/display-setup.sh"
    ok "Removed display setup script"
fi

if [[ -f "$HOME/.config/autostart/fairydust-display.desktop" ]]; then
    rm -f "$HOME/.config/autostart/fairydust-display.desktop"
    ok "Removed autostart entry"
fi

# Restore m1n1 to stock kernel DTBs
info "Restoring m1n1 bootloader..."
STOCK_KVER=$(uname -r)
if [[ -L /boot/dtb ]]; then
    sudo ln -sfn "dtb-$STOCK_KVER" /boot/dtb
fi

# Restore /etc/sysconfig/update-m1n1 DTBS path
if [[ -f /etc/sysconfig/update-m1n1 ]]; then
    sudo sed -i 's|.*DTBS=.*|DTBS="/boot/dtb"|' /etc/sysconfig/update-m1n1
fi

sudo ln -sfn "/usr/lib/modules/$STOCK_KVER" /usr/src/linux
sudo update-m1n1
ok "m1n1 restored to stock kernel"

# Regenerate GRUB
info "Regenerating GRUB..."
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
ok "GRUB regenerated"

# Optionally remove source tree
echo ""
CLONE_DIR="$HOME/linux-fairydust"
if [[ -d "$CLONE_DIR" ]]; then
    SOURCE_SIZE=$(du -sh "$CLONE_DIR" | awk '{print $1}')
    if confirm "Remove kernel source tree at $CLONE_DIR ($SOURCE_SIZE)?"; then
        rm -rf "$CLONE_DIR"
        ok "Source tree removed"
    else
        info "Source tree kept at $CLONE_DIR"
    fi
fi

# Also check for ~/linux
if [[ -d "$HOME/linux" ]] && [[ -f "$HOME/linux/.config" ]]; then
    if grep -q "fairydust" "$HOME/linux/.config" 2>/dev/null; then
        SOURCE_SIZE=$(du -sh "$HOME/linux" | awk '{print $1}')
        if confirm "Found fairydust source at ~/linux ($SOURCE_SIZE). Remove?"; then
            rm -rf "$HOME/linux"
            ok "Source tree removed"
        fi
    fi
fi

echo ""
echo "============================================================"
echo -e "  ${GREEN}UNINSTALL COMPLETE${NC}"
echo "============================================================"
echo ""
echo "  Your system is back to the stock Fedora Asahi kernel."
echo "  Current kernel: $(uname -r)"
echo ""
echo "============================================================"
