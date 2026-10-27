# FINN setup: neural networks as PL IP blocks

[FINN](https://github.com/Xilinx/finn) turns a quantized PyTorch network (trained with [Brevitas](https://github.com/Xilinx/brevitas)) into a dataflow accelerator: one hardware block per layer, chained with AXI-Stream, packaged as a Vivado IP. Step 5 (`kria_face_detect`) uses it twice: for FINN's MNIST example as an integration test (`finn/tfc_example`) and for the trained face detector (`ml/finn_v1`).

FINN runs **only on the PC**, inside Docker. Its output is an IP that goes into our own Vivado design; nothing FINN-specific runs on the board.

## What you need

- Vivado + Vitis HLS **2022.2** installed (e.g. under `/tools/Xilinx`).
- FINN **v0.10**: the release that targets Vivado/Vitis 2022.2. Newer FINN releases expect newer tools.
- Docker, run **as your user** (never with `sudo`, see below).
- About 30 GB of free disk for the image and builds; 16 GB+ RAM.
- Optional: an NVIDIA GPU for training (step 5 uses a T1000 8 GB, about 10× faster than 24 CPU threads).

## Install

```sh
sudo apt install docker.io
sudo usermod -aG docker $USER
```

Log out and back in (or reboot): group changes only apply to new sessions. Check with `id -nG` (must list `docker`) and `docker run --rm hello-world` (without `sudo`).

```sh
git clone -b v0.10 https://github.com/Xilinx/finn.git ~/finn
```

Add to `~/.zshrc` (or `~/.bashrc`):

```sh
export FINN_XILINX_PATH=/tools/Xilinx
export FINN_XILINX_VERSION=2022.2
export FINN_DOCKER_EXTRA="-e PYTEST_ADDOPTS=-pno:anyio"
export NUM_DEFAULT_WORKERS=1
```

| Variable | Why |
|---|---|
| `FINN_XILINX_PATH`, `FINN_XILINX_VERSION` | `run-docker.sh` mounts Vivado/Vitis HLS into the container. Without them HLS steps fail with `KeyError: 'HLS_PATH'` (and a misleading "Custom op_type … is currently not supported"). |
| `FINN_DOCKER_EXTRA="-e PYTEST_ADDOPTS=-pno:anyio"` | Building the v0.10 image today pulls `anyio` 4.x, whose pytest plugin needs a newer pytest than the pinned 6.2.5 (`No module named '_pytest.scope'`). Disabling that plugin avoids rebuilding the image. Only tests are affected. |
| `NUM_DEFAULT_WORKERS=1` | With the default 4 parallel HLS jobs, some layers randomly fail their IP export with `Unable to load Tcl app xilinx::questa` (several `vitis_hls` processes race on `~/.Xilinx/Vivado/2022.2/XilinxTclStore`). One at a time is a few minutes slower and reliable. |

Check the installation (the first run builds the image, 20-60 min):

```sh
cd ~/finn && ./run-docker.sh quicktest
```

Expected: `963 passed, 16 skipped, 4 xfailed, 3 xpassed`.

### GPU (optional, for training)

```sh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all ubuntu nvidia-smi        # must show the GPU
```

`run-docker.sh` then adds `--gpus all` by itself ("nvidia-docker detected, enabling GPUs"). The container's PyTorch is 1.13.1 + CUDA 11.6.

## Three ways to run things in the container

| Mode | Command (from `~/finn`) | Use |
|---|---|---|
| build script | `./run-docker.sh build_custom <dir> [<script>]` | runs `<dir>/<script>.py` (default `build.py`) with `<dir>` mounted and as working directory. The FINN builds of step 5. No arguments can be passed. |
| interactive shell | `FINN_DOCKER_EXTRA="$FINN_DOCKER_EXTRA -v $DIR:$DIR -w $DIR" ./run-docker.sh` | a bash shell in `$DIR`, e.g. for `python train/train.py --epochs 40`. Run it inside `tmux` for long jobs. |
| one command | same `FINN_DOCKER_EXTRA` + `./run-docker.sh python <script> <args>` | short jobs with arguments. |

`run-docker.sh` always asks Docker for a terminal (`-it`). From a script or in the background, wrap it: `script -qec "./run-docker.sh …" /dev/null`, otherwise Docker stops with `the input device is not a TTY`.

## Build settings that matter (all used in step 5)

| Setting | Why |
|---|---|
| `fpga_part="xck26-sfvc784-2LV-c"` | the KV260 SOM chip. With `board=` FINN would build a whole board shell instead of an IP. |
| `synth_clk_period_ns=10.0` | `pl_clk0` = 100 MHz in our block designs. |
| `generate_outputs=[ESTIMATE_REPORTS, STITCHED_IP, RTLSIM_PERFORMANCE, OOC_SYNTH]` | the IP for our Vivado project, plus resource/timing/cycle reports. No bitstream, no PYNQ driver. |
| `stitched_ip_gen_dcp=True` | packages a synthesized netlist (`dcp/finn_design.dcp`) into the IP. Without it the IP's ~40 sub-IPs point to `/tmp/finn_dev_<user>/code_gen_ipgen_*` (wiped at reboot) and Vivado reports "IP contains one or more locked subcores". The DCP-based IP can be implemented but not simulated in xsim; FINN's own RTL simulation covers that. |
| `auto_fifo_depths=False` (conv networks) | FINN's automatic FIFO sizing runs a simulation with huge FIFOs and measures how far fast layers run ahead (262 144 entries for our network, above the 32 768 limit of the Xilinx FIFO IP → `CreateStitchedIP failed`). A plain chain (no branches/skips) cannot deadlock with FINN's small default FIFOs; throughput is set by the folding. |
| folding (`PE`/`SIMD` per layer, or `target_fps`) | sets parallelism → cycles per frame, latency and LUTs. The first layer's folding also sets the **input stream width**: TFC with `Thresholding PE=4` → 32-bit input matching the DMA; FaceNet's first conv → 8-bit, 1 pixel per beat. |
| `verify_steps=[…, STITCHED_IP_RTLSIM]` + `verify_input_npy`, `verify_expected_output_npy` | compares the generated RTL with the PyTorch/Brevitas output (`atol=1e-3`): `output_*/verification_output/*_SUCCESS.npy`. |

## The generated IP

```
ap_clk, ap_rst_n                 clock + active-low reset (connect peripheral_aresetn)
s_axis_0_tdata, tvalid, tready   input stream, width from the first layer's folding
m_axis_0_tdata, tvalid, tready   output stream
```

- **No `tlast`** on either side. The DMA's S2MM needs one: our top levels generate it (`fpga_top_test`: every beat is the last, one result per transfer; `fpga_top_nn`: counter on the 600th beat).
- Its VLNV is `xilinx_finn:finn:finn_design:1.0` for every FINN build. Two FINN IPs therefore cannot be in the same Vivado project; step 5 creates a separate project per IP (`create_project.tcl nn` / `tfc_test`). FINN's `CreateStitchedIP` has an `ip_name` parameter, but the builder step does not expose it.
- Graph parts FINN cannot map to hardware stay in software, in `intermediate_models/dataflow_parent.onnx` around the `StreamingDataflowPartition` node. For FaceNet: an input `Transpose` (NCHW→NHWC, a no-op for 1 channel), and after the IP a `Transpose` + `Mul` by the output scale. So the IP streams **NHWC integers**, and the notebook multiplies by `out_scale`.

## Where to look

| What | Where |
|---|---|
| reports | `output_*/report/`: `ooc_synth_and_timing.json` (measured LUT/BRAM/DSP/WNS), `estimate_layer_resources.json`, `estimate_layer_cycles.json`, `rtlsim_performance.json` |
| verification | `output_*/verification_output/*_SUCCESS.npy` |
| the graph after each step | `output_*/intermediate_models/step_*.onnx` (open with https://netron.app) |
| per-layer HLS code and weights | `/tmp/finn_dev_<user>/code_gen_ipgen_<layer>_*/` (wiped at reboot; set `FINN_HOST_BUILD_DIR` to keep it) |
| layer libraries | `~/finn/deps/finn-hlslib/` (`mvau.hpp`, `slidingwindow.h`, …), `~/finn/finn-rtllib/` (`swg`, `fifo`, `dwc`, `thresholding`, …) |
| stitching project | `output_*/stitched_ip/finn_vivado_stitch_proj.xpr` |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `setuptools-scm was unable to detect version for …/deps/qonnx` | The container ran as root (`run-docker.sh` started with `sudo`), so git rejects the user-owned repos. `sudo chown -R $USER:$USER ~/finn`, then run without sudo. |
| `permission denied … /var/run/docker.sock` | The session does not have the `docker` group yet: log out/in or reboot. |
| `No module named '_pytest.scope'` | `PYTEST_ADDOPTS=-pno:anyio`, see above. |
| `KeyError: 'HLS_PATH'` | `FINN_XILINX_PATH` / `FINN_XILINX_VERSION` not set in this shell. |
| `IP definition not found for VLNV: xilinx.com:hls:MVAU_hls_N` / `Unable to load Tcl app xilinx::questa` | parallel HLS race: `NUM_DEFAULT_WORKERS=1`. |
| `Value '262144' is out of the range for parameter 'FIFO depth'` | `auto_fifo_depths=False`, see above. |
| Vivado: "locked subcores" on the FINN IP | build with `stitched_ip_gen_dcp=True`. |
| The build "hangs" at 0% CPU, log ends with `(Pdb)` | a step failed and `build_custom` stopped in the Python debugger. Type `q`; the real error is a few lines above the traceback. |
