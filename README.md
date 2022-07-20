# installarch.sh
Create an [Arch Linux](https://archlinux.org) [qemu](https://www.qemu.org) VM in a few clicks.

Requires a recent bash and a few dependencies:
`curl` or `wget`, `mkisofs`, `nc`, and of course `qemu-system-x86_64` and `qemu-img`. `md5sum` is needed if the script downloads the install ISO for you.

This should work on macOS once bash and qemu are installed via brew. Has not been tested on physical hardware so YMMV.
