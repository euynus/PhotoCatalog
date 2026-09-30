#!/usr/bin/env python3
"""Converts the AI models PhotoCatalog bundles to Core ML (development tool; nothing here ships).

    uv venv --python 3.11 .venv && uv pip install --python .venv/bin/python torch==2.7.0 coremltools numpy pillow
    .venv/bin/python script/models/convert.py <model> [--weights DIR]

Each model's weights are downloaded from its authors' release, checked against the SHA-256 below,
traced at a fixed tile size and saved as Resources/Models/<Name>.mlpackage (16-bit weights).
Licenses are listed in Resources/Models/LICENSES.md.
"""
import argparse
import hashlib
import os
import sys
import urllib.request

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Resources", "Models")


def fetch(url, sha256, folder):
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, os.path.basename(url))
    if not os.path.exists(path):
        print("downloading", url)
        urllib.request.urlretrieve(url, path)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if digest != sha256:
        sys.exit(f"{path}: SHA-256 {digest} is not the expected {sha256}")
    return path


# ---- super resolution: Real-ESRGAN's general model (BSD-3-Clause, xinntao/Real-ESRGAN) ----
class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN's compact network: plain convolutions, then a pixel shuffle, on top of a
    nearest-neighbour enlargement."""

    def __init__(self, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        body = [nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        for _ in range(num_conv):
            body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        body.append(nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1))
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        return self.upsampler(out) + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


def super_resolution(weights, denoise):
    """The general model and its weak-denoise twin blended as Real-ESRGAN's own `-dn` does:
    0 keeps the photo's texture (and noise), 1 smooths it away."""
    strong = fetch("https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth",
                   "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292", weights)
    weak = fetch("https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-wdn-x4v3.pth",
                 "1641f8c4464b9f097c9fdda5589273713f67cf59f3d909e0bd688f0cee269dca", weights)
    def state(path):
        loaded = torch.load(path, map_location="cpu")
        return loaded.get("params", loaded)
    a, b = state(strong), state(weak)
    model = SRVGGNetCompact()
    model.load_state_dict({key: denoise * a[key] + (1 - denoise) * b[key] for key in a})
    return model.eval(), 256, "SuperResolution"


# ---- denoise: SCUNet trained on realistic camera noise (Apache-2.0, cszn/SCUNet) ----
# The authors' network (models/network_scunet.py) in plain tensor operations — no einops, einsum
# or boolean masks — which Core ML converts; the weights load unchanged.
class WindowAttention(nn.Module):
    """Window self-attention at a fixed resolution, so every shape, index and mask is a constant."""

    def __init__(self, dim, head_dim, window, shifted, resolution):
        super().__init__()
        self.dim, self.head_dim, self.window, self.shifted = dim, head_dim, window, shifted
        self.heads = dim // head_dim
        self.scale = head_dim ** -0.5
        self.windows = resolution // window
        self.embedding_layer = nn.Linear(dim, 3 * dim)
        self.relative_position_params = nn.Parameter(torch.zeros(self.heads, 2 * window - 1, 2 * window - 1))
        self.linear = nn.Linear(dim, dim)
        p = window
        cord = torch.tensor([[i, j] for i in range(p) for j in range(p)])
        relation = cord[:, None, :] - cord[None, :, :] + p - 1
        self.register_buffer("relative_index", (relation[:, :, 0] * (2 * p - 1) + relation[:, :, 1]).reshape(-1),
                             persistent=False)
        # A shifted window in the last row (or column) of windows wraps round: pixels from
        # either side of the wrap mustn't attend to each other. That's the last row's windows
        # times an across-the-wrap pattern of rows, plus the same for columns, kept small here
        # and put together in `forward`.
        n, s = self.windows, p - p // 2
        last = torch.zeros(n)
        last[-1] = 1
        side = (torch.arange(p) >= s).float()
        across = (side[:, None] != side[None, :]).float()   # p × p: one on each side of the wrap
        self.register_buffer("last_window", last, persistent=False)
        self.register_buffer("across_wrap", across * -10000.0, persistent=False)

    def forward(self, x):   # 1, resolution, resolution, dim
        p, n, c, heads = self.window, self.windows, self.dim, self.heads
        if self.shifted:
            x = torch.roll(x, shifts=(-(p // 2), -(p // 2)), dims=(1, 2))
        x = x.reshape(1, n, p, n, p, c).permute(0, 1, 3, 2, 4, 5).reshape(1, n * n, p * p, c)
        qkv = self.embedding_layer(x).reshape(1, n * n, p * p, 3 * heads, self.head_dim).permute(3, 0, 1, 2, 4)
        q, k, v = qkv[:heads], qkv[heads:2 * heads], qkv[2 * heads:]
        sim = torch.matmul(q, k.transpose(-1, -2)) * self.scale   # heads, 1, windows, p², p²
        bias = self.relative_position_params.reshape(heads, -1)[:, self.relative_index].reshape(heads, 1, 1, p * p, p * p)
        sim = sim + bias
        if self.shifted:
            rows = (self.last_window.reshape(n, 1, 1, 1, 1, 1) * self.across_wrap.reshape(1, 1, p, 1, p, 1))
            columns = (self.last_window.reshape(1, n, 1, 1, 1, 1) * self.across_wrap.reshape(1, 1, 1, p, 1, p))
            sim = sim + (rows + columns).reshape(1, 1, n * n, p * p, p * p)
        out = torch.matmul(torch.softmax(sim, dim=-1), v)   # heads, 1, windows, p², head_dim
        out = self.linear(out.permute(1, 2, 3, 0, 4).reshape(1, n * n, p * p, c))
        out = out.reshape(1, n, n, p, p, c).permute(0, 1, 3, 2, 4, 5).reshape(1, n * p, n * p, c)
        if self.shifted:
            out = torch.roll(out, shifts=(p // 2, p // 2), dims=(1, 2))
        return out


class TransformerBlock(nn.Module):
    def __init__(self, dim, head_dim, window, shifted, resolution):
        super().__init__()
        self.ln1 = nn.LayerNorm(dim)
        self.msa = WindowAttention(dim, head_dim, window, shifted, resolution)
        self.ln2 = nn.LayerNorm(dim)
        self.mlp = nn.Sequential(nn.Linear(dim, 4 * dim), nn.GELU(), nn.Linear(4 * dim, dim))

    def forward(self, x):
        x = x + self.msa(self.ln1(x))
        return x + self.mlp(self.ln2(x))


class ConvTransBlock(nn.Module):
    def __init__(self, conv_dim, trans_dim, shifted, resolution, head_dim=32, window=8):
        super().__init__()
        self.conv_dim, self.trans_dim = conv_dim, trans_dim
        self.trans_block = TransformerBlock(trans_dim, head_dim, window, shifted and resolution > window, resolution)
        self.conv1_1 = nn.Conv2d(conv_dim + trans_dim, conv_dim + trans_dim, 1, 1, 0)
        self.conv1_2 = nn.Conv2d(conv_dim + trans_dim, conv_dim + trans_dim, 1, 1, 0)
        self.conv_block = nn.Sequential(nn.Conv2d(conv_dim, conv_dim, 3, 1, 1, bias=False), nn.ReLU(True),
                                        nn.Conv2d(conv_dim, conv_dim, 3, 1, 1, bias=False))

    def forward(self, x):
        conv_x, trans_x = torch.split(self.conv1_1(x), (self.conv_dim, self.trans_dim), dim=1)
        conv_x = self.conv_block(conv_x) + conv_x
        trans_x = self.trans_block(trans_x.permute(0, 2, 3, 1)).permute(0, 3, 1, 2)
        return x + self.conv1_2(torch.cat((conv_x, trans_x), dim=1))


class SCUNet(nn.Module):
    def __init__(self, config=(4, 4, 4, 4, 4, 4, 4), dim=64, resolution=256):
        super().__init__()
        def blocks(count, width, res):
            return [ConvTransBlock(width, width, i % 2 == 1, res) for i in range(count)]
        self.m_head = nn.Sequential(nn.Conv2d(3, dim, 3, 1, 1, bias=False))
        self.m_down1 = nn.Sequential(*blocks(config[0], dim // 2, resolution), nn.Conv2d(dim, 2 * dim, 2, 2, 0, bias=False))
        self.m_down2 = nn.Sequential(*blocks(config[1], dim, resolution // 2), nn.Conv2d(2 * dim, 4 * dim, 2, 2, 0, bias=False))
        self.m_down3 = nn.Sequential(*blocks(config[2], 2 * dim, resolution // 4), nn.Conv2d(4 * dim, 8 * dim, 2, 2, 0, bias=False))
        self.m_body = nn.Sequential(*blocks(config[3], 4 * dim, resolution // 8))
        self.m_up3 = nn.Sequential(nn.ConvTranspose2d(8 * dim, 4 * dim, 2, 2, 0, bias=False), *blocks(config[4], 2 * dim, resolution // 4))
        self.m_up2 = nn.Sequential(nn.ConvTranspose2d(4 * dim, 2 * dim, 2, 2, 0, bias=False), *blocks(config[5], dim, resolution // 2))
        self.m_up1 = nn.Sequential(nn.ConvTranspose2d(2 * dim, dim, 2, 2, 0, bias=False), *blocks(config[6], dim // 2, resolution))
        self.m_tail = nn.Sequential(nn.Conv2d(dim, 3, 3, 1, 1, bias=False))

    def forward(self, x0):   # resolution × resolution tiles
        x1 = self.m_head(x0)
        x2 = self.m_down1(x1)
        x3 = self.m_down2(x2)
        x4 = self.m_down3(x3)
        x = self.m_body(x4)
        x = self.m_up3(x + x4)
        x = self.m_up2(x + x3)
        x = self.m_up1(x + x2)
        return self.m_tail(x + x1)


def load_scunet(path):
    state = torch.load(path, map_location="cpu")
    model = SCUNet()
    heads = {key: value for key, value in state.items() if key.endswith("relative_position_params")}
    for key, value in heads.items():
        if value.dim() == 2:   # stored flat by older checkpoints: (2w-1)², heads
            window = int(round(value.shape[0] ** 0.5))
            state[key] = value.view(window, window, -1).permute(2, 0, 1)
    model.load_state_dict(state)
    return model.eval()


def denoise(weights, _):
    path = fetch("https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_psnr.pth",
                 "fa78899ba2caec9d235a900e91d96c689da71c42029230c2028b00f09f809c2e", weights)
    return load_scunet(path), 256, "Denoise"


MODELS = {"superresolution": super_resolution, "denoise": denoise}


def convert(name, weights, denoise, out):
    import coremltools as ct
    model, tile, output_name = MODELS[name](weights, denoise)
    example = torch.rand(1, 3, tile, tile)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=example.shape)],
                         outputs=[ct.TensorType(name="output")], convert_to="mlprogram",
                         compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
    # the conversion should change nothing but rounding
    with torch.no_grad():
        expected = model(example).numpy()
    got = mlmodel.predict({"input": example.numpy()})["output"]
    error = float(np.abs(got - expected).max())
    print(f"{output_name}: largest difference from PyTorch {error:.4f}")
    if error > 0.05:
        sys.exit("the converted model doesn't match")
    os.makedirs(out, exist_ok=True)
    mlmodel.short_description = f"{output_name} ({tile}x{tile} tiles)"
    mlmodel.save(os.path.join(out, f"{output_name}.mlpackage"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("model", choices=sorted(MODELS))
    parser.add_argument("--weights", default=os.path.join(ROOT, ".build", "model-weights"))
    parser.add_argument("--denoise", type=float, default=0.0, help="super resolution: 0 keeps texture, 1 smooths")
    parser.add_argument("--out", default=OUT)
    arguments = parser.parse_args()
    convert(arguments.model, arguments.weights, arguments.denoise, arguments.out)
