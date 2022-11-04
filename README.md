# installarch.sh
Create an [Arch Linux](https://archlinux.org) [qemu](https://www.qemu.org) VM in a few clicks. 

Run the script, press "y" to download the install ISO, and hit "enter" when prompted. That's it.

Requires a recent bash and a few dependencies:
`curl` or `wget`, `mkisofs`, `nc`, and of course `qemu-system-x86_64` and `qemu-img`. `sha256sum` is needed if the script downloads the install ISO for you.

KVM is _highly_ recommended. It will work without it, but may be so slow it's not worth it.

Likely to work on any recent Linux distribution with the required dependencies. 

This should work on macOS once bash and qemu are installed via brew. Has not been tested on physical hardware so YMMV.

Windows is not supported.

### Usage

See the top of the script for variables. You can change the disk size, swap size, username, hostname, etc. 

Use the `-vnc` option to run headless. A VNC server will run on localhost:1.

