# Board setup: KV260 with Ubuntu 22.04 and Kria-PYNQ

Steps 2 to 5 run their notebooks on the board, under Ubuntu with PYNQ. This is a one-time setup. Step 1 (`hello_kria`) and the bare-metal part of step 2 only need JTAG and the UART, see [setup_host.md](setup_host.md).

## Tested setup

| Item | Version |
|---|---|
| Board | KV260 Starter Kit (SOM SMK-K26-XCL2G, carrier SCK-KV-G rev 1) |
| Boot firmware (QSPI) | `BOOT_xilinx-k26-starterkit-v2022.1-09152304_update3.BIN` |
| OS | Ubuntu 22.04.4 LTS for Kria, image `iot-limerick-kria-classic-desktop-2204-20240304-165.img.xz`, fully upgraded with `apt` |
| PYNQ | Kria-PYNQ from `github.com/Xilinx/Kria-PYNQ` (`main`, installed 2026-09-30), Python 3.10 venv in `/usr/local/share/pynq-venv` |
| Webcam | Logitech C170 (USB, UVC), YUYV 640×480 at 30 fps |
| SD card | 32 GB microSD |
| Power | **the original 12 V supply of the kit** (a weaker one causes a boot loop, see Troubleshooting) |

## 1. Boot firmware

Ubuntu 22.04 does not boot with the original 2021 firmware. Check it first. Any Linux on the board works for this, for example the PetaLinux 2021.1 card shipped with the kit (user `petalinux`, it asks for a new password at first login):

```sh
sudo xmutil bootfw_status
```

If the version line shows `XilinxSom_QspiImage_v1.1_20210422` or anything older than 2022.1, update it:

1. Download the latest K26 **Starter Kit** boot firmware from the *Kria SOM Boot Firmware Update* page of the AMD wiki (https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/3020685316/Kria+SOM+Boot+Firmware+Update). You need a free AMD account. The minimum version is `2022.1_update3`.
2. Copy it to the board and write it to the inactive QSPI slot:
   ```sh
   sudo xmutil bootfw_update -i BOOT_xilinx-k26-starterkit-v2022.1-09152304_update3.BIN
   sudo xmutil bootfw_status      # Image B: Non Bootable, Requested Boot Image: Image B
   ```
3. **Power-cycle** the board: unplug the 12 V jack, wait about 10 s, plug it back in. `sudo reboot` is not enough, the board keeps booting the old slot.
4. On the UART, the FSBL banner now shows `Release 2022.1` and U-Boot shows `2022.01`. Log in and mark the new image as good:
   ```sh
   sudo xmutil bootfw_status      # Last Booted Image: Image B
   sudo xmutil bootfw_update -v
   ```
   Without `-v`, the board falls back to the old image on a later boot.

## 2. Flash Ubuntu 22.04

On the PC, download the KV260 image from https://ubuntu.com/download/amd and write it to a microSD card of **at least 16 GB** (32 GB recommended). The uncompressed image does not fit on a 4 GB card.

```sh
lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL    # find the card; it is RM=1, TRAN=usb
xzcat iot-limerick-kria-classic-desktop-2204-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync && sudo eject /dev/sdX
```

`dd` reports a few GB/s at first because it writes into RAM, then appears to hang while `conv=fsync` flushes to the card at SD speed (about 16 MB/s, so around 10 minutes). Let it finish.

To keep the previous card contents, clone the card first:

```sh
sudo dd if=/dev/sdX bs=4M status=progress | xz -T0 -3 > kv260_backup.img.xz
```

## 3. First boot

1. Insert the card and connect Ethernet (with internet access), the micro-USB (UART/JTAG) and the webcam.
2. On the PC, open the console. It is PS UART1, the second or third port of the FTDI depending on the PC:
   ```sh
   picocom -b 115200 /dev/ttyUSB1 --logfile boot.log
   ```
3. Power on. Log in as `ubuntu` / `ubuntu`. Ubuntu forces a password change. To set a short password afterwards, which skips the quality checks:
   ```sh
   sudo usermod -p "$(openssl passwd -6 '<password>')" ubuntu
   ```
4. Update the system:
   ```sh
   sudo apt update && sudo apt upgrade -y
   ```
   If it asks about `/etc/default/flash-kernel.oem-limerick-kria-meta`, choose **install the package maintainer's version**. If apt reports a lock, `unattended-upgrades` is still running; wait and retry.
5. Reboot, then get the IP and continue over SSH:
   ```sh
   ip -4 a show eth0
   ```

## 4. Webcam check

```sh
lsusb                                          # Logitech, Inc. Webcam C170
sudo apt install -y v4l-utils
v4l2-ctl --list-devices                        # /dev/video0 is the camera, /dev/video1 its metadata node
v4l2-ctl -d /dev/video0 --list-formats-ext     # needs 'YUYV' 640x480 30 fps
```

Optional: stream to the PC to check the whole path. On the board:

```sh
sudo apt install -y ffmpeg
ffmpeg -f v4l2 -input_format yuyv422 -video_size 640x480 -framerate 30 -i /dev/video0 \
       -vsync 0 -c:v mjpeg -q:v 5 -f mjpeg "tcp://0.0.0.0:5000?listen=1"
```

On the PC:

```sh
ffplay -fflags nobuffer -flags low_delay -framedrop -probesize 32 -sync ext \
       -f mjpeg -framerate 30 tcp://<board-ip>:5000
```

### Capturing raw frames

Step 5 evaluates the face detector on your own frames. Capture them as raw YUYV, exactly what the DMA sees (close any notebook that uses the webcam first):

```sh
mkdir -p ~/webcam_frames && cd ~/webcam_frames
for i in $(seq -w 1 60); do
  v4l2-ctl -d /dev/video0 --set-fmt-video=width=640,height=480,pixelformat=YUYV \
           --stream-mmap --stream-skip=10 --stream-count=1 --stream-to=frame_$i.yuyv
  echo "frame $i"; sleep 1
done
```

Each file is 614 400 bytes. `--stream-skip=10` lets the auto-exposure settle. Copy them to the PC with `scp -r ubuntu@<board-ip>:webcam_frames <dest>`.

## 5. Install Kria-PYNQ

On the board, inside `tmux` so an SSH disconnect does not kill it:

```sh
sudo apt install -y tmux && tmux
git clone https://github.com/Xilinx/Kria-PYNQ.git
cd Kria-PYNQ
sudo bash install.sh -b KV260                  # 30+ minutes
git log -1 --format='%h %cd'                   # note the commit you installed
```

JupyterLab then runs as a root service at `http://<board-ip>:9090/lab`, password `xilinx`. The example notebook `opencv_face_detect_webcam` is a good check that PYNQ, OpenCV and the webcam all work.

## 6. Running a step's notebook

Every step's `pynq/` folder works the same way:

1. On the PC, build the step's bitstream and XSA (see the step README), then extract the overlay with the step's `export_overlay.sh`. It writes `<name>.bit` and `<name>.hwh`; PYNQ finds the `.hwh` by base name, so both must come from the same XSA.
2. In JupyterLab, create a folder and upload the `.bit`, the `.hwh` and the notebook (plus any extra files the step lists). Upload through the browser: Jupyter runs as root, so `scp` as `ubuntu` cannot write into its notebook folder.
3. Shut down the kernels of other notebooks that use the webcam.
4. After uploading a new `.bit`/`.hwh`, use **Kernel → Restart Kernel** before running.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| UART shows `Xilinx Zynq MP First Stage Boot Load…` repeating, cut off | Power supply too weak. Use the original 12 V kit supply. |
| After `bootfw_update` the board still boots the old firmware | A warm reboot does not switch slots. Power-cycle. |
| Ubuntu 22.04 does not boot | Boot firmware older than 2022.1, see section 1. |
| `dd: No space left on device` | Card too small for the image. |
| JupyterLab asks for a password | It is `xilinx`. |
| `jupyter-notebook list` shows nothing | Jupyter runs as root, so the `ubuntu` user does not see it. Check `sudo systemctl status jupyter` and `sudo ss -ltnp \| grep 9090`. |
| `PermissionError … /sys/kernel/config/device-tree/overlays/pynq/dtbo` | `insert_dtbo.py` ran as a non-root user, or the overlay was already inserted. Check `ls /sys/kernel/config/device-tree/overlays/`; if `pynq` is missing, run it as root and restart Jupyter (see below). |
| Webcam cell: `no frame from webcam` | Another notebook or `ffmpeg` holds `/dev/video0`. |
| A notebook hangs in `dma.sendchannel.wait()` / `recvchannel.wait()` | The loaded bitstream is not the design the notebook expects (e.g. an `.bit` extracted from an older XSA). Restart the kernel, check which XSA `export_overlay.sh` read, re-upload. |
| `ffplay` lags more and more | Missing `-framerate 30`: raw MJPEG has no timestamps and ffplay assumes 25 fps. |
| board `ffmpeg` shows `dup=` growing | The camera delivers under 30 fps in low light. `-vsync 0` stops ffmpeg from duplicating frames. |

Reinserting the PYNQ device-tree overlay as root:

```sh
sudo bash -c 'source /etc/profile.d/pynq_venv.sh && python3 /usr/local/share/pynq-venv/pynq-dts/insert_dtbo.py'
sudo systemctl restart jupyter
```
