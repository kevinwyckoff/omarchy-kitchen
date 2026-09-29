# Everything the nct6775-notify-dkms tests need: the kernel build (base-devel,
# the headers' own dependencies, sparse), makepkg and DKMS for the package, and
# QEMU plus a static busybox for the VM tests. tests/run.sh builds it as
# kitchen-nct6775-test.
FROM archlinux:latest
RUN pacman -Syu --noconfirm --needed \
      base-devel bc cpio kmod libelf openssl pahole perl python xxhash xz zstd \
      sparse dkms qemu-system-x86 busybox \
 && pacman -Scc --noconfirm
