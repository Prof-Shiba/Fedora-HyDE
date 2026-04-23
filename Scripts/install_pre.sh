#!/usr/bin/env bash
#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Script to apply pre install configs |--/ /-|#
#|-/ /--| Prasanth Rangan                     |-/ /--|#
#|-/ /--| Modified for Fedora by Shiba        |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

scrDir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
if ! source "${scrDir}/global_fn.sh"; then
    echo "Error: unable to source global_fn.sh..."
    exit 1
fi

flg_DryRun=${flg_DryRun:-0}

# Needed packages prior to install
echo "Installing dependencies..."
sudo dnf install cmake hyprutils-devel wayland-devel wayland-protocols-devel gcc python3-devel cairo-devel gobject-introspection-devel pkgconf-pkg-config cairo-gobject-devel
sudo dnf install rust cargo clang libxkbcommon-devel pango-devel lz4-devel

# for hyprshade
sudo dnf install pipx
echo "Installing hyprshade..."
pipx install hyprshade
mkdir -p ~/.config/hypr/shaders
# move the shaders into the right place
cp ~/.local/share/pipx/venvs/hyprshade/share/hyprshade/shaders/* ~/.config/hypr/shaders/

#hypr deps
echo "Installing COPR repos for hyprland, nwg-shell, fonts, and VSCode"
sudo dnf copr enable sdegler/hyprland
sudo dnf copr enable tofik/nwg-shell
sudo dnf copr enable atim/starship
sudo dnf install hyprutils-devel swaylock-effects

# awww
git clone https://codeberg.org/LGFae/awww
cd awww
cargo build --release
sudo cp target/release/awww /usr/local/bin
sudo cp target/release/awww-daemon /usr/local/bin
cd ..

sudo dnf install \
https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# vs code
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'

# hyprquery
echo "Installing hyprquery..."
git clone https://github.com/HyDE-Project/hyprquery
cd hyprquery
mkdir build;cd build
cmake ..
make -j$(nproc)
cd ..;cd bin
sudo cp hyq /usr/local/bin
cd && cd ~/Fedora-HyDE/Scripts/

sudo dnf makecache

# grub
if pkg_installed grub && [ -f /boot/grub/grub.cfg ]; then
    print_log -sec "bootloader" -b "detected :: " "grub..."

    if [ ! -f /etc/default/grub.hyde.bkp ] && [ ! -f /boot/grub/grub.hyde.bkp ]; then
        [ "${flg_DryRun}" -eq 1 ] || sudo cp /etc/default/grub /etc/default/grub.hyde.bkp
        [ "${flg_DryRun}" -eq 1 ] || sudo cp /boot/grub/grub.cfg /boot/grub/grub.hyde.bkp

        # Only if the nvidia installation doesn't skip
        if nvidia_detect; then
            if [ ${flg_Nvidia} -eq 1 ]; then
                print_log -g "[bootloader] " -b "configure :: " "nvidia detected, adding nvidia_drm.modeset=1 to boot option..."
                gcld=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "/etc/default/grub" | cut -d'"' -f2 | sed 's/\b nvidia_drm.modeset=.\b//g')
                [ "${flg_DryRun}" -eq 1 ] || sudo sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/c\GRUB_CMDLINE_LINUX_DEFAULT=\"${gcld} nvidia_drm.modeset=1\"" /etc/default/grub
            else
                print_log -g "[bootloader] " -b "skip :: " "nvidia detected, skipping nvidia_drm.modeset=1 to boot option..."
            fi
        fi

        print_log -g "WARNING: Custom Grub themes may conflict with secure boot on Fedora. If unsure if you need secure boot, simply skip this portion."
        print_log -g "[bootloader] " "Select grub theme:" -y "\n[1]" -y " Retroboot (dark)" -y "\n[2]" -y " Pochita (light)"
        read -r -p " :: Press enter to skip grub theme <or> Enter option number : " grubopt
        case ${grubopt} in
        1) grubtheme="Retroboot" ;;
        2) grubtheme="Pochita" ;;
        *) grubtheme="None" ;;
        esac

        if [ "${grubtheme}" == "None" ]; then
            print_log -g "[bootloader] " -b "skip :: " "grub theme selection skipped..."
            echo ""
        else
            print_log -g "[bootloader] " -b "set :: " "grub theme // ${grubtheme}"
            echo ""
            # shellcheck disable=SC2154
            [ "${flg_DryRun}" -eq 1 ] || sudo tar -xzf "${cloneDir}/Source/arcs/Grub_${grubtheme}.tar.gz" -C /usr/share/grub/themes/
            [ "${flg_DryRun}" -eq 1 ] || sudo sed -i "/^GRUB_DEFAULT=/c\GRUB_DEFAULT=saved
            /^GRUB_GFXMODE=/c\GRUB_GFXMODE=1280x1024x32,auto
            /^GRUB_THEME=/c\GRUB_THEME=\"/usr/share/grub/themes/${grubtheme}/theme.txt\"
            /^#GRUB_THEME=/c\GRUB_THEME=\"/usr/share/grub/themes/${grubtheme}/theme.txt\"
            /^#GRUB_SAVEDEFAULT=true/c\GRUB_SAVEDEFAULT=true" /etc/default/grub
            [ "${flg_DryRun}" -eq 1 ] || sudo grub-mkconfig -o /boot/grub/grub.cfg
        fi

    else
        print_log -y "[bootloader] " -b "exist :: " "grub is already configured..."
    fi
fi

# systemd-boot
if pkg_installed systemd && nvidia_detect && [ "$(bootctl status 2>/dev/null | awk '{if ($1 == "Product:") print $2}')" == "systemd-boot" ]; then
    print_log -sec "bootloader" -stat "detected" "systemd-boot"

    if [ "$(find /boot/loader/entries/ -type f -name '*.conf.hyde.bkp' 2>/dev/null | wc -l)" -ne "$(find /boot/loader/entries/ -type f -name '*.conf' 2>/dev/null | wc -l)" ]; then
        print_log -g "[bootloader] " -b " :: " "nvidia detected, adding nvidia_drm.modeset=1 to boot option..."
        if [[ "${flg_DryRun}" -ne 1 ]]; then
            find /boot/loader/entries/ -type f -name "*.conf" | while read -r imgconf; do
                sudo cp "${imgconf}" "${imgconf}.hyde.bkp"
                sdopt=$(grep -w "^options" "${imgconf}" | sed 's/\b quiet\b//g' | sed 's/\b splash\b//g' | sed 's/\b nvidia_drm.modeset=.\b//g')
                sudo sed -i "/^options/c${sdopt} quiet splash nvidia_drm.modeset=1" "${imgconf}"
            done
        fi
    else
        print_log -y "[bootloader] " -stat "skipped" "systemd-boot is already configured..."
    fi
fi
