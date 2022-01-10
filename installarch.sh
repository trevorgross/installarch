
#!/bin/bash -i
set -e -o pipefail
################################################################
#
# Install Arch Linux in two clicks.
# You provide:
#   - working qemu install
#   - 16+GB disk space
#   - Arch install ISO
#   - OVMF (optional, script downloads if not found)
#   - nc
#   - mkisofs (hditool on mac)
#   - curl or wget
#
# MacOS has its own requirements that this script tries to handle.
#
# You MUST paste in your ssh public key for installation on the 
# created machine, or you won't be able to log in to it thru ssh.
#
# Run this script, ./installarch.sh [-vnc]
#    -vnc option runs headless and installs a headless run script
# Press "enter" once at the specified time.
# That's all.
#
################################################################

# put the full or relative path to the Arch install ISO here:
INSTALL_MEDIA="archlinux-2022.01.01-x86_64.iso"

# size of the virtual disk in GB
DISK_SIZE=20

# swap size in GB
SWAP_SIZE=2

# user info
USERNAME=archuser
SSH_KEY=""

# name of install dir
INSTALL_DIR="arch-install"

# Where are UEFI files? This is the default on Arch
OVMF_DIR="/usr/share/OVMF/x64"

# https://upload.wikimedia.org/wikipedia/commons/1/15/Xterm_256color_chart.svg
red=$(tput setaf 196)
orange=$(tput setaf 178)
yellow=$(tput setaf 226)
green=$(tput setaf 47)
blue=$(tput setaf 75)
white=$(tput setaf 15)
norm=$(tput sgr0)

success () {
    echo -e " ${green}✔${norm} ${1}"
}

info () {
    echo -e " ${blue}ℹ${norm} ${1}"
}

warn () {
    echo -e " ${orange}🠪 ${1}${norm}"
}

error () {
    echo -e " ${red}! ${1}${norm}"
}

VNC=""

if [[ $1 == '-vnc' ]]; then
    warn "Running headless. VNC server on localhost:1"
    VNC="-vnc :1"
fi

MACOS=0

function check_macos () {
    # also sw_vers, is that better?
    if [[ "$(uname -s)" ==  "Darwin" ]]; then
        info "Running on Darwin, assuming MacOS"
        MACOS=1
    fi
    if [[ $MACOS == 1 && "${BASH_VERSION:0:1}" -lt 5 ]]; then
        error "MacOS detected, install a newer bash (e.g. brew install bash) if you haven't already."
        error "Then you must explicitly specify it: '/usr/local/bin/bash installarch.sh'"
        exit 1
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
        exit 1
    fi
}

function check_mkisofs_installed () {
    if [[ -z $(mkisofs --version 2> /dev/null) ]]; then
        error "Couldn't find ${green}mkisofs${red}."
        warn "Install the \"${norm}cdrtools${orange}\" package."
        exit 1
    else
        success "Found mkisofs."
    fi
}

function check_nc_installed () {

    # There are many different versions of nc and they're a disaster.
    # No consistent options existence or handling, no consistency
    # with what gets sent to stdout and stderr.
    # Assumptions must be made WRT MacOS, this tries to catch
    # other common scenarios

    NC_CMD=''

    if [[ -z $(nc -h 2> /dev/null) ]]; then
        nc -h 2> /tmp/nc-tmpfile
        re='^OpenBSD'
        if [[ "$(head -n 1 /tmp/nc-tmpfile)" =~ ${re} ]]; then
            success "Found nc (OpenBSD)."
            [[ -f /tmp/nc-tmpfile ]] && rm /tmp/nc-tmpfile
        else 
            error "Couldn't find ${green}nc${red}."
            warn "Install the \"${norm}gnu-netcat${orange}\" package."
            exit 1
        fi
    else
        success "Found nc."
        re='^GNU'
        if [[ "$(nc -h 2> /dev/null | head -n 1)" =~ ${re} ]]; then
            info "Applying GNU workaround for nc"
            NC_CMD="-c"
        fi
    fi
}

function check_qemu_installed () {
    if [[ -z $(qemu-system-x86_64 --version 2> /dev/null) ]]; then
        error "Couldn't find ${green}qemu-system-x86_64${red}."
        warn "Install the \"${norm}qemu${orange}\" package."
        exit 1
    else
        success "Found qemu-system-x86_64."
    fi
}

function run_prog_checks () {
    check_dl_installed
    if [[ $MACOS == 0 ]]; then
        check_mkisofs_installed
        check_nc_installed
    else
        info "On MacOS, assuming hdiutil exists"
        info "On MacOS, assuming netcat exists"
    fi
    check_qemu_installed
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

function check_media () {
    if [[ ! -f "${INSTALL_MEDIA}" ]]; then
        error "No install media found."
        warn "Correct the ${norm}\$INSTALL_MEDIA${orange} variable to point to your ISO, or..."
        warn "visit ${norm}https://archlinux.org/download/${orange} and download an ISO."
        exit 1
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

# populate swap files
echo "SWAP=${SWAP_SIZE}" >> "${INSTALL_DIR}/x/vars"
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

info "Formatting: wipefs and gdisk"

wipefs -af ${DISK}

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

# on off chance this is a reinstall
info "wipefs on individual partitions"
wipefs -af ${DISK}1
wipefs -af ${DISK}2

### LVM
info "LVM: Create physical volume"
pvcreate ${DISK}2

info "LVM: Create volume group"
vgcreate vg ${DISK}2

info "LVM: Create logical volumes"
lvcreate -L "${SWAP}G" vg -n swap
lvcreate -l 100%FREE vg -n root

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

info "update package databases"
pacman -Syy

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

HOSTNAME=arch-qemu

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

PROGS="dhcpcd efibootmgr ethtool gdisk grub htop inetutils linux-headers lvm2 nfs-utils nmap openssh sudo tcpdump usbutils vim wget zsh"
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
alias diff='diff --color=auto'
alias grep='grep --color=auto'
alias ip='ip --color=auto'
alias ls='ls --color=auto'
alias lsd='ls --group-directories-first'
EOFF

# quick and dirty way to make vim the default vi
info "Link vim to vi"
ln -s /usr/bin/vim /usr/bin/vi

info "Using dhcpcd for simplicity, systemd-networkd was not reliable"
systemctl enable dhcpcd

info "SSH: disallow root login, disallow keyboard interactive auth"
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

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

mkdir /home/"${USERNAME}"/.ssh
echo "${USER_SSH_KEY}" > /home/"${USERNAME}"/.ssh/authorized_keys

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

export EDITOR='vim'
export HISTFILE=~/.zsh_history
export HISTFILESIZE=1000000000
export HISTSIZE=1000000000
export HISTTIMEFORMAT="%a %b %d %R "
export PROMPT='%B%F{47}%n%f%b@%B%F{208}%m%f%b %B%F{199}%~%f%b %# '
export RPROMPT='%B%F{69}%D{%H:%M:%S}%f%b'
export SAVEHIST=10000
export VISUAL='vim'

setopt INC_APPEND_HISTORY
setopt EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt CORRECT

bindkey "^A" beginning-of-line
bindkey "^E" end-of-line
bindkey "^R" history-incremental-search-backward
bindkey "^[[3~" delete-char

. /etc/profile.d/nice-aliases.sh
alias bc='bc -l'
alias dmesg="dmesg -T"
alias history='history -i 1'
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
umount x

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

ACCEL="kvm"
CPU="-cpu host"
VNC=""
MONITOR="vc"

if [[ ! -z $VNC ]]; then
    echo "Running headless, VNC server on localhost:1, monitor on localhost:3456"
    MONITOR="telnet:localhost:3456,server,nowait"
fi

if [[ $ACCEL == "hvf" ]]; then
    echo "Running on MacOS, using HVF"
    CPU=""
fi

function run_machine () {
    qemu-system-x86_64 \
        -name arch \
        -nodefaults \
        -monitor ${MONITOR} \
        -machine type=q35,accel=${ACCEL} \
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
        if [[ $MACOS == 1 ]]; then
            sed 's/VNC=""/VNC="-vnc :1"/' "${INSTALL_DIR}/run.sh" > "${INSTALL_DIR}/tmp_run.sh" && mv "${INSTALL_DIR}/tmp_run.sh" "${INSTALL_DIR}/run.sh"
        else
            sed -i 's/VNC=""/VNC="-vnc :1"/' "${INSTALL_DIR}/run.sh"
        fi
    fi

    if [[ $MACOS == 1 ]]; then
        sed 's/ACCEL="kvm"/ACCEL="hvf"/' "${INSTALL_DIR}/run.sh" > "${INSTALL_DIR}/tmp_run.sh" && mv "${INSTALL_DIR}/tmp_run.sh" "${INSTALL_DIR}/run.sh"
    fi
}

edit_runfile 

chmod 755 "${INSTALL_DIR}/run.sh"

# create iso from install script
info "Creating script install iso"
cd "${INSTALL_DIR}"
if [[ $MACOS = 1 ]]; then
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

# MacOS is accel=hvf, but this doesn't work inside virtual machine. No mac hardware to test on.
# -cpu=host requires KVM, can't have this in mac 
function run_machine () {

    RUNCPU="-cpu host"
    ACCEL="kvm"

    if [[ $MACOS == 1 ]]; then
        RUNCPU=''
        ACCEL='hvf'
    fi

    qemu-system-x86_64 \
        -name arch \
        -nodefaults \
        -monitor telnet:localhost:6661,server,nowait \
        -machine type=q35,accel=${ACCEL} \
        ${RUNCPU} \
        -m 1024 \
        -device virtio-rng-pci \
        -device virtio-gpu \
        -device qemu-xhci,id=xhci \
        -device usb-tablet \
        -drive id=disk0,if=virtio,format=raw,file="${INSTALL_DIR}"/arch.img,media=disk \
        -drive file="${INSTALL_MEDIA}",media=cdrom \
        -drive file="${INSTALL_DIR}"/ia.iso,media=cdrom \
        -netdev user,id=net0 \
        -device virtio-net-pci,id=nic0,netdev=net0 \
        ${VNC} \
        -drive if=pflash,format=raw,readonly=on,file="${INSTALL_DIR}"/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file="${INSTALL_DIR}"/OVMF_VARS.fd 
}

info "Starting machine"
( run_machine & )

# Thanks to
# https://github.com/mvidner/sendkeys
# and 
# https://github.com/myspaghetti/macos-virtualbox
function send_keys () {

    function sub_fn () {

        # require a newer version of bash on macos. brew install bash and explicitly
        # specify /usr/local/bin/bash in first line

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

        # could be useful: https://www.rexegg.com/regex-anchors.html#G

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

    sub_fn | nc ${NC_CMD} localhost 6661 > /dev/null
}

warn "Wait for the \"${red}root${norm}@archiso ${white}~${norm} #${orange}\" prompt."
sleep 5
warn "Press enter in THIS terminal window when you see that prompt."
read -sr input
if [[ $input == "" ]]; then
    str='mkdir x && mount -o ro /dev/sr1 x && cp x/ia.sh x/vars x/install-vars . && chmod 755 ia.sh && ./ia.sh<ret>'
    send_keys
fi

info "Waiting for install to complete."

function wait_for_end () {
    if $(echo "info block" | nc ${NC_CMD} localhost 6661 > /dev/null 2>&1); then
        sleep 1
        wait_for_end
    else
        success "Install complete"
    fi
}

wait_for_end

info "Removing temp files"
[[ -f /tmp/nc-tmpfile ]] && rm /tmp/nc-tmpfile
[[ -f "${INSTALL_DIR}/tmp_run.sh" ]] && rm "${INSTALL_DIR}/tmp_run.sh"
[[ -f "${INSTALL_DIR}/ia.iso" ]] && rm "${INSTALL_DIR}/ia.iso"
[[ -f "${INSTALL_DIR}/x/ia.sh" ]] && rm "${INSTALL_DIR}/x/ia.sh"
[[ -f "${INSTALL_DIR}/x/vars" ]] && rm "${INSTALL_DIR}/x/vars"
[[ -f "${INSTALL_DIR}/x/install-vars" ]] && rm "${INSTALL_DIR}/x/install-vars"
[[ -d "${INSTALL_DIR}/x" ]] && rmdir "${INSTALL_DIR}/x"

info "To run your new machine, do \"cd ${blue}${INSTALL_DIR}${norm}\", \"./${green}run.sh${norm}\"."
