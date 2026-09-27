# QEMU test harness

Small helpers for driving the ISO and installed systems in QEMU from a shell, used for every row in the spec. They talk to QEMU's QMP socket over TCP, so start the VM with `-qmp tcp:127.0.0.1:4444,server,nowait`.

| Script | What it does |
|---|---|
| `keys.py <host:port> <item>...` | Types into the VM. An item is `text:<literal>` or a key or combo such as `ret`, `tab`, `down`, `esc`, `ctrl-c`, `spc`. |
| `shot.py <host:port> <out.png>` | Takes a screenshot (QMP `screendump`, converted to PNG with the Python standard library only). |
| `step.sh <name> <wait> [keys...]` | Sends keys, waits, and saves `./<name>.png`. Set `QMP=host:port` for a non-default socket. |

## Booting

UEFI with Ubuntu's firmware files (Arch keeps them under `/usr/share/edk2/x64/`):

```bash
cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd
qemu-img create -f qcow2 disk.qcow2 40G
qemu-system-x86_64 -cpu host -enable-kvm -machine q35 -smp 8 -m 8192 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file=disk.qcow2,format=qcow2,if=none,id=target \
  -device virtio-blk-pci,drive=target,serial=KITCHEN-A \
  -device qemu-xhci \
  -drive file=cidata.img,format=raw,if=none,id=stick -device usb-storage,drive=stick \
  -drive file=omarchy.iso,media=cdrom,if=none,format=raw,id=cd -device ide-cd,drive=cd \
  -device virtio-vga -display gtk \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
  -qmp tcp:127.0.0.1:4444,server,nowait
```

- `serial=` on the virtio disk is what `install.toml` selectors match. A SCSI `product=` is limited to 16 characters.
- Don't set `bootindex` on the CD: OVMF then drops the boot entry the installer registered. Leave it off and the firmware falls through to the CD while the disk is blank, then boots Limine after the install.
- QMP `eject` takes `device`, not `id`.
- With the GTK display, an odd window width skews the guest picture diagonally. Pin the guest resolution if it happens.
- For a USB stick image, `mkfs.vfat -C -n KITCHEN stick.img 32768` and `mcopy -i stick.img file ::/` (dosfstools and mtools) need no root.

## Secure Boot rows

- **Firmware:** Ubuntu's `OVMF_CODE_4M.fd` is built with Secure Boot, and enforces it, without SMM. Use it on WSL2, where nested KVM can't run the SMM build (`OVMF_CODE_4M.secboot.fd` fails with `KVM: entry failed`). SMM only protects the variable store from the guest OS, which the rows don't test.
- **Firmware-menu steps:** do them offline on the vars file with `virt-fw-vars` (`pip install virt-firmware`, in a venv):
  - vendor keys with Secure Boot off: `virt-fw-vars -i vars.fd --enroll-microsoft --microsoft-kek all --microsoft-db all --set-false SecureBootEnable -o vars-ms.fd`
  - the user deleting only the PK: `virt-fw-vars --inplace vars.fd -d PK`
  - turning Secure Boot on: `virt-fw-vars --inplace vars.fd --set-true SecureBootEnable`
- **Destructive rows:** run them on a throwaway overlay (`qemu-img create -f qcow2 -b base.qcow2 -F qcow2 row.qcow2`) with a copy of the vars file.

## Serial consoles and the LUKS prompt

`-serial file:…` is handy for grepping boot messages, but it changes what boots. With a serial port present, systemd-stub appends `console=uart,io,0x3f8 console=tty0` to the kernel command line, and Plymouth then drops to its text "details" mode. That mode reads keys through the tty, and so through the kernel keymap, whatever the initramfs says about XKB.
- Any row that tests **which keyboard layout the LUKS prompt uses** must boot with `-serial none` and screenshot the graphical prompt. With a serial port, a broken layout still unlocks.
- Use a character that differs between the console keymap and the XKB layout (for `no-latin1`, `$` is Shift+4 on the console and AltGr+4 in XKB `no`), and try both.
- Boot-time initramfs errors reach only the console, never the journal. Grep the serial log for them; a `journalctl` grep can never match.

## Driving a machine over SSH

Used for the live installer (`omarchy-iso-remote`, on the private `live-ssh` branch) and for installed systems. Drive interactive prompts with Python `pexpect` over `ssh -tt`.

- gum's confirm prompts end with a `←→ toggle` help line. Match `toggle`: a `yes.*no` pattern misses them, because escape sequences sit between the buttons.
- sudo on current Arch emits OSC 3008 session markers on the same line as the next output. Strip `\x1b]3008;...(\x07|\x1b\\)` before filtering lines, or you drop real output.
- `pi -p` waits on an open standard input. Run it with `</dev/null` in scripts.
- `pkill -f 'pattern'` sent through ssh matches the ssh command line itself and kills it. Use bracket patterns like `'[c]hefs'`.
- The live ISO gets a different DHCP lease from the installed system. On the LAN it answers as `archiso.local` (`Resolve-DnsName archiso.local` from Windows PowerShell).
- To boot a USB stick on a remote machine without a keypress, set `efibootmgr --bootnext` to the firmware's own `UEFI: <stick>` entry. It appears once the stick has been present at boot. A hand-made `HD(MBR)` entry was ignored on AMI firmware.
