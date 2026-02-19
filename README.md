# Setup llama.cpp server on AMD Strix Halo 128Gb version

This note describes how to configure step by step local high-performance LLM setup with fresh install of Ubuntu Server 24.04 LTS and llama.cpp.

Before you proceed you MUST configure BIOS settings in graphics section to dedicate MINIMUM amount of RAM to GPU in UMA_SPECIFIED section.
Some systems allow to select 512Mb, some 2Gb.

Login to your shell then let's install repo for the newest kernels
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
Look for this line and modify accordingly. My benchmarks proved `amd_iommu=off` is better than `amd_iommu=pt`
```
GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=off amdgpu.gttsize=129024 ttm.pages_limit=33030144"
```

Configure module with same numbers
```
sudo nano /etc/modprobe.d/amdgpu_llm_optimized.conf
```
```
options amdgpu gttsize=129024
options ttm pages_limit=33030144
options ttm page_pool_size=33030144
```

Update initramfs and grub
```
sudo update-grub
sudo update-initramfs -u -k all
```

Update udev rules
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
ExecStop=/usr/local/bin/distrobox enter rocm7-nightlies -- /bin/bash -c "/usr/sbin/lsof -ti:${LLM_PORT} | xargs -r kill -TERM"

[Install]
WantedBy=multi-user.target
```

Create wrapper script
```
nano ~/llama-starter.sh
```

Paste and modify again `your-user-name`.
This command will configure llama.cpp to load models dynamically which were found at dir `~/models`.

`--models-max 2` specifies to handle up 2 models in RAM.

```bash
#!/bin/bash

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export MY_DIR=/home/your-user-name

exec /usr/local/bin/distrobox enter rocm7-nightlies -- \
  ${MY_DIR}/llama.cpp/build/bin/llama-server \
  --models-preset ${MY_DIR}/llama.ini \
  --models-max 2 \
  --models-dir ${MY_DIR}/models \
  -fa on --no-mmap -ngl 999 --parallel 1  \
  -t 14 -tb 16 -cb --jinja --cache-type-k q8_0 --cache-type-v q8_0 --cache-reuse 12288 --batch-size 2048 --ubatch-size 512 \
  --host 0.0.0.0 --port ${LLM_PORT}
```

Create custom config for models
```
nano ~/llama.ini
```

My example
```ini
[qwen-autocomplete]
model = /home/your-user-name/models/qwen2.5-coder-14b/qwen2.5-coder-14b-instruct-q6_k-00001-of-00002.gguf
ctx-size = 4096
temp = 0.15
top-p = 0.95
top-k = 40
min-p = 0.01
repeat-penalty = 1.0
cache-type-k = q6_0
cache-type-v = q6_0

[qwen3-coder]
model = /home/your-user-name/models/QwenNext/Qwen3-Coder-Next-UD-Q8_K_XL-00001-of-00003.gguf
ctx-size = 150000
temp = 1.0
top-p = 0.95
top-k = 40
min-p = 0.01
repeat-penalty = 1.0
seed = 3407
cache-type-k = q8_0
cache-type-v = q8_0

[GPT]
model = /home/your-user-name/models/GPT/gpt-oss-120b-Q8_0-00001-of-00002.gguf
ctx-size = 100000
temp = 1.0
min-p = 0.01
cache-type-k = q8_0
cache-type-v = q8_0

[GLM]
model = /home/your-user-name/models/GLM-4.7-Flash-UD-Q8_K_XL.gguf
ctx-size = 202752
min-p = 0.01
top-p = 0.95
temp = 0.8
repeat-penalty = 1.0
cache-type-k = q8_0
cache-type-v = q8_0
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
