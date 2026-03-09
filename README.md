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
Look for this line and modify accordingly. 
This params allow to allocate all available shared memory to GPU.

My benchmarks proved `amd_iommu=off` is better than `amd_iommu=pt`.
```
GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=off amdgpu.gttsize=131072 ttm.pages_limit=33554432"
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

Paste and modify again `your-user-name`.

This command will configure llama.cpp to load models dynamically which were found at dir `~/models`.

I tuned params to handle at agents workflow as fast as it can be.

`numactl --cpunodebind=0 --membind=0 ` - binds to CPU CCD 0 and `-tb 8` specifies use all threads on that CCD. 
"Threads batch" is for prompt processing. It utilizes CPU. Note! You must install it manually *in the container*:
```
distrobox enter rocm7-nightly
sudo dnf install numactl
exit
```

Using all CPUs CCDs makes less efficient job processing due to concurrent memory access between them and GPU.

`--models-max 1` specifies to handle up 1 models in RAM. The only stable option for auto loading/unloading model on demand.

`--parallel 1` - max 1 requests processed at once. Available ctx-size divides by this param.

`-cb` - I removed continous batching as it confronts with speculative decoding feature.

```bash
#!/bin/bash

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export MY_DIR=/home/your-user-name

exec /usr/local/bin/distrobox enter rocm7-nightlies -- \
  numactl --cpunodebind=0 --membind=0 llama-server \
  --models-preset ${MY_DIR}/llama.ini \
  --models-max 1 \
  --models-dir ${MY_DIR}/models \
  -fa on --no-mmap -ngl 99 --parallel 1 \
  -t 4 -tb 8 --jinja --cache-reuse 12288 \
  --host 0.0.0.0 --port ${LLM_PORT}
```

Create custom config for models
```
nano ~/llama.ini
```

My example of configuration. Take a note on highly optimized params for Qwen3 Coder Next (speculative decoding without providing draft model) 
```ini
[qwen3-235b]
model = /home/your-user-name/models/Qwen3-235b/Qwen3-235B-A22B-UD-Q3_K_XL-00001-of-00003.gguf
batch-size = 2048
ubatch-size = 512
ctx-size = 120000
ctx-checkpoints = 16
slot-prompt-similarity = 0.85
n-predict = 32768
temp = 0.3
top-p = 0.95
top-k = 40
min-p = 0.01
repeat-penalty = 1.1
cache-type-k = q4_0
cache-type-v = q4_0
cache-type-k-draft = q4_0
cache-type-v-draft = q4_0
spec-type = ngram-map-k
draft-max = 12
spec-ngram-size-n = 5
spec-ngram-size-m = 3
lookup-cache-static = 4096
lookup-cache-dynamic = 4096

[qwen3-coder]
batch-size = 4096
ubatch-size = 768
ctx-size = 196608
cache-reuse = 12288
ctx-checkpoints = 24
swa-full = on
slot-prompt-similarity = 0.85
n-predict = 32768
temp = 0.2
top-p = 0.95
top-k = 40
min-p = 0.01
repeat-penalty = 1.1
cache-type-k = q8_0
cache-type-v = q8_0
cache-type-k-draft = q4_0
cache-type-v-draft = q4_0
draft-max = 64
spec-type = ngram-map-k
#spec-use-checkpoints = on
spec-ngram-size-n = 12
spec-ngram-size-m = 8
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

P.S. Llama.cpp buid tips. Actually performance was much worse than on `rocm7-nightlies` builds
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
