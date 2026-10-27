# FINN build of the trained FaceNet v1 (ml/runs/v1/best.pt) -> stitched IP for fpga_top_nn.
#
# 1. load the trained weights, export to QONNX, annotate the input as UINT8 (raw gray pixels)
# 2. verification data: 2 seeded random 160x120 UINT8 images (one pixel noise, one 8x8 blocks)
#    and the Brevitas output for them. Bit-exactness does not need faces, and no personal or
#    dataset images are needed. The board notebook replays the same images through the PL.
# 3. hw_meta.json: what the notebook needs to decode the hardware output
# 4. FINN build -> stitched IP (self-contained DCP), checked bit-exact in RTL simulation
#
# Hardware interface of the IP (VLNV xilinx_finn:finn:finn_design:1.0, FINN's default name):
#   s_axis_0: 8 bit, 19200 beats per frame (160x120 UINT8 pixels, raster order)
#   m_axis_0: 8 bit,   600 beats per frame (20x15 cells x [score, size code], INT8, NHWC order:
#             cell (0,0) score, cell (0,0) size, cell (0,1) score, ...); value = int8 * out_scale
#
# Run from ~/finn, with ml/ as the build folder so that train/model.py and runs/ are visible
# (REPO = path of this repository; about 1 hour):
#   ./run-docker.sh build_custom $REPO/kria_face_detect/ml finn_v1/build
# Export only (no FINN build), to check the export and regenerate the verification files:
#   FINN_DOCKER_EXTRA="$FINN_DOCKER_EXTRA -v $REPO/kria_face_detect/ml:$REPO/kria_face_detect/ml -w $REPO/kria_face_detect/ml" \
#     ./run-docker.sh python finn_v1/build.py --export-only
# Needs NUM_DEFAULT_WORKERS=1 and the other FINN settings of docs/setup_finn.md.

import json
import os
import sys

import numpy as np
import torch
from brevitas.export import export_qonnx
from qonnx.core.datatype import DataType
from qonnx.core.modelwrapper import ModelWrapper
from qonnx.util.cleanup import cleanup

HERE = os.path.dirname(os.path.abspath(__file__))
ML_DIR = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ML_DIR, "train"))
from model import IN_H, IN_W, FaceNet  # noqa: E402

RUN = "v1"
CKPT = os.path.join(ML_DIR, "runs", RUN, "best.pt")
TARGET_FPS = 150            # sizing build: 60 fps -> 35.6 ms latency; 150 -> 15.4 ms
VERIFY_SEED = 2026


def verification_images():
    """2 seeded random 160x120 UINT8 images: pixel noise, and 8x8-pixel blocks (more structure)."""
    rng = np.random.default_rng(VERIFY_SEED)
    noise = rng.integers(0, 256, (IN_H, IN_W), dtype=np.uint8)
    blocks = np.kron(rng.integers(0, 256, (IN_H // 8, IN_W // 8), dtype=np.uint8), np.ones((8, 8), np.uint8))
    return np.stack([noise, blocks])[:, None].astype(np.float32)                    # (2,1,120,160)


def export():
    model = FaceNet()
    model.load_state_dict(torch.load(CKPT, map_location="cpu"))
    model.eval()

    x = verification_images()
    with torch.no_grad():
        y = model(torch.from_numpy(x)).numpy()                                      # (2,2,15,20)
    np.save(os.path.join(HERE, "input.npy"), x)
    np.save(os.path.join(HERE, "expected_output.npy"), y)

    scale = float(model.net[-1].quant_act_scale())
    q = y / scale
    assert np.allclose(q, np.round(q), atol=1e-3), "output is not an integer multiple of the output scale"
    meta = {
        "run": RUN, "checkpoint": "runs/%s/best.pt" % RUN, "out_scale": scale,
        "out_dtype": "INT8", "out_layout": "NHWC (15, 20, 2): [score logit, size code]",
        "size_log_min": 3.5, "size_log_span": 4.0, "cell_px": 8, "in_w": IN_W, "in_h": IN_H,
    }
    json.dump(meta, open(os.path.join(HERE, "hw_meta.json"), "w"), indent=1)
    print(f"[finn_v1] out_scale = {scale:.6f}, verification: 2 random images (seed {VERIFY_SEED}), "
          f"output int range {int(np.round(q).min())}..{int(np.round(q).max())}")

    raw = os.path.join(HERE, "facenet_v1_raw.onnx")
    onnx_path = os.path.join(HERE, "facenet_v1.onnx")
    export_qonnx(model, torch.from_numpy(x[:1]), raw)
    cleanup(raw, out_file=onnx_path)
    mw = ModelWrapper(onnx_path)
    mw.set_tensor_datatype(mw.graph.input[0].name, DataType["UINT8"])
    mw.save(onnx_path)
    return onnx_path


def build(onnx_path):
    import finn.builder.build_dataflow as build
    import finn.builder.build_dataflow_config as build_cfg

    cfg = build.DataflowBuildConfig(
        output_dir=os.path.join(HERE, "output_facenet_v1"),
        fpga_part="xck26-sfvc784-2LV-c",
        synth_clk_period_ns=10.0,                 # pl_clk0 = 100 MHz
        target_fps=TARGET_FPS,
        stitched_ip_gen_dcp=True,                 # self-contained IP (docs/setup_finn.md)
        auto_fifo_depths=False,                   # plain chain: small FIFOs cannot deadlock (docs/setup_finn.md)
        verify_input_npy=os.path.join(HERE, "input.npy"),
        verify_expected_output_npy=os.path.join(HERE, "expected_output.npy"),
        verify_steps=[
            build_cfg.VerificationStepType.TIDY_UP_PYTHON,
            build_cfg.VerificationStepType.STREAMLINED_PYTHON,
            build_cfg.VerificationStepType.STITCHED_IP_RTLSIM,   # the generated RTL, bit-exact vs Brevitas
        ],
        generate_outputs=[
            build_cfg.DataflowOutputType.ESTIMATE_REPORTS,
            build_cfg.DataflowOutputType.STITCHED_IP,
            build_cfg.DataflowOutputType.RTLSIM_PERFORMANCE,
            build_cfg.DataflowOutputType.OOC_SYNTH,
        ],
        save_intermediate_models=True,
    )
    build.build_dataflow_cfg(onnx_path, cfg)


if __name__ == "__main__":
    path = export()
    if "--export-only" not in sys.argv:
        build(path)
