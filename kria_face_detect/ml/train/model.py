# FaceNet: the face detector network, shared by training and the FINN export.
# Same architecture as the sizing build (ml/size_net/build.py, measured 12.6k LUT, 0 DSP on XCK26).
#
#   input : N x 1 x 120 x 160, gray pixels 0..255 (UINT8 in hardware, from downscale4x)
#   output: N x 2 x 15 x 20, per 8x8-pixel cell: [0] face score (logit), [1] face size code
#   4-bit weights and activations, 8-bit output, conv 3x3 + BN + ReLU blocks, max-pool to stride 8

import torch.nn as nn
import brevitas.nn as qnn

IN_H, IN_W = 120, 160
GRID_H, GRID_W = 15, 20
CELL = 8                      # input pixels per grid cell
W_BITS = 4
A_BITS = 4
OUT_BITS = 8

# (in_channels, out_channels, max-pool after the block)
BLOCKS = [
    (1, 8, True),     # 160x120 -> 80x60
    (8, 16, True),    #  80x60  -> 40x30
    (16, 32, True),   #  40x30  -> 20x15
    (32, 32, False),  #  20x15
    (32, 32, False),  #  20x15
    (32, 32, False),  #  20x15  (receptive field 70 px)
]
HEAD_OUT = 2          # face score, face size


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
