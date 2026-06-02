# Setup llama.cpp server on AMD Strix Halo 128Gb version

## Initial setup

This note describes how to configure step by step local high-performance LLM setup with fresh install of Ubuntu Server 24.04 LTS and llama.cpp.

Before you proceed **you MUST configure BIOS** settings in graphics section to dedicate **MINIMUM** amount of RAM to GPU in UMA_SPECIFIED section.
Some systems allow to select 512Mb, some 2Gb.

Login to your shell then let's install repo for the newest kernel.
```bash
sudo add-apt-repository ppa:cappelikan/ppa -y
sudo apt update
sudo apt install mainline pkexec -y
```

If you tired from entering your password for sudo
```bash
sudo nano /etc/sudoers.d/$USER
```
```
your-user-login      ALL=(ALL) NOPASSWD: ALL
```

Find latest stable kernel
```
sudo mainline --list | grep "6.1[6-9]\|7.0"
```

You can try 7.0.4 even on Ubuntu 24.04 LTS
```
sudo mainline --install 7.0.4
```

Edit kernel startup params
```
sudo nano /etc/default/grub
```
Look for this line and modify accordingly. 
This params allow to allocate all available shared memory to GPU.

My benchmarks proved `amd_iommu=off` is better than `amd_iommu=pt`.
```
GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856 ttm.page_pool_size=32505856"
```

Update grub
```
sudo update-grub
```

Create udev rules
```
sudo bash -c 'cat > /etc/udev/rules.d/99-amd-kfd.rules << EOF
SUBSYSTEM=="kfd", GROUP="render", MODE="0666", OPTIONS+="last_rule"
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", GROUP="render", MODE="0666", OPTIONS+="last_rule"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", GROUP="render", MODE="0666", OPTIONS+="last_rule"
EOF'

sudo udevadm control --reload-rules
sudo udevadm trigger
```

Add your user to groups video and render
```
sudo usermod -aG video,render $USER
```

Install tuned
```bash
sudo apt install tuned -y
sudo systemctl enable --now tuned
sudo tuned-adm profile accelerator-performance
tuned-adm active
```

Tune kernel params with sysctl
```
sudo nano /etc/sysctl.d/99-llama.conf
```

Paste
```
# Don't swap unless absolutely forced — you want model weights in RAM always
vm.swappiness = 1

# Allow large contiguous allocations (important for 128GB unified memory pool)
vm.overcommit_memory = 1

# Reduce kernel's eagerness to reclaim memory from page cache under pressure
vm.vfs_cache_pressure = 50

# Raise dirty page thresholds — less frequent writeback interruptions
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10

vm.hugetlb_shm_group = 0

net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 4096
```

Paste to `/etc/security/limits.d/99-llm.conf`
```
* soft memlock unlimited
* hard memlock unlimited
```

You have 2 easy options for installation:
- As portable Lemonade ROCm backend (recommended)
- As distrobox/podman container 

Below I'm going to cover only Lemonade as the most easy and optimized way.

ROCm driver dependencies are included in distro.
Proceed to https://github.com/lemonade-sdk/llamacpp-rocm/releases and download the latest zip for Ubuntu (for example `llama-b1286-ubuntu-rocm-gfx1151-x64.zip`). I assume you're going to install it to `~/llama` folder.

```bash
mkdir ~/llama && cd ~/llama
wget llama-b1286-ubuntu-rocm-gfx1151-x64.zip
unzip llama-b1286-ubuntu-rocm-gfx1151-x64.zip
rm llama-b1286-ubuntu-rocm-gfx1151-x64.zip
chmod +x llama*
```

At this point I recommend to reboot first to apply all settings
```
sudo reboot
```

## Autoloading llama.cpp

Now let's create systemd user service to handle llama.cpp

```
nano ~/.config/systemd/user/llama.service
```

Paste this but pay attention to change `your-user-name`.
```systemd
[Unit]
Description=llama.cpp distrobox-server
After=network.target user@1000.service

[Service]
Type=simple
WorkingDirectory=/home/your-user-name
Restart=on-failure
RestartSec=10
TimeoutStopSec=10
StandardOutput=journal
StandardError=journal
Environment="XDG_RUNTIME_DIR=/run/user/1000"
Environment="LLM_PORT=9999"

ExecStart=/home/your-user-name/llama.sh
ExecStop=/usr/bin/pgrep llama-server | xargs -r kill -9

[Install]
WantedBy=multi-user.target
```

Create wrapper script
```
nano ~/llama.sh
```
[llama.sh](https://github.com/kryoz/llama-strix-halo/blob/main/llama.sh)

The script will configure llama.cpp to load models dynamically which were found at dir `~/models`.

Create custom config for models
```
nano ~/llama.ini
```
[llama.ini](https://github.com/kryoz/llama-strix-halo/blob/main/llama.ini)



Now register your service
```
sudo systemctl daemon-reload
systemctl --user enable llama.service
```

Then try to start service and read the journal
```
systemctl --user start llama.service
journalctl --user -u llama -f -n 100
```

I hope it helped you.

---

# Bonus part

## Ryzenadj

You can tweak power balance by famous utility `ryzenadj`.
It can safely decrease CPU power consumption freeing TDP room for GPU core.

Here's the guideline. 
```bash
# You may need a fresh toolchain for the kernel
sudo add-apt-repository ppa:ubuntu-toolchain-r/test
sudo apt update
sudo apt install gcc-15 g++-15 cmake build-essential libpci-dev

# Install forked module ryzen_smu for strix-halo
git clone https://github.com/amkillam/ryzen_smu
cd ryzen_smu && sudo make dkms-install

# Status check
sudo dkms status ryzen_smu

# If ok - load module
sudo modprobe ryzen_smu

# Install module permanently
echo "ryzen_smu" | sudo tee /etc/modules-load.d/ryzen_smu.conf

# Install ryzenadj utility
git clone https://github.com/FlyGoat/RyzenAdj.git
cd RyzenAdj
rm -r win32
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make
sudo cp ryzenadj /usr/local/bin
```

On GMKtec Evo X2 thermal limit was at 98 which is abnormally high. I changed to 87 which is enough especially if thermal interface was replaced to graphen pad.

Also GPU TDP limit was increased from 70W to 90W.

CPU cores was set to proven safe -20mV. 
Here's the map:
| mV | hex |
|----|-----| 
| 00x00000 | -10 |
| 0xFFFF6 | -20 |
| 0xFFFEC | -30 |
| 0xFFFE2 | -40 |
| 0xFFFF8 | -50 |
| 0xFFFF0 | instabilty risk |

One time set
```bash
sudo ryzenadj \
  --stapm-limit=120000 \
  --fast-limit=140000 \
  --slow-limit=120000 \
  --apu-slow-limit=90000 \
  --tctl-temp=90 \
  --set-coall=0xFFFEC
```

If you upgraded cooling or at least thermal interface you may try increase TDP up to 140W but MONITOR TEMPERATURES UNDER LOAD!
```bash
sudo ryzenadj \
  --stapm-limit=140000 \
  --fast-limit=150000 \
  --slow-limit=140000 \
  --apu-slow-limit=90000 \
  --tctl-temp=90 \
  --set-coall=0xFFFEC
```

Permanent set as service:
```bash
sudo nano /etc/systemd/system/ryzenadj.service
```

```ini
[Unit]
Description=RyzenAdj power settings
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ryzenadj --stapm-limit=120000 --fast-limit=140000 --slow-limit=120000 --apu-slow-limit=90000 --tctl-temp=90 --set-coall=0xFFFEC
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```
And enable it:
```bash
sudo systemctl enable --now ryzenadj.service
systemctl daemon-reload
# check
sudo systemctl status ryzenadj.service
```
# GMKTec Evo X2 BIOS 1.12 and minimal VRAM of 2Gb

If you've got this miniPC with v1.12 BIOS you probably was annoyed by minimum of UMA setting 2Gb RAM.

You can examine list of firmwares [here](https://strixhalo.wiki/Hardware/Boards/Sixunited_AXB35/Firmware)
---
**!!!DO NOT EVEN TRY TO FLASH v1.05 IF YOU HAD v1.12 FROM FACTORY!!!**

There are 2 versions of 1.05. One cannot be flashed. The another bricked my BIOS chip and even specialized flasher tool couldn't recover it!
---

Eventually appeared that **v1.11** is good enough.

Visit https://strixhalo.wiki/Hardware/Boards/Sixunited_AXB35/Firmware to download the archive. If you have Windows installed - you can handle with ease :)
If not here's a recipe.
1. You need USB stick and EFI shell like this https://sourceforge.net/projects/cloverefiboot/
2. Install Clover of the formatted USB stick
3. Copy contents of `ROM` and `Shell` directories of the firmware archive to the root of USB
4. Reboot and choose to boot from USB
5. Select EFI Shell in the Clover UI
6. At the shell select USB drive with command `FS1:` or `FS0:`
7. Lookup a command for flashing in the .nsh script like `cat AXB35-02_BIOS_UpdateEFI.nsh`
8. Type the command to run (mine was `AfuEfix64.efi AXB3502111.bin /p /b /n /r /k /l /x /capsule /q` )
9. Don't touch anything and pray :) Very scary part really.
10. No, it's not all over :) After all is done goto BIOS and reset all settings to default.
11. Reboot and goto BIOS again. Now you can select UMA 1Gb.
12. Congratulations!

---

# USB4/Thunderbolt/RDMA low latency driver

Refer to drivers [OdinLink-Five](https://github.com/Geramy/OdinLink-Five), follow a building guide.

Before probing boot your two nodes with USB4/TB4/5 cable connected.

The only issue was about default `odl_ring_size=4096` which is too high. Try with `odl_ring_size=1024`

```bash
sudo insmod driver/odl_tb5.ko odl_ring_size=1024
# Verify
lsmod | grep odl_tb5
# Also check logs upon init
sudo dmesg
```

Installation steps for permanent usage after the successful build and assuming you're in `OdinLink-Five` cloned directory:

```bash
echo "odl_tb5" | sudo tee /etc/modules-load.d/odl_tb5.conf
sudo cp driver/odl_tb5.ko /lib/modules/$(uname -r)/kernel/drivers/
sudo depmod -a
```
