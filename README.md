# Setup llama.cpp server on AMD Strix Halo 128Gb version

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

For example 6.18.6
```
sudo mainline --install 6.18.6
```

Edit kernel startup params
```
sudo nano /etc/default/grub
```
Look for this line and modify accordingly. 
This params allow to allocate all available shared memory to GPU.

My benchmarks proved `amd_iommu=off` is better than `amd_iommu=pt`.
```
GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=off amdgpu.gttsize=131072 ttm.pages_limit=33554432"
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
At the moment `rocm7-nightlies` is the fastest in most cases but may have issues.
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

Paste this but pay attension to change `your-user-name` and customize `LLM_PORT=9999`
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

`-cb` - I removed continous batching as it confronts with speculative decoding feature.


Paste and modify again `your-user-name`.
```
nano ~/llama-starter.sh
```
```bash
#!/bin/bash

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export MY_DIR=/home/your-user-name
export GGML_HIP_FORCE_MMQ=1
export GGML_HIP_MAX_BATCH_SIZE=4096
export GGML_HIP_NO_PINNED=1

exec /usr/local/bin/distrobox enter rocm7-nightlies -- \
  numactl --cpunodebind=0 --membind=0 llama-server \
  --models-preset ${MY_DIR}/llama.ini \
  --models-max 1 \
  --models-dir ${MY_DIR}/models \
  -ngl 999 --parallel 1 \
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
threads = 8
threads-batch = 8
flash-attn = on
mlock = off
mmap = off
split-mode = none
fit = off
warmup = off
ubatch-size = 1536
batch-size  = 6144
cache-type-k = q8_0
cache-type-v = q8_0
jinja = true
direct-io = on
ctx-checkpoints = 20
cache-prompt = true
cache-reuse = 4096
# Careful! +8Gb of RAM utilization
cache-ram = 8192
slot-prompt-similarity = 0.85

[minimax]
# AesSedai/MiniMax-M2.5
# This model works badly with draft and works on the edge of 128Gb RAM
# These params help to avoid OOM
model = /home/your-user-name/models/MiniMax-M2.5/MiniMax-M2.5-IQ4_XS-00001-of-00004.gguf
chat-template =
ctx-checkpoints = 8
ubatch-size = 768
batch-size  = 3072
cache-type-k = q4_0
cache-type-v = q4_0
ctx-size = 50000
slot-prompt-similarity = 0.9
n-predict = 16384
temp = 0.5
top-p = 0.95
top-k = 40
min-p = 0.01
repeat-penalty = 1.1

[qwen3.5]
model = /home/your-user-name/models/Qwen3.5/Qwen3.5-122B-A10B-UD-Q5_K_XL-00001-of-00003.gguf
ctx-size = 32768
cache-reuse = 8192
ctx-checkpoints = 32
swa-full = on
n-predict = 16384
temp = 1.0
top-p = 0.95
top-k = 40
min-p = 0.01
repeat-penalty = 1.1
cache-type-k = q4_0
cache-type-v = q4_0
spec-type = ngram-map-k
#spec-use-checkpoints = on
spec-ngram-size-n = 6
spec-ngram-size-m = 4
# maybe you should tune this params to achieve acceptance to range of 0.6~0.0.9
draft-p-min = 0.8
draft-min = 6
draft-max = 16

[qwen3-coder]
model = /home/your-user-name/models/Qwen3Coder-Q8/Qwen3-Coder-Next-UD-Q8_K_XL-00001-of-00003.gguf
ctx-size = 196608
cache-reuse = 9182
swa-full = on
n-predict = 16384
temp = 1.0
top-p = 0.95
top-k = 40
min-p = 0.01
repeat-penalty = 1.1
presence-penalty = 1.5
cache-type-k = q8_0
cache-type-v = q8_0
spec-type = ngram-map-k
#spec-use-checkpoints = on
spec-ngram-size-n = 8
spec-ngram-size-m = 6
# maybe you should tune this params to achieve acceptance to range of 0.6~0.0.9
draft-max = 48
draft-p-min = 0.8

[GPT]
model = /home/your-user-name/models/GPT/gpt-oss-120b-Q8_0-00001-of-00002.gguf
ctx-size = 130000
temp = 1.0
min-p = 0.01
cache-type-k = q8_0
cache-type-v = q8_0

[Qwen3-VL]
model = /home/your-user-name/models/Qwen3-VL/Qwen3-VL-30B-A3B-Instruct-UD-Q8_K_XL.gguf
mmproj = /home/akubintsev/models/mmproj-F16.gguf
chat-template = chatml
ctx-size = 32768
min-p = 0.05
top-k = 40
top-p = 0.95
temp = 0.2
repeat-penalty = 1.05
cache-type-k = q8_0
cache-type-v = q8_0
presence-penalty = 0
image-min-tokens = 1024
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

# Install permanently
echo "ryzen_smu" | sudo tee /etc/modules-load.d/ryzen_smu.conf
```

On GMKtec Evo X2 thermal limit was at 98 which is abnormally high. I changed to 85 which is enough especially if thermal interface was replaced to graphen pad.

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
  --tctl-temp=85 \
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
ExecStart=/usr/local/bin/ryzenadj --stapm-limit=120000 --fast-limit=140000 --slow-limit=120000 --apu-slow-limit=90000 --tctl-temp=85 --set-coall=0xFFFEC
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

If you've got this miniPC you probably was annoyed by minimal UMA setting of 2Gb RAM. Mine was shipped with this version of BIOS.

In prev versions of the firmware there was even 512M so it's about 1.5Gb of RAM which has become unusable.

At first I tried to flash 1.05 but without any success. As I understood the manufacturer has changed the flash method and I DO NOT RECOMMEND EVEN TO ATTEMPT to flash it.

Eventually appeared thayt v1.11 is enough.

Visit https://strixhalo.wiki/Hardware/Boards/Sixunited_AXB35/Firmware to download the archive. If you have Windows installed - you can handle with ease :)
If not here's a recipe.
1. You need USB stick and EFI shell like this https://sourceforge.net/projects/cloverefiboot/
2. Install Clover of the formatted USB stick
3. Copy contents of `ROM` and `Shell` directories of the firmware archive to the root of USB
4. Reboot and choose to boot from USB
5. Select EFI Shell in the Clover UI
6. At the shell select USB drive with command `FS1:` or `FS0:`
7. Lookup a command for flashing in the .nsh script like `cat AfiFlash.nsh`
8. Type the command  (mine was `AfuEfix64.efi AXB3502111.bin /p /b /n /r /k /l /x /capsule /q` )
9. Don't touch anything and pray :) Very scary part really.
10. No, it's not all over :) After all is done goto BIOS and reset all settings to default.
11. Reboot and goto BIOS again. Now you can select UMA 1Gb.
12. We can do better :) After applying and reboot return to BIOS.
13. Hit Alt+F5. You'll be notified about enabling debug settings. If 2nd Advanced tab didn't appear save and reboot again
14. In the 2nd Advanced tab look for GFX settings. I don't recommend to change anything else by the way.
15. Select 0.5Gb at last and save the settings.
16. Congratulations!



## Llama.cpp buid tips
Actually performance was much worse than at `rocm7-nightlies` builds. 
But it may have sense to add optimization flags inside toolbox'es Dockerfile.

```bash
# Add AMD ROCm repository
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | sudo apt-key add -
echo 'deb [arch=amd64] https://repo.radeon.com/rocm/apt/latest ubuntu main' | sudo tee /etc/apt/sources.list.d/rocm.list

sudo apt update
sudo apt install rocm-hip-runtime rocm-hip-sdk -y

export ROCM_PATH=/opt/rocm
# gfx1151
export HSA_OVERRIDE_GFX_VERSION="11.5.1"
export PATH=$PATH:$ROCM_PATH/bin 
export LD_LIBRARY_PATH="$ROCM_PATH/lib $ROCM_PATH/lib64 $LD_LIBRARY_PATH"
export HIPCC_FLAGS="--amdgpu-target=gfx1151 --hip-link-llvm-bitcode"

# Clone llama.cpp sources
git clone https://github.com/ggerganov/llama.cpp --depth 1

# build
cd llama.cpp
cmake -B build . -DCMAKE_CXX_FLAGS="-march=native -Ofast -DNDEBUG" -DCMAKE_C_FLAGS="-march=native -Ofast -DNDEBUG" -DGGML_HIP=ON -DAMDGPU_TARGETS="gfx1151" -DGGML_AVX512=ON -DGGML_AVX2=ON -DGGML_AVX=ON -DGGML_AVX512_VBMI=ON -DGGML_AVX512_VNNI=ON -DGGML_AVX512_BF16=ON -DGGML_NATIVE=OFF -DGGML_FMA=ON -DGGML_F16C=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
