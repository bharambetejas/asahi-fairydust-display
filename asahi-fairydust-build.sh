#!/bin/bash
# =============================================================================
# asahi-fairydust-build.sh
#
# Enables USB-C DisplayPort Alt Mode (external display) on Fedora Asahi Remix
# for Apple Silicon Macs by building the Asahi Linux "fairydust" kernel branch.
#
# Tested on: MacBook Air M2 running Fedora Asahi Remix (XFCE)
# Author:    Tejas Bharambe
# License:   MIT
# Date:      April 2026
#
# WHAT THIS DOES:
#   1. Installs build dependencies (including Rust toolchain)
#   2. Clones the Asahi Linux fairydust kernel branch
#   3. Configures the kernel with full Fedora config + DP Alt Mode + GPU (Rust)
#   4. Builds and installs the kernel
#   5. Updates m1n1 bootloader and GRUB
#   6. Sets up typec module autoloading
#   7. Creates a display hotplug script
#
# REQUIREMENTS:
#   - Fedora Asahi Remix on Apple Silicon Mac
#   - At least 15GB free disk space
#   - Internet connection
#   - sudo access
#
# USAGE:
#   chmod +x asahi-fairydust-build.sh
#   ./asahi-fairydust-build.sh
#
# NOTES:
#   - The build takes 60-90+ minutes depending on your Mac
#   - After reboot, select the kernel with "-fairydust" in GRUB
#   - Use the FRONT-MOST USB-C port for external display
#   - This script is provided as-is with no warranty
# =============================================================================

set -eo pipefail

# --- Configuration ---
CLONE_DIR="$HOME/linux-fairydust"
BRANCH="fairydust"
LOCALVERSION="-fairydust"
DISPLAY_SCRIPT="$HOME/display-setup.sh"
LOG_FILE="$HOME/fairydust-build.log"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

log_and_run() {
    echo "$ $*" >> "$LOG_FILE"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

confirm() {
    read -rp "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

# --- Pre-flight Checks ---
preflight() {
    echo ""
    echo "============================================================"
    echo "  Asahi Linux Fairydust Kernel Builder"
    echo "  USB-C DisplayPort Alt Mode for Apple Silicon Macs"
    echo "============================================================"
    echo ""

    # Must not be root
    if [[ $EUID -eq 0 ]]; then
        error "Do not run this script as root. Run as your normal user (sudo will be used when needed)."
    fi

    # Check we're on Fedora Asahi
    if ! grep -qi "fedora" /etc/os-release 2>/dev/null; then
        error "This script is designed for Fedora Asahi Remix. Detected a different OS."
    fi

    if [[ "$(uname -m)" != "aarch64" ]]; then
        error "This script is for Apple Silicon (aarch64) only. Detected: $(uname -m)"
    fi

    info "Current kernel: $(uname -r)"

    # Check disk space (need at least 15GB)
    AVAIL_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    info "Available disk space: ${AVAIL_GB}GB"
    if [[ "$AVAIL_GB" -lt 15 ]]; then
        error "Need at least 15GB free disk space. You have ${AVAIL_GB}GB. Free up space and try again."
    fi
    ok "Disk space check passed"

    # Check internet
    if ! ping -c 1 github.com &>/dev/null; then
        error "No internet connection. Please connect and try again."
    fi
    ok "Internet connection available"

    # Check if already running fairydust
    if uname -r | grep -q "fairydust"; then
        warn "You're already running a fairydust kernel: $(uname -r)"
        if ! confirm "Continue anyway (rebuild)?"; then
            exit 0
        fi
    fi

    echo ""
    warn "This script will:"
    echo "  - Install build dependencies (~2GB)"
    echo "  - Clone the Asahi Linux kernel source (~3GB)"
    echo "  - Build a custom kernel (~10-15GB build artifacts)"
    echo "  - Install the kernel alongside your existing one"
    echo "  - Modify GRUB and m1n1 bootloader configuration"
    echo ""
    warn "The build will take 60-90+ minutes."
    echo ""

    if ! confirm "Do you want to proceed?"; then
        info "Aborted."
        exit 0
    fi

    echo "" > "$LOG_FILE"
    info "Logging to $LOG_FILE"
}

# --- Step 1: Install Build Dependencies ---
install_deps() {
    echo ""
    info "=== Step 1/9: Installing build dependencies ==="

    sudo dnf install -y \
        gcc gcc-c++ make bc bison flex elfutils-libelf-devel \
        ncurses-devel python3 zlib-devel libuuid-devel dwarves \
        xz zstd clang llvm lld git \
        openssl openssl-devel \
        rust rust-std-static bindgen-cli \
        2>&1 | tee -a "$LOG_FILE"

    # Install rust-src (needed for kernel Rust support - provides core library source)
    info "Installing rust-src..."
    sudo dnf install -y rust-src 2>&1 | tee -a "$LOG_FILE" || true

    # Verify the core library source exists; if not, try rustup fallback
    if [[ ! -f /usr/lib/rustlib/src/rust/library/core/src/lib.rs ]]; then
        warn "rust-src not found via dnf. Trying rustup fallback..."
        if command -v rustup &>/dev/null; then
            rustup component add rust-src 2>&1 | tee -a "$LOG_FILE"
        else
            warn "rustup not available. Installing..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tee -a "$LOG_FILE"
            source "$HOME/.cargo/env"
            rustup component add rust-src 2>&1 | tee -a "$LOG_FILE"
        fi
    fi

    # Install glx-utils for post-build GPU verification
    sudo dnf install -y glx-utils 2>&1 | tee -a "$LOG_FILE" || true

    # Verify Rust toolchain
    if ! command -v rustc &>/dev/null; then
        error "rustc not found after installation. Please install Rust manually."
    fi

    if ! command -v bindgen &>/dev/null; then
        error "bindgen not found after installation. Please install bindgen-cli manually."
    fi

    ok "Build dependencies installed"
    info "  rustc:   $(rustc --version)"
    info "  bindgen: $(bindgen --version)"
}

# --- Step 2: Clone Fairydust Branch ---
clone_source() {
    echo ""
    info "=== Step 2/9: Cloning fairydust kernel source ==="

    if [[ -d "$CLONE_DIR" ]]; then
        warn "Directory $CLONE_DIR already exists."
        if confirm "Delete and re-clone?"; then
            rm -rf "$CLONE_DIR"
        else
            info "Using existing source tree."
            cd "$CLONE_DIR"
            return
        fi
    fi

    git clone https://github.com/AsahiLinux/linux.git \
        --branch "$BRANCH" --single-branch "$CLONE_DIR" 2>&1 | tee -a "$LOG_FILE"

    cd "$CLONE_DIR"
    ok "Source cloned to $CLONE_DIR"
    info "Branch: $(git branch --show-current)"
    info "HEAD:   $(git log --oneline -1)"
}

# --- Step 3: Configure Kernel ---
configure_kernel() {
    echo ""
    info "=== Step 3/9: Configuring kernel ==="

    cd "$CLONE_DIR"

    # Start with current Fedora kernel config
    CURRENT_CONFIG="/boot/config-$(uname -r)"
    if [[ ! -f "$CURRENT_CONFIG" ]]; then
        error "Cannot find current kernel config at $CURRENT_CONFIG"
    fi

    cp "$CURRENT_CONFIG" .config
    info "Copied config from $CURRENT_CONFIG"

    # Accept defaults for new options
    make olddefconfig 2>&1 | tee -a "$LOG_FILE"

    # Verify Rust is available to the build system
    info "Checking Rust availability..."

    # Try to find and export RUST_LIB_SRC if not already set
    if [[ -z "$RUST_LIB_SRC" ]]; then
        for candidate in \
            /usr/lib/rustlib/src/rust/library \
            "$HOME/.rustup/toolchains/stable-aarch64-unknown-linux-gnu/lib/rustlib/src/rust/library" \
            $(find /usr/lib/rustlib -name "library" -type d 2>/dev/null | head -1); do
            if [[ -d "$candidate" ]]; then
                export RUST_LIB_SRC="$candidate"
                info "Rust library source: $RUST_LIB_SRC"
                break
            fi
        done
    fi

    if make rustavailable 2>&1 | tee -a "$LOG_FILE"; then
        ok "Rust is available"
    else
        error "Rust is not available to the kernel build system.
Please ensure rust, rust-std-static, rust-src, and bindgen-cli are installed.
Run: make rustavailable   for details.
See Documentation/rust/quick-start.rst in the kernel source."
    fi

    # Enable Rust support
    scripts/config --enable RUST

    # Enable Asahi GPU driver and dependencies
    scripts/config --module DRM_ASAHI
    scripts/config --enable RUST_FW_LOADER_ABSTRACTIONS
    scripts/config --enable RUST_DRM_SCHED
    scripts/config --enable RUST_DRM_GEM_SHMEM_HELPER
    scripts/config --enable RUST_DRM_GPUVM
    scripts/config --enable RUST_APPLE_MAILBOX
    scripts/config --enable RUST_APPLE_RTKIT

    # Enable DP Alt Mode support
    scripts/config --module TYPEC_DP_ALTMODE
    scripts/config --module TYPEC_NVIDIA_ALTMODE
    scripts/config --module TYPEC_TBT_ALTMODE

    # Ensure Apple DRM is enabled
    scripts/config --module DRM_APPLE

    # Set local version tag
    sed -i "s/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"${LOCALVERSION}\"/" .config

    # Fix known build-breakers
    scripts/config --set-str EFI_SBAT_FILE ""
    scripts/config --disable QRTR_MHI

    # Disable module signing (Fedora config enables this but signing key
    # doesn't exist in our build, causing modules_install to fail)
    scripts/config --disable MODULE_SIG
    scripts/config --disable MODULE_SIG_ALL
    scripts/config --disable MODULE_SIG_FORCE
    scripts/config --set-str MODULE_SIG_KEY ""
    scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
    scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

    # Finalize config
    make olddefconfig 2>&1 | tee -a "$LOG_FILE"

    # Verify critical options
    echo ""
    info "Verifying critical config options:"
    for opt in CONFIG_RUST CONFIG_DRM_ASAHI CONFIG_DRM_APPLE \
               CONFIG_TYPEC_DP_ALTMODE CONFIG_RUST_APPLE_RTKIT; do
        val=$(grep "^${opt}=" .config 2>/dev/null || echo "NOT SET")
        if [[ "$val" == "NOT SET" ]]; then
            error "$opt is not set in .config. Build will be incomplete."
        else
            ok "  $val"
        fi
    done
    echo ""
}

# --- Step 4: Build Kernel ---
build_kernel() {
    echo ""
    info "=== Step 4/9: Building kernel (this will take a while) ==="
    info "Using $(nproc) parallel jobs"
    info "Started at: $(date)"

    cd "$CLONE_DIR"

    log_and_run make -j$(nproc)

    ok "Kernel build completed at: $(date)"
}

# --- Step 5: Install Kernel ---
install_kernel() {
    echo ""
    info "=== Step 5/9: Installing kernel ==="

    cd "$CLONE_DIR"

    KVER=$(make kernelrelease)
    info "Kernel version: $KVER"

    # Install modules, DTBs, VDSO
    info "Installing modules..."
    log_and_run sudo make INSTALL_MOD_STRIP=1 modules_install

    info "Installing DTBs..."
    log_and_run sudo make dtbs_install

    info "Installing VDSO..."
    log_and_run sudo make vdso_install

    # Create DTB symlink that Fedora expects
    sudo ln -sf "/boot/dtbs/$KVER" "/usr/lib/modules/$KVER/dtb"

    # Install kernel image
    info "Installing kernel image..."
    log_and_run sudo make install

    ok "Kernel installed: $KVER"
}

# --- Step 6: Update m1n1 Bootloader ---
update_m1n1() {
    echo ""
    info "=== Step 6/9: Updating m1n1 bootloader ==="

    cd "$CLONE_DIR"

    sudo ln -sfn "$PWD" /usr/src/linux

    if sudo update-m1n1 2>&1 | tee -a "$LOG_FILE"; then
        ok "m1n1 updated"
    else
        error "Failed to update m1n1. Check $LOG_FILE for details."
    fi
}

# --- Step 7: Update GRUB ---
update_grub() {
    echo ""
    info "=== Step 7/9: Updating GRUB ==="

    sudo sed -i 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
    sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tee -a "$LOG_FILE"

    ok "GRUB updated (5-second menu timeout)"
}

# --- Step 8: Setup Typec Module Autoloading ---
setup_modules() {
    echo ""
    info "=== Step 8/9: Setting up typec module autoloading ==="

    echo -e "typec_displayport\ntypec_nvidia\ntypec_thunderbolt" | \
        sudo tee /etc/modules-load.d/fairydust-typec.conf > /dev/null

    ok "Typec modules will auto-load on boot"
}

# --- Step 9: Create Display Hotplug Script ---
setup_display_script() {
    echo ""
    info "=== Step 9/9: Creating display hotplug script ==="

    USERNAME=$(whoami)
    HOMEDIR=$(eval echo ~"$USERNAME")

    # Create the display setup script
    cat > "$DISPLAY_SCRIPT" << DISPEOF
#!/bin/bash
# Auto-configure external display for Asahi Linux on Apple Silicon
# Generated by asahi-fairydust-build.sh

sleep 2
export DISPLAY=:0
export XAUTHORITY=${HOMEDIR}/.Xauthority

# Check if DP-1 is connected
if xrandr 2>/dev/null | grep -q "DP-1 connected"; then
    # Get the preferred resolution of the external display
    EXT_RES=\$(xrandr | grep -A1 "DP-1 connected" | tail -1 | awk '{print \$1}')
    INT_RES="2560x1600"

    # Calculate framebuffer width
    INT_W=\$(echo "\$INT_RES" | cut -d'x' -f1)
    EXT_W=\$(echo "\$EXT_RES" | cut -d'x' -f1)
    EXT_H=\$(echo "\$EXT_RES" | cut -d'x' -f2)
    INT_H=\$(echo "\$INT_RES" | cut -d'x' -f2)
    FB_W=\$((INT_W + EXT_W))
    FB_H=\$((INT_H > EXT_H ? INT_H : EXT_H))

    xrandr --fb "\${FB_W}x\${FB_H}" \\
        --output eDP-1 --mode "\$INT_RES" --pos 0x0 \\
        --output DP-1 --mode "\$EXT_RES" --pos "\${INT_W}x0"

    logger "fairydust: External display configured at \$EXT_RES"
else
    # No external display — just use internal
    xrandr --output eDP-1 --auto
    logger "fairydust: No external display detected"
fi
DISPEOF
    chmod +x "$DISPLAY_SCRIPT"
    ok "Display script created at $DISPLAY_SCRIPT"

    # XFCE autostart entry
    mkdir -p "$HOMEDIR/.config/autostart"
    cat > "$HOMEDIR/.config/autostart/fairydust-display.desktop" << AUTOEOF
[Desktop Entry]
Type=Application
Name=Fairydust Display Setup
Comment=Configure external display via USB-C DP Alt Mode
Exec=${DISPLAY_SCRIPT}
Hidden=false
X-GNOME-Autostart-enabled=true
AUTOEOF
    ok "Autostart entry created (runs at login)"

    # Udev rule for hotplug
    sudo bash -c "cat > /etc/udev/rules.d/95-fairydust-hotplug.rules << UDEVEOF
ACTION==\"change\", SUBSYSTEM==\"drm\", RUN+=\"${DISPLAY_SCRIPT}\"
UDEVEOF"
    sudo udevadm control --reload-rules
    ok "Udev hotplug rule created (auto-detects display plug/unplug)"
}

# --- Summary ---
print_summary() {
    KVER=$(cd "$CLONE_DIR" && make kernelrelease)
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}BUILD COMPLETE!${NC}"
    echo "============================================================"
    echo ""
    echo "  Kernel version:  $KVER"
    echo "  Source tree:      $CLONE_DIR"
    echo "  Display script:   $DISPLAY_SCRIPT"
    echo "  Build log:        $LOG_FILE"
    echo ""
    echo "  NEXT STEPS:"
    echo "  1. Reboot:  sudo reboot"
    echo "  2. In GRUB menu, select the kernel with '${LOCALVERSION}'"
    echo "  3. After boot, plug USB-C to HDMI adapter into the"
    echo "     FRONT-MOST USB-C port (closer to the trackpad)"
    echo "  4. The display should auto-configure, or run:"
    echo "     ~/display-setup.sh"
    echo ""
    echo "  VERIFY AFTER BOOT:"
    echo "    uname -r                         # should show ${LOCALVERSION}"
    echo "    lsmod | grep asahi               # GPU driver loaded"
    echo "    glxinfo | grep 'OpenGL renderer'  # should show Apple M2"
    echo "    xrandr                            # should show DP-1"
    echo ""
    echo "  TO REVERT:"
    echo "    Reboot and select your original kernel in GRUB."
    echo "    The original kernel is untouched."
    echo ""
    echo "============================================================"
    echo ""

    if confirm "Reboot now?"; then
        sudo reboot
    else
        info "Reboot when ready with: sudo reboot"
    fi
}

# --- Main ---
main() {
    preflight
    install_deps
    clone_source
    configure_kernel
    build_kernel
    install_kernel
    update_m1n1
    update_grub
    setup_modules
    setup_display_script
    print_summary
}

main "$@"
