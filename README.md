# Asahi Linux External Display Enabler (Fairydust)

Enable USB-C external display output on Apple Silicon Macs running Fedora Asahi Remix.

## What is this?

Apple Silicon MacBooks (M1/M2) running Asahi Linux cannot output to external displays via USB-C in the stable kernel. The Asahi team has developed experimental support in their `fairydust` kernel branch. This script automates building and installing that kernel.

## Supported Hardware

| Device | Status |
|--------|--------|
| MacBook Air M1 | Tested (39C3 demo, community reports) |
| MacBook Air M2 | ✅ Tested and working |
| MacBook Pro M1 Pro | Tested by community |
| MacBook Pro M1 Max | Untested (should work) |
| MacBook Pro M2 Pro/Max | Untested (should work) |
| Mac Mini M1/M2 (HDMI) | Already supported in stable kernel |

## Requirements

- **Fedora Asahi Remix** on Apple Silicon Mac
- **15GB+ free disk space** (kernel build is large)
- **Internet connection** for downloading source and packages
- **USB-C to HDMI adapter** (or USB-C to DisplayPort)
- **60-90 minutes** for the build

## Quick Start

```bash
# Download the script
chmod +x asahi-fairydust-build.sh

# Run it
./asahi-fairydust-build.sh

# After reboot, select the "-fairydust" kernel in GRUB
# Plug adapter into the FRONT-MOST USB-C port
```

## What the script does

1. Installs build dependencies (gcc, Rust toolchain, etc.)
2. Clones the Asahi Linux `fairydust` kernel branch
3. Configures the kernel with your existing Fedora config as baseline
4. Enables Rust support + Asahi GPU driver (prevents lag)
5. Enables USB-C DisplayPort Alt Mode modules
6. Builds the kernel (~60-90 min)
7. Installs kernel, modules, and device tree blobs
8. Updates m1n1 bootloader and GRUB
9. Sets up automatic typec module loading
10. Creates a display hotplug script for automatic configuration

## Important Notes

- **Use the front-most USB-C port** (closer to the trackpad/front edge)
- Only **one** USB-C port supports display output at a time
- Hot-plug may not always work — a reboot with the adapter plugged in is more reliable
- Your original kernel is **untouched** — select it in GRUB to revert anytime

## After Reboot Verification

```bash
# Check kernel
uname -r
# Expected: 6.18.x-fairydust+

# Check GPU acceleration (NOT llvmpipe)
glxinfo | grep "OpenGL renderer"
# Expected: Apple M2 (G14G B0)

# Check GPU module
lsmod | grep asahi
# Expected: asahi  1179648  0

# Check display output
xrandr
# Expected: DP-1 connected with resolutions listed
```

## Uninstall

To completely remove the fairydust kernel and revert to stock:

1. Reboot into your stock Fedora Asahi kernel (select it in GRUB)
2. Run:

```bash
chmod +x asahi-fairydust-uninstall.sh
./asahi-fairydust-uninstall.sh
```

## Troubleshooting

### Lag / slow desktop after installing fairydust kernel

The GPU driver wasn't built. Check:
```bash
glxinfo | grep "OpenGL renderer"
```
If it says `llvmpipe`, Rust support wasn't enabled during build. Ensure `rust`, `rust-std-static`, `rust-src`, and `bindgen-cli` are installed, then rebuild.

### "No space left on device" during build

Need 15GB+ free. Clean up with:
```bash
sudo dnf clean all
```
Or build on an external SSD.

### Display not detected after plugging in

- Try the **other** USB-C port
- Check kernel logs: `dmesg | tail -50`
- Force detection: `xrandr --output DP-1 --auto`
- Ensure typec modules are loaded: `lsmod | grep typec`

### m1n1 update fails

Check `/etc/sysconfig/update-m1n1` — the DTBS path may point to a deleted kernel. Fix with:
```bash
sudo sed -i "s|.*DTBS=.*|DTBS=/usr/lib/modules/$(uname -r)/dtb|" /etc/sysconfig/update-m1n1
sudo update-m1n1
```

## Credits

- **Asahi Linux team** (Sven, Janne, marcan) for the fairydust branch and years of reverse engineering
- **Asahi community** for testing and documentation
- Built following the process documented at [asahilinux.org](https://asahilinux.org/2026/02/progress-report-6-19/)

## Disclaimer

This involves building and installing a custom kernel. While your original kernel remains untouched (just select it in GRUB to revert), proceed at your own risk. The fairydust branch is experimental and not officially supported by the Asahi team for general use.

## License

MIT
