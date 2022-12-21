#!/bin/bash -i
set -e -o pipefail
trap "exit" INT TERM
trap "kill_machine" EXIT
################################################################
#
# Create an Arch Linux qemu VM in two clicks.
#
# Works on Linux and Mac (with homebrew)
#
# You provide:
#   - Arch install ISO (script can download this if not found)
#   - curl or wget
#   - sha256sum (if the script downloads the install ISO)
#   - mkisofs (hditool on mac)
#   - nc
#   - OVMF (optional, script downloads if not found)
#   - qemu, KVM very highly recommended (hvf on macOS)
#
# Set your options below.
# Add an SSH public key to allow passwordless login to your VM.
# Run this script, ./installarch.sh [-vnc]
#    -vnc option runs headless and installs a headless run script
# Press "enter" once at the specified time.
# That's all.
#
################################################################

# Change things in this section

# put the full or relative path to the Arch install ISO here
# the script can attempt to download one if not found
INSTALL_MEDIA="archlinux-2022.07.01-x86_64.iso"

# name of install dir
INSTALL_DIR="arch-install"

# size of the virtual disk in GB
DISK_SIZE=20

# swap size in GB
SWAP_SIZE=0.5

# hostname of the created machine
HOSTNAME="arch-qemu"

# user info
USERNAME="archuser"
SSH_KEY=""

# If you have OVMF files locally
# This is the default location on Arch
OVMF_DIR="/usr/share/OVMF/x64"

# Nothing below here should need to be changed

################################################################

# https://upload.wikimedia.org/wikipedia/commons/1/15/Xterm_256color_chart.svg
red=$(tput setaf 196)
orange=$(tput setaf 178)
yellow=$(tput setaf 226)
green=$(tput setaf 47)
blue=$(tput setaf 75)
norm=$(tput sgr0)

function success () {
    echo -e " ${green}✔${norm} ${1}"
}

function info () {
    echo -e " ${blue}ℹ${norm} ${1}"
}

function warn () {
    echo -e " ${orange}🠪 ${1}${norm}"
}

function danger () {
    echo -e " ${yellow}⚠ ${1}${norm}"
}

function error () {
    echo -e " ${red}! ${1}${norm}"
}

ACCEL=""
MACOS=0
MACHINE_PID="/tmp/qemu-pid.$$"
CHECKSUM_PROGRAM="sha256sum"
MISSING_PROGRAMS=0
NC_CMD_ARG=""
NC_TMPFILE="/tmp/nc-tmp.$$"
QEMU_GA="/tmp/qemu-ga.$$"
VNC=""

function delete_temp_files () {
    info "Removing temp files"
    [[ -f "$NC_TMPFILE" ]] && rm -f "$NC_TMPFILE"
    [[ -f "$MACHINE_PID" ]] && rm -f "$MACHINE_PID"
    [[ -f "${INSTALL_DIR}/tmp_run.sh" ]] && rm -f "${INSTALL_DIR}/tmp_run.sh"
    [[ -f "${INSTALL_DIR}/ia.iso" ]] && rm -f "${INSTALL_DIR}/ia.iso"
    [[ -f "${INSTALL_DIR}/x/ia.sh" ]] && rm -f "${INSTALL_DIR}/x/ia.sh"
    [[ -f "${INSTALL_DIR}/x/vars" ]] && rm -f "${INSTALL_DIR}/x/vars"
    [[ -f "${INSTALL_DIR}/x/install-vars" ]] && rm -f "${INSTALL_DIR}/x/install-vars"
    [[ -d "${INSTALL_DIR}/x" ]] && rmdir "${INSTALL_DIR}/x"
}

function kill_machine () {
    if [[ -f "$MACHINE_PID" ]]; then
        kill "$(cat $MACHINE_PID)"
        rm -f "$MACHINE_PID"
    fi
}

if [[ "${BASH_VERSION:0:1}" -lt 5 ]]; then
    error "Your version of bash is likely too old to run this script."
    error "The default macOS bash won't work. You should install bash via brew."
    error "Then you must explicitly specify it: '${norm}/usr/local/bin/bash installarch.sh${red}'"
    exit 1
fi

if [[ "$1" == "-vnc" ]]; then
    warn "Running headless. VNC server on localhost:1"
    VNC="-vnc localhost:1"
fi

function check_macos () {
    # also sw_vers, is that better?
    if [[ "$(uname -s)" ==  "Darwin" ]]; then
        info "Running on Darwin, assuming macOS"
        MACOS=1
        CHECKSUM_PROGRAM="shasum -a 256" # untested
    fi
}

function check_dl_installed () {
    if [[ -n "$(wget --version 2> /dev/null)" ]]; then
        success "Found wget."
        DL_CMD="wget --quiet --show-progress -O"
    elif [[ -n "$(curl --version 2> /dev/null)" ]]; then
        success "Found curl."
        DL_CMD="curl --progress-bar -Lo"
    else
        error "Couldn't find ${green}curl${red} or ${green}wget${red}."
        warn "Install one of them."
        MISSING_PROGRAMS=1
    fi
}

function check_accel () {

    function no_accel () {
        if [[ $MACOS -eq 1 ]]; then
            DEV="Hypervisor framework"
            VIRT="virtualization"
        else
            DEV="KVM device"
            VIRT="KVM"
        fi
        danger "$DEV not available."
        danger "qemu will probably be unusably slow."
        danger "You should configure $VIRT and try again."
    }

    if [[ $MACOS -eq 1 ]] && [[ "$(sysctl kern.hv_support 2> /dev/null)" =~ 1$ ]]; then
        info "Hardware acceleration available."
        ACCEL=",accel=hvf"
    elif [[ -c /dev/kvm ]]; then
        info "Found /dev/kvm, hardware acceleration likely available."
        ACCEL=",accel=kvm"
    else
        no_accel
        ACCEL=""
    fi
}

function check_mkisofs_installed () {
    if [[ -z $(mkisofs --version 2> /dev/null) ]]; then
        error "Couldn't find ${green}mkisofs${red}."
        warn "Install \"${norm}cdrtools${orange}\", or something like \"${norm}genisoimage, cdrkit, xorriso${orange}\"."
        MISSING_PROGRAMS=1
    else
        success "Found mkisofs."
    fi
}

function check_nc_installed () {

    # e.g. Debian doesn't match either of the below regexes. 
    # it should use BSD style -q 0 but only "problem" if not is
    # connection doesn't close, so the script doesn't keep running (showing "waiting" message)
    # and no one else can connect to the monitor while nc remains connected.
    # (only one open connection at a time to telnet monitor)
    # nmap netcat closes automatically and doesn't need any special argument

    RE_BSD="^OpenBSD"
    RE_GNU="^GNU"

    # use hash because different nc versions have different stderr
    if hash nc 2> /dev/null; then
        success "Found nc."

        nc -h &> "$NC_TMPFILE"

        if [[ "$(head -n 1 $NC_TMPFILE)" =~ ${RE_BSD} ]]; then
            info "Applying args for OpenBSD netcat."
            NC_CMD_ARG="-q 0"
        fi

        if [[ "$(head -n 1 $NC_TMPFILE)" =~ ${RE_GNU} ]]; then
            info "Applying args for GNU netcat."
            NC_CMD_ARG="-c"
        fi

        [[ -f "$NC_TMPFILE" ]] && rm -f "$NC_TMPFILE"
    else
        error "Couldn't find ${green}nc${red}."
        warn "Install the \"${norm}gnu-netcat${orange}\" or \"${norm}openbsd-netcat${orange}\" package."
        MISSING_PROGRAMS=1
    fi
}

function check_qemu_installed () {
    if [[ -n $(/usr/libexec/qemu-kvm --version 2> /dev/null) ]]; then
        QEMU=/usr/libexec/qemu-kvm
        success "Found qemu in /usr/libexec."
    elif [[ -n $(qemu-system-x86_64 --version 2> /dev/null) ]]; then
        QEMU=qemu-system-x86_64
        success "Found qemu-system-x86_64."
    else
        error "Couldn't find ${green}qemu-system-x86_64${red} or ${green}/usr/libexec/qemu-kvm${red}."
        warn "Install a qemu package (\"${norm}qemu-desktop${orange}\" or \"${norm}qemu-full${orange}\")"
        MISSING_PROGRAMS=1
    fi
}

function check_qemu_img () {
    if [[ -n $(qemu-img --version 2> /dev/null) ]]; then
        success "Found qemu-img."
    else
        error "Couldn't find ${green}qemu-img${red}."
        MISSING_PROGRAMS=1
    fi
}

function run_prog_checks () {
    info "Checking for program dependencies..."
    check_dl_installed
    if [[ $MACOS -eq 0 ]]; then
        check_mkisofs_installed
        check_nc_installed
    else
        info "On macOS, assuming hdiutil exists"
        # macOS netcat closes connection w/o extra args
        info "On macOS, assuming netcat exists"
    fi
    check_qemu_installed
    check_qemu_img
    if [[ $MISSING_PROGRAMS -eq 1 ]]; then
        error "Required programs are missing, see above. Quitting."
        exit 1
    fi
    check_accel
}

function check_create_install_dir () {
    info "Creating install directory ${blue}${INSTALL_DIR}${norm}"
    if [[ -d "${INSTALL_DIR}" ]]; then
        error "Install directory ${norm}\"${blue}${INSTALL_DIR}${norm}\"${red} exists, quitting."
        exit 1
    else
        if mkdir "${INSTALL_DIR}"; then
            success "Directory ${blue}${INSTALL_DIR}${norm} created"
        else
            error "Couldn't create ${blue}${INSTALL_DIR}${red}, failing."
            exit 1
        fi
    fi
}

function get_media () {

    LINKS=(
        "https://mirror.arizona.edu/archlinux/iso/latest/"
        "http://arch.mirror.constant.com/iso/latest/"
        "http://mirror.math.princeton.edu/pub/archlinux/iso/latest/"
        "http://mirrors.lug.mtu.edu/archlinux/iso/latest/"
        "http://mirror.mia11.us.leaseweb.net/archlinux/iso/latest/"
    )

    NUMLINKS=${#LINKS[@]}
    SERVER="${LINKS[$((RANDOM % NUMLINKS))]}"

    info "trying server: $SERVER"

    if [[ $(echo "$DL_CMD" | cut -b -4) == "wget" ]]; then
        ISO=$(wget --quiet -O - "${SERVER}sha256sums.txt" | head -n 1)
    else
        ISO=$(curl --silent "${SERVER}sha256sums.txt" | head -n 1)
    fi

    SUM=$(echo "$ISO" | cut -b -64)
    DISC=$(echo "$ISO" | cut -b 67-)

    info "Latest ISO is $DISC."

    if [[ ! -f $DISC ]]; then
        info "Fetching ISO..."
        $DL_CMD "$DISC" "${SERVER}${DISC}"
    else
        info "Latest ISO found in current directory, using it."
    fi

    info "Checking checksum..."

    COMPUTEDSUM=$($CHECKSUM_PROGRAM "$DISC" | cut -b -64)

    if [[ $COMPUTEDSUM != "$SUM" ]]; then
        error "Checksum failed."
        info "Try downloading an ISO from ${norm}https://archlinux.org/download/${orange}."
        exit 1
    else
        success "Checksum OK, proceeding."
        INSTALL_MEDIA="$DISC"
    fi

}

function check_media () {
    if [[ ! -f "${INSTALL_MEDIA}" ]]; then
        error "Install media ${norm}$INSTALL_MEDIA${red} not found."
        warn "Would you like this script to try to download the latest ISO for you?"
        warn "Press \"y\" to try downloading it."
        read -s -r -n 1 ans
        if [[ $ans == "y" ]]; then
            get_media
        else
            error "No install ISO available, quitting."
            info "You may download an ISO from https://archlinux.org/download/"
            info "and set the \$INSTALL_MEDIA variable to point to your ISO."
            exit 1
        fi
    fi
}

function ovmf () {

    function dl () {
        info "OVMF_${1} not found, fetching..."
        if ${DL_CMD} "${INSTALL_DIR}/OVMF_${1}.fd" "https://github.com/clearlinux/common/raw/master/OVMF_${1}.fd"; then
            success "OVMF_${1} downloaded."
        else
            error "Couldn't copy or download UEFI file, quitting."
            exit 1
        fi
    }

    if [[ ! -d "${OVMF_DIR}" ]]; then
        dl "CODE"
        dl "VARS"
    else
        if [[ ! -f "${OVMF_DIR}/OVMF_VARS.fd" ]]; then
            dl "VARS"
        else
            success "Found OVMF_VARS.fd, copying."
            cp "${OVMF_DIR}/OVMF_VARS.fd" "${INSTALL_DIR}"
        fi

        if [[ ! -f "${OVMF_DIR}/OVMF_CODE.fd" ]]; then
            dl "CODE"
        else
            success "Found OVMF_CODE.fd, copying."
            cp "${OVMF_DIR}/OVMF_CODE.fd" "${INSTALL_DIR}"
        fi
    fi
}

# warn if macos
check_macos

# program checks
run_prog_checks

# do we have media?
check_media

# create folder
check_create_install_dir

# create install dir for iso creation
mkdir -p "${INSTALL_DIR}/x"

# put vars files in install dir
touch "${INSTALL_DIR}/x/vars" "${INSTALL_DIR}/x/install-vars"

# populate variables
echo "SWAP=${SWAP_SIZE}" >> "${INSTALL_DIR}/x/vars"
echo "HOSTNAME=${HOSTNAME}" >> "${INSTALL_DIR}/x/install-vars"
echo "USERNAME=${USERNAME}" >> "${INSTALL_DIR}/x/install-vars"
echo "USER_SSH_KEY='${SSH_KEY}'" >> "${INSTALL_DIR}/x/install-vars"

# put install script in install dir
info "Creating install script in install dir"

cat <<'INSTALLFILE' > "${INSTALL_DIR}/x/ia.sh"
#!/bin/bash
set -e -u -o pipefail

. vars

export TERM=xterm-256color

STEP=1

function info () {
    echo -e "$(tput setaf 11)Step ${STEP}$(tput setaf 230) => $(tput setaf 11)${1}$(tput sgr0)"
    ((STEP++))
}

# virtio devices are /dev/vd[x]
DISK=/dev/vda

info "Start ntp"

timedatectl set-ntp true

info "Cleaning up in case this script is being re-run"

info "Unmount..."
[[ $(grep "^/dev/vda1" /proc/mounts) ]] && umount /mnt/efi
[[ $(grep "^/dev/mapper/vg-root" /proc/mounts) ]] && umount /mnt

info "Swapoff..."
[[ -n $(swapon --show) ]] && swapoff /dev/vg/swap

info "Delete lvm..."
if [[ -n $(lvscan | grep swap) ]]; then
    lvchange -an /dev/vg/swap
    lvremove /dev/vg/swap
fi
if [[ -n $(lvscan | grep root) ]]; then
    lvchange -an /dev/vg/root
    lvremove /dev/vg/root
fi
[[ -n $(vgscan) ]] && vgremove vg
[[ -z $(pvscan | grep '^  No') ]] && pvremove ${DISK}2

info "wipefs on disk and partitions..."
wipefs -af ${DISK} &> /dev/null || true
wipefs -af ${DISK}1 &> /dev/null || true
wipefs -af ${DISK}2 &> /dev/null || true

info "partx -u ${DISK}..."
partx -u ${DISK} &> /dev/null || true

info "Format with gdisk"
(
echo o      # delete all partitions
echo y      # confirm
echo n      # new partition
echo        # default number 1
echo        # default start sector
echo +512M  # 512M EFI partition
echo ef00   # EFI partition type
echo n      # new partition
echo        # default number 2
echo        # default start sector
echo        # default end sector (entire disk)
echo 8e00   # LVM type
echo w      # write the partition table
echo y      # confirm write
) | gdisk ${DISK} > /dev/null

info "partx -u ${DISK}"
partx -u ${DISK}

info "wipefs on partitions in case reinstall"
wipefs -af ${DISK}1 &> /dev/null || true
wipefs -af ${DISK}2 &> /dev/null || true

### LVM
info "LVM: Create physical volume"
pvcreate ${DISK}2

info "LVM: Create volume group"
vgcreate vg ${DISK}2

info "LVM: Create logical volumes"
lvcreate -Wn -L "${SWAP}G" vg -n swap
lvcreate -Wn -l 100%FREE vg -n root

info "Format disks"
mkfs.fat -F32 ${DISK}1 > /dev/null
# force creation of new filesystem
mkfs.ext4 -F /dev/vg/root > /dev/null

info "Set up swap"
mkswap /dev/vg/swap
swapon /dev/vg/swap

info "Mount partitions"
mount /dev/vg/root /mnt
mkdir /mnt/efi && mount ${DISK}1 /mnt/efi

info "Wait for pacman-init service to start. This can take a long time."
function check_pacman () {
    if ! systemctl show --no-pager pacman-init.service | grep -qx ActiveState=active; then
        echo -n "."
        sleep 1
        check_pacman
    else
        echo ""
    fi
}

check_pacman

info "Update archlinux-keyring"
pacman --noconfirm -Sy archlinux-keyring

info "pacstrap"
if ! pacstrap /mnt base linux; then
    echo "$(tput setaf 196)Something is wrong. Couldn't install base system."
    echo "Bailing out, try either running the script again"
    echo "or manually completing install.$(tput sgr0)"
    exit 1
fi

info "Generate fstab"
genfstab -U /mnt >> /mnt/etc/fstab

info "Copy other install files to new root"
cp install-vars /mnt

cat <<'EOF' > /mnt/moreinst.sh
#!/bin/bash
set -e -u -o pipefail

. install-vars

export TERM=xterm-256color

STEP=1

function info () {
    echo -e "$(tput setaf 48)Step ${STEP}$(tput setaf 230) => $(tput setaf 48)${1}$(tput sgr0)"
    ((STEP++))
}

echo -e "$(tput setaf 48)Running install script in chroot$(tput sgr0)"

info "Set timezone: America/New_York"
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime

info "Set clock"
hwclock --systohc

info "Set LANG=en_US.UTF-8 and update locale.gen"
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

info "Set hostname to ${HOSTNAME}"
echo "${HOSTNAME}" > /etc/hostname

info "Full-system update, can avoid problems w/Grub"
pacman --noconfirm -Syu

PROGS="efibootmgr ethtool gdisk grub htop inetutils linux-headers lvm2 nfs-utils nmap openssh sudo tcpdump usbutils vim wget zsh"
info "Install some programs: ${PROGS}"
pacman --noconfirm -S ${PROGS}

info "Disable auditing: audit=0"
sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="audit=0"/' /etc/default/grub

info "Install grub: grub-install && grub-mkconfig"
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB > /dev/null
grub-mkconfig -o /boot/grub/grub.cfg > /dev/null

info "Add LVM hook to mkinitcpio.conf"
sed -i '/^HOOKS=/ s/block file/block lvm2 file/' /etc/mkinitcpio.conf

info "Make init cpio"
mkinitcpio -P > /dev/null

info "Aliases"
cat <<EOFF > /etc/profile.d/nice-aliases.sh
alias confgrep="grep -v '^#\|^$'"
alias diff="diff --color=auto"
alias grep="grep --color=auto"
alias ip="ip --color=auto"
alias ls="ls --color=auto"
alias lsd="ls --group-directories-first"
EOFF

# quick and dirty way to make vim the default vi
info "Link vim to vi"
ln -s /usr/bin/vim /usr/bin/vi

info "Enable systemd networking"
cat <<NETCONFIG > /etc/systemd/network/en.network
[Match]
Name=en*

[Network]
DHCP=yes
DNSSEC=no
NETCONFIG
systemctl enable systemd-networkd
systemctl enable systemd-resolved

info "Enable sshd"
systemctl enable sshd

info "Add ip address to banner"
echo "\4" >> /etc/issue
echo >> /etc/issue

info "Add a user, set them up w/ssh key and zsh"
useradd -m -s /bin/zsh -G wheel "${USERNAME}"
(
echo asdf
echo asdf
) | passwd "${USERNAME}" > /dev/null

mkdir -p /home/"${USERNAME}"/.ssh
chmod 700 /home/"$USERNAME"/.ssh
echo "${USER_SSH_KEY}" > /home/"${USERNAME}"/.ssh/authorized_keys
chmod 600 /home/"$USERNAME"/.ssh/authorized_keys

cat <<'ENDZSH' > /home/"${USERNAME}"/.zshrc
# https://wiki.archlinux.org/index.php/SSH_keys#SSH_agents
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
    ssh-agent > ~/.ssh-agent-running
fi
if [[ "$SSH_AGENT_PID" == "" ]]; then
    eval "$(<~/.ssh-agent-running)"
fi

case $TERM in
    xterm*)
        precmd () {print -Pn "\e]0;%n@%m:%~\a"}
        ;;
esac

eval $(dircolors -b)

export EDITOR="vim"
export HISTFILE=~/.zsh_history
export HISTFILESIZE=1000000000
export HISTSIZE=1000000000
export HISTTIMEFORMAT="%a %b %d %R "
export PROMPT='%B%F{47}%n%f%b@%B%F{208}%m%f%b %B%F{199}%~%f%b %# '
export RPROMPT='%B%F{69}%D{%H:%M:%S}%f%b'
export SAVEHIST=10000
export TERM=xterm-256color
export VISUAL="vim"

setopt INC_APPEND_HISTORY
setopt EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt CORRECT

bindkey "^A" beginning-of-line
bindkey "^E" end-of-line
bindkey "^R" history-incremental-search-backward
bindkey "^[[3~" delete-char

. /etc/profile.d/nice-aliases.sh
alias bc="bc -l"
alias dmesg="dmesg -T"
alias history="history -i 1"
alias screen="screen -q"
function ccd { mkdir -p "$1" && cd "$1" }
ENDZSH

chown -R "${USERNAME}":"${USERNAME}" /home/"${USERNAME}"

sed -i '/NOPASSWD/s/^#.//g' /etc/sudoers

info "Set root pw"
(
echo root
echo root
) | passwd root > /dev/null

info "Remove this script and exit chroot"

rm moreinst.sh
rm install-vars

exit

EOF

chmod 755 /mnt/moreinst.sh

info "chroot and execute install script"

echo -e "$(tput setaf 11)Entering chroot...$(tput sgr0)"

arch-chroot /mnt ./moreinst.sh

echo -e "$(tput setaf 11)Chroot done, shutting down.$(tput sgr0)"

sleep 2

umount /root/x
umount /mnt/efi
umount /mnt

I=10

echo -e "$(tput setaf 11)Shutting down in 10 seconds..."
echo -ne "$I"
sleep 0.3
((I--))
while [[ $I -gt 0 ]]; do
    echo -n "."
    sleep 0.3
    echo -n "."
    sleep 0.3
    echo -n "."
    sleep 0.3
    echo -n "$I"
    sleep 0.3
    ((I--))
done
tput sgr0

shutdown -h now

INSTALLFILE

info "Creating startup script for completed machine"
cat <<'RUNFILE' > "${INSTALL_DIR}/run.sh"
#!/bin/bash

ACCEL=""
CPU=""
MONITOR="vc"
VNC=""

if [[ -n $VNC ]]; then
    echo "Running headless, VNC server on localhost:1, monitor on localhost:3456"
    MONITOR="telnet:localhost:3456,server,nowait"
fi

if [[ $ACCEL == ",accel=kvm" ]]; then
    CPU="-cpu host"
fi

function run_machine () {
    qemu-system-x86_64 \
        -name arch \
        -nodefaults \
        -monitor ${MONITOR} \
        -machine type=q35${ACCEL} \
        ${CPU} \
        -m 1024 \
        -device virtio-rng-pci \
        -device virtio-gpu \
        -device qemu-xhci,id=xhci \
        -device usb-tablet \
        -drive id=disk0,if=virtio,format=raw,file=arch.img,media=disk \
        -drive media=cdrom \
        -netdev user,id=net0 \
        -device virtio-net-pci,id=nic0,netdev=net0 \
        ${VNC} \
        -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=OVMF_VARS.fd 
}

run_machine
RUNFILE

function edit_runfile () {
    if [[ -n $VNC ]]; then
        # no "sed -i" on macos...
        sed 's/VNC=""/VNC="-vnc localhost:1"/' "${INSTALL_DIR}/run.sh" > "${INSTALL_DIR}/tmp_run.sh" && mv -f "${INSTALL_DIR}/tmp_run.sh" "${INSTALL_DIR}/run.sh"
    fi

    if [[ -n $ACCEL ]]; then
        sed "s/ACCEL=\"\"/ACCEL=\"${ACCEL}\"/" "${INSTALL_DIR}/run.sh" > "${INSTALL_DIR}/tmp_run.sh" && mv -f "${INSTALL_DIR}/tmp_run.sh" "${INSTALL_DIR}/run.sh"
    fi

    # in case it's libexec CentOS/Fedora version...
    if [[ $QEMU != "qemu-system-x86_64" ]]; then
        sed "s#qemu-system-x86_64#$QEMU#" "${INSTALL_DIR}/run.sh" > "${INSTALL_DIR}/tmp_run.sh" && mv -f "${INSTALL_DIR}/tmp_run.sh" "${INSTALL_DIR}/run.sh"
    fi
}

edit_runfile 

chmod 755 "${INSTALL_DIR}/run.sh"

# create iso from install script
info "Creating script install iso"
cd "${INSTALL_DIR}"
if [[ $MACOS -eq 1 ]]; then
    hdiutil makehybrid -quiet -iso -joliet -o ia.iso x
else
    mkisofs -quiet -r -V IA -o ia.iso x
fi
cd - > /dev/null

# create virtual hard drive
info "Creating virtual hard drive (${DISK_SIZE}GB)"
qemu-img create -f raw "${INSTALL_DIR}/arch.img" ${DISK_SIZE}G > /dev/null

# set up ovmf (UEFI files)
ovmf

# setup for the qemu machine

# -cpu=host requires KVM
function run_machine () {

    CPU=""

    if [[ $ACCEL == ",accel=kvm" ]]; then
        CPU="-cpu host"
    fi

    "$QEMU" \
        -name arch-installer \
        -nodefaults \
        -monitor telnet:localhost:3456,server,nowait \
        -machine type=q35${ACCEL} \
        ${CPU} \
        -m 1024 \
        -device virtio-rng-pci \
        -device virtio-gpu \
        -device qemu-xhci,id=xhci \
        -device usb-tablet \
        -device virtio-serial \
        -chardev socket,path=${QEMU_GA},server=on,wait=off,id=qemu-ga \
        -device virtserialport,chardev=qemu-ga,name=org.qemu.guest_agent.0 \
        -drive id=disk0,if=virtio,format=raw,file="${INSTALL_DIR}"/arch.img,media=disk \
        -drive file="${INSTALL_MEDIA}",media=cdrom \
        -drive file="${INSTALL_DIR}"/ia.iso,media=cdrom \
        -netdev user,id=net0 \
        -device virtio-net-pci,id=nic0,netdev=net0 \
        ${VNC} \
        -drive if=pflash,format=raw,readonly=on,file="${INSTALL_DIR}"/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file="${INSTALL_DIR}"/OVMF_VARS.fd &

    echo $! > "$MACHINE_PID"

}

info "Starting machine"
( run_machine )

# Thanks to
# https://github.com/mvidner/sendkeys
# and 
# https://github.com/myspaghetti/macos-virtualbox
function send_keys () {

    function sub_fn () {

        declare -gA KEYS

        KEYS=(
          # ASCII-sorted
          [" "]="spc"
          ["!"]="shift-1"
          ['"']="shift-apostrophe"
          ["#"]="shift-3"
          ["$"]="shift-4"
          ["%"]="shift-5"
          ["&"]="shift-7"
          ["'"]="apostrophe"
          ["("]="shift-9"
          [")"]="shift-0"
          ["*"]="shift-8"
          ["+"]="shift-equal"
          [","]="comma"
          ["-"]="minus"
          ["."]="dot"
          ["/"]="slash"
          [":"]="shift-semicolon"
          [";"]="semicolon"
          ["<"]="shift-comma"
          ["="]="equal"
          [">"]="shift-dot"
          ["?"]="shift-slash"
          ["@"]="shift-2"
          ["["]="bracket_left"
          ['\']="backslash"
          ["]"]="bracket_right"
          ["^"]="shift-6"
          ["_"]="shift-minus"
          ['`']="grave_accent"
          ["{"]="shift-bracket_left"
          ["|"]="shift-backslash"
          ["}"]="shift-bracket_right"
          ["~"]="shift-grave_accent"
        )

        re='<([a-z_]+)>'

        for (( i=0; i < ${#str}; i++ )); do

            # this works for the one string I need, that's good enough for this purpose

            # if we find "<"
            if [[ ${str:${i}:1} == "<" ]]; then
                # if also matching closing ">" w/in pattern
                if [[ ${str:${i}} =~ $re ]]; then
                    # send special code
                    if [[ ${BASH_REMATCH[1]} == "lt" ]]; then
                        echo "sendkey shift-comma"
                    elif [[ ${BASH_REMATCH[1]} == "gt" ]]; then
                        echo "sendkey shift-dot"
                    else
                        echo "sendkey ${BASH_REMATCH[1]}"
                    fi
                    # move pointer past entire thing
                    # capture len + 2 brackets - 1 for zero indexing
                    new_idx=$(( ${#BASH_REMATCH[1]}+1 ))
                    i=$((i+new_idx))
                fi
            else
                echo "sendkey ${KEYS[${str:${i}:1}]:-${str:${i}:1}}"
            fi
        done
        sleep 0.5
    }

    sub_fn | nc ${NC_CMD_ARG} localhost 3456 > /dev/null
}

warn "Wait for the \"${red}root${norm}@archiso ~ #${orange}\" prompt."
sleep 5
warn "Press enter in THIS terminal window when you see that prompt."
read -sr input
if [[ $input == "" ]]; then
    str='mkdir x && mount -o ro /dev/sr1 x && cp x/ia.sh x/vars x/install-vars . && chmod 755 ia.sh && ./ia.sh<ret>'
    send_keys
fi

info "Waiting for install to complete."

function wait_for_end () {
    if echo "info block" | nc ${NC_CMD_ARG} localhost 3456 > /dev/null 2>&1; then
        sleep 1
        wait_for_end
    else
        success "Install complete"
    fi
}

wait_for_end

delete_temp_files

info "To run your new machine, do \"cd ${blue}${INSTALL_DIR}${norm}\", \"./${green}run.sh${norm}\"."
