# Setup llama.cpp server on AMD Strix Halo 128Gb version

## Initial setup

This note describes how to configure step by step local high-performance LLM setup with fresh install of Ubuntu Server 24.04 LTS and llama.cpp.

Before you proceed **you MUST configure BIOS** settings in graphics section to dedicate **MINIMUM** amount of RAM to GPU in UMA_SPECIFIED section.
Some systems allow to select 512Mb, some 2Gb.

Also for more predictable CPU threads aligning by `numactl` - **disable SMT (hyper-threading)**.

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
sudo mainline --list | grep "6.1[6-9]\|6.2"
```

6.19.* at the moment had issues. I recommend 6.18.*, for example 6.18.10
```
sudo mainline --install 6.18.20
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

Install podman and distrobox
```bash
sudo apt install podman -y
curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sudo sh
sudo loginctl enable-linger $USER
```

Install one of toolboxes from [kyuz0](https://hub.docker.com/r/kyuz0/amd-strix-halo-toolboxes/tags).
At the moment `rocm7-nightlies` is the fastest in most cases but may have issues (at the end of April 2026 - only half mem visible).
Take a look for [benchmark comparison](https://kyuz0.github.io/amd-strix-halo-toolboxes/)
```
distrobox create rocm7-nightlies --image docker.io/kyuz0/amd-strix-halo-toolboxes:rocm7-nightlies --additional-flags "--device /dev/dri --device /dev/kfd --group-add video --group-add render  --security-opt seccomp=unconfined"
```

At this point I recommend to reboot first to apply all settings
```
sudo reboot
```

Now let's create systemd service to handle llama.cpp

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

ExecStart=/home/your-user-name/llama-starter.sh
ExecStop=/usr/local/bin/distrobox enter rocm7-nightlies -- /bin/bash -c "pkill -9 llama-server"

[Install]
WantedBy=multi-user.target
```

Create wrapper script
```
nano ~/llama-starter.sh
```


Next script will configure llama.cpp to load models dynamically which were found at dir `~/models`.

I tuned params to handle at agents workflow as fast as it can be.

`numactl --cpunodebind=0 --membind=0 ` - binds to CPU CCD 0 (to use all threads on that CCD and its L2 Cache). 

Note! You must install it manually **in the container**:
```
distrobox enter rocm7-nightly
sudo dnf install numactl
exit
```

Using all CPUs CCDs makes less efficient job processing due to concurrent memory access between them and GPU.

`--models-max 1` specifies to handle up 1 models in RAM. The only stable option for auto loading/unloading model on demand.

`--parallel 1` - max 1 requests processed at once. Available ctx-size divides by this param.

Don't use without specific needs `-cb` -  continous batching, it confronts with speculative decoding feature.


Paste and modify again `your-user-name`.
```
nano ~/llama-starter.sh
```
```bash
#!/bin/bash

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export MY_DIR=/home/your-user-name

export GGML_HIP_NO_VMM=1
export GGML_HIP_FORCE_MMQ=1
export GGML_HIP_MAX_BATCH_SIZE=2048
export GGML_HIP_NO_PINNED=1
export ROCBLAS_USE_HIPBLASLT=1
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export HSA_ENABLE_SDMA=0
# allow 30 min for slow long prompt processing step
export LLAMA_ARG_TIMEOUT=1800

exec /usr/local/bin/distrobox enter rocm7-nightlies -- \
  numactl --cpunodebind=0 --membind=0 llama-server --numa numactl \
  --models-preset ${MY_DIR}/llama.ini \
  --models-max 1 \
  -ngl 999 --parallel 1 -np 2 --no-webui --no-mmap -fa 1 -nocb \
  --host 0.0.0.0 --port ${LLM_PORT}
```

Create custom config for models
```
nano ~/llama.ini
```

Here's example of my configuration. Take a note on highly optimized params for Qwen3 Coder Next (speculative decoding without providing draft model) 
```ini
version = 1

[*]
threads = 2
threads-batch = 8
flash-attn = on
mlock = off
mmap = off
split-mode = none
fit = off
warmup = off
# Generally ubatch-size of 2048 is optimal for gfx1151 for ROCm. Try 1024 for Vulkan.
ubatch-size = 2048
batch-size  = 8192
# Quants higher Q8 have tiny benefits; lower degrade quality significantly
cache-type-k = q8_0
cache-type-v = q8_0
jinja = true
direct-io = on
ctx-checkpoints = 20
cache-prompt = true
cache-reuse = 256
cache-ram = 2048
slot-prompt-similarity = 0.85
top-k = 40
top-p = 0.95
min-p = 0.01
swa-full = on
# thinking
reasoning = off
chat-template-kwargs = {"enable_thinking":false}
# spec decoding
spec-type = ngram-map-k
spec-ngram-map-k-size-n = 8
spec-ngram-map-k-size-m = 4
spec-draft-n-min = 1
spec-draft-n-max = 4
draft-p-min = 0.9

[qwen3.5-27B]
model = /home/your-user-name/models/Qwen3.5-27B-GGUF/Qwen3.5-27B-UD-Q8_K_XL.gguf
temp = 0.6
top-k = 30

[qwen3.6-35B]
model = /home/your-user-name/models/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf
temp = 0.9

[qwen3.5-122B]
model = /home/your-user-name/models/Qwen3.5-122B-A10B/Qwen3.5-122B-A10B-APEX-I-Quality.gguf
ctx-size = 200000
temp = 0.9
```

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

Also my credits to https://github.com/Gygeek/Framework-strix-halo-llm-setup 

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
  --tctl-temp=88 \
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
ExecStart=/usr/local/bin/ryzenadj --stapm-limit=120000 --fast-limit=140000 --slow-limit=120000 --apu-slow-limit=90000 --tctl-temp=87 --set-coall=0xFFFEC
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

In prev versions of the firmware there was even 512M so it's about 1.5Gb of RAM which has become unusable.

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
12. We can do better :) After applying and reboot return to BIOS.
13. Hit Alt+F5. You'll be notified about enabling debug settings. If 2nd Advanced tab didn't appear save and reboot again
14. In the 2nd Advanced tab look for GFX settings. I don't recommend to change anything else by the way.
15. Select 0.5Gb at last and save the settings.
16. Congratulations!

UPDATE: Setting to 512Mb worked only once for me :(

---

# USB4/Thunderbolt/RDMA breakthrough for lowest latency

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
