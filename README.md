```console
# export SDB_PROXY="http://192.168.1.10:8081"
export SDB_APT_RELEASE="jammy"

export SDB_ARCH="amd64"
export SDB_APT_SOURCES_URL="archive.ubuntu.com/ubuntu"
# export SDB_ARCH="arm64"
# export SDB_APT_SOURCES_URL="ports.ubuntu.com/ubuntu-ports"

# sudo is needed temporarily for CAP_MKNOD to create the /dev/ devices
sudo --preserve-env=SDB_PROXY,SDB_ARCH,SDB_APT_SOURCES_URL,SDB_APT_RELEASE ./sdb.bash /mnt/ubuntu
```
