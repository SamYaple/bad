```console
$ export BAD_PROXY="http://192.168.1.10:8081"
$ export BAD_APT_RELEASE="jammy"
$ export BAD_ARCH="amd64"
$ export BAD_APT_SOURCES_URL="archive.ubuntu.com/ubuntu"
$ # export BAD_ARCH="arm64"
$ # export BAD_APT_SOURCES_URL="ports.ubuntu.com/ubuntu-ports"
$ # sudo is needed temporarily for CAP_MKNOD to create the /dev/ devices
$ sudo --preserve-env=BAD_PROXY,BAD_ARCH,BAD_APT_SOURCES_URL,BAD_APT_RELEASE ./bad.bash /mnt/ubuntu
########
# All Done!
#
# Target directory ("/mnt/ubuntu")
# has been bootstrapped with dpkg/apt, but not an init system.
#
# Use 'systemd-nspawn -D "/mnt/ubuntu" bash' to spawn a shell
########

real    0m12.540s
user    0m6.044s
sys     0m1.980s
```
