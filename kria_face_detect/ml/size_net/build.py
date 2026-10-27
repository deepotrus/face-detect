# Sizing build for the face detector network (random weights, no training).
#
# Defines the candidate network in Brevitas, exports it to QONNX and runs FINN up to the
# estimate reports, stitched IP and out-of-context synthesis for the KV260 chip. FINN's
# resources depend on layer sizes and bit widths, not on the weight values, so this gives
# real LUT/BRAM/DSP/fps numbers before any training.
#
# Network contract:
#   input : 1 x 1 x 120 x 160, UINT8 gray (from downscale4x), one pixel per stream beat
#   output: 1 x 15 x 20 x 2 (NHWC), INT8: per 8x8-pixel cell a face score and a face size
#   4-bit weights and activations, conv 3x3 + BN + ReLU blocks, 2x2 max-pool to stride 8
#
# Run from ~/finn:  ./run-docker.sh build_custom <path to this folder>
# Output:           size_net.onnx, output_size_net/ (report/, stitched_ip/, ...)

import torch
import torch.nn as nn
import brevitas.nn as qnn
from brevitas.export import export_qonnx
from qonnx.core.datatype import DataType
from qonnx.core.modelwrapper import ModelWrapper
from qonnx.util.cleanup import cleanup

import finn.builder.build_dataflow as build
import finn.builder.build_dataflow_config as build_cfg

IN_H, IN_W = 120, 160
W_BITS = 4        # weights
A_BITS = 4        # activations
OUT_BITS = 8      # score and size

# (in_channels, out_channels, max-pool after the block)
BLOCKS = [
    (1, 8, True),     # 160x120 -> 80x60
    (8, 16, True),    #  80x60  -> 40x30
    (16, 32, True),   #  40x30  -> 20x15
    (32, 32, False),  #  20x15
    (32, 32, False),  #  20x15
    (32, 32, False),  #  20x15  (receptive field ~70 px)
]
HEAD_OUT = 2      # face score, face size


class FaceNet(nn.Module):
    def __init__(self):
        super().__init__()
        layers = []
        for cin, cout, pool in BLOCKS:
            layers += [
                qnn.QuantConv2d(cin, cout, 3, padding=1, bias=False, weight_bit_width=W_BITS),
                nn.BatchNorm2d(cout),
                qnn.QuantReLU(bit_width=A_BITS),
            ]
            if pool:
                layers.append(nn.MaxPool2d(2))
        layers += [
            qnn.QuantConv2d(BLOCKS[-1][1], HEAD_OUT, 1, bias=False, weight_bit_width=W_BITS),
            qnn.QuantIdentity(bit_width=OUT_BITS),
        ]
        self.net = nn.Sequential(*layers)

    def forward(self, x):
        return self.net(x)


def count(model):
    params = sum(p.numel() for n, p in model.named_parameters() if "weight" in n and p.dim() == 4)
    macs, h, w = 0, IN_H, IN_W
    for cin, cout, pool in BLOCKS:
        macs += h * w * 9 * cin * cout
        if pool:
            h, w = h // 2, w // 2
    macs += h * w * BLOCKS[-1][1] * HEAD_OUT
    rf, stride = 1, 1
    for _, _, pool in BLOCKS:
        rf += 2 * stride
        if pool:
            rf += stride
            stride *= 2
    return params, macs, rf, (h, w)


torch.manual_seed(0)
model = FaceNet()
for m in model.modules():                     # realistic-looking BN statistics
    if isinstance(m, nn.BatchNorm2d):
        m.running_mean.uniform_(-1.0, 1.0)
        m.running_var.uniform_(0.5, 2.0)
model.eval()

params, macs, rf, grid = count(model)
print(f"[size_net] conv weights: {params}, MACs/frame: {macs / 1e6:.1f} M, "
      f"receptive field: {rf} px, output grid: {grid[1]}x{grid[0]}")

export_qonnx(model, torch.randint(0, 256, (1, 1, IN_H, IN_W)).float(), "size_net_raw.onnx")
cleanup("size_net_raw.onnx", out_file="size_net.onnx")
mw = ModelWrapper("size_net.onnx")
mw.set_tensor_datatype(mw.graph.input[0].name, DataType["UINT8"])   # raw 0..255 gray pixels
mw.save("size_net.onnx")

cfg = build.DataflowBuildConfig(
    output_dir="output_size_net",
    fpga_part="xck26-sfvc784-2LV-c",
    synth_clk_period_ns=10.0,                 # pl_clk0 = 100 MHz
    target_fps=60,                            # 2x the webcam rate, FINN picks the folding
    stitched_ip_gen_dcp=True,                 # self-contained IP (see tfc_example README)
    # The network is a plain chain (no branches/skips), so small FIFOs cannot deadlock:
    # backpressure just stalls the faster layers. FINN's automatic sizing (rtlsim with huge
    # FIFOs) measured how far early layers can run ahead (262144 entries, beyond the 32768
    # limit of the Xilinx FIFO IP), not what is needed. Keep FINN's small default FIFOs.
    auto_fifo_depths=False,
    generate_outputs=[
        build_cfg.DataflowOutputType.ESTIMATE_REPORTS,
        build_cfg.DataflowOutputType.STITCHED_IP,
        build_cfg.DataflowOutputType.RTLSIM_PERFORMANCE,
        build_cfg.DataflowOutputType.OOC_SYNTH,
    ],
    save_intermediate_models=True,
)

build.build_dataflow_cfg("size_net.onnx", cfg)
