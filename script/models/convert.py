#!/usr/bin/env python3
"""Converts the AI models PhotoCatalog bundles to Core ML (development tool; nothing here ships).

    uv venv --python 3.11 .venv && uv pip install --python .venv/bin/python torch==2.7.0 coremltools numpy pillow onnx
    .venv/bin/python script/models/convert.py <model> [--weights DIR]

Each model's weights are downloaded from its authors' release, checked against the SHA-256 below,
traced at a fixed tile size and saved as Resources/Models/<Name>.mlpackage (16-bit weights).
`depth`, `segmentation` and `objects` fetch Apple's own Core ML conversions instead, unchanged.
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


# ---- smart remove: LaMa, big-lama (Apache-2.0, advimman/lama), as IOPaint exports it ----
def inpaint(weights, _):
    """The generator as a TorchScript module (image and mask in, the filled image out); it
    blanks the hole itself, so nothing under the mask reaches the result."""
    path = fetch("https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt",
                 "344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9", weights)
    return torch.jit.load(path, map_location="cpu").eval(), 512, "Inpaint"


# ---- people: SFace (Apache-2.0, opencv/opencv_zoo's face_recognition_sface) ----
class SFace(nn.Module):
    """SFace's MobileFaceNet, run step by step from its ONNX graph, which is a plain chain:
    pixels scaled to ±1, convolutions each with a batch norm and PReLU, then a fully connected
    layer and batch norm to 128 numbers. Its weights are used unchanged."""

    def __init__(self, path):
        super().__init__()
        import onnx
        from onnx import numpy_helper
        graph = onnx.load(path).graph
        tensors = {t.name: torch.from_numpy(numpy_helper.to_array(t).copy()) for t in graph.initializer}
        self.steps = []
        for index, node in enumerate(graph.node):
            for k, name in enumerate(node.input[1:]):
                self.register_buffer(f"t{index}_{k}", tensors[name])
            attributes = {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}
            self.steps.append((node.op_type, attributes, len(node.input) - 1))

    def forward(self, x):
        for index, (op, attributes, count) in enumerate(self.steps):
            t = [getattr(self, f"t{index}_{k}") for k in range(count)]
            if op == "Sub":
                x = x - t[0]
            elif op == "Mul":
                x = x * t[0]
            elif op == "Conv":
                x = F.conv2d(x, t[0], t[1] if count > 1 else None, attributes["strides"],
                             attributes["pads"][:2], 1, attributes["group"])
            elif op == "BatchNormalization":
                x = F.batch_norm(x, t[2], t[3], t[0], t[1], False, 0.0, attributes["epsilon"])
            elif op == "PRelu":
                x = F.prelu(x, t[0].flatten())
            elif op == "Flatten":
                x = torch.flatten(x, 1)
            elif op == "Gemm":
                x = F.linear(x, t[0], t[1])
            elif op != "Dropout":
                raise ValueError(f"SFace: unexpected {op}")
        return x


def faces(weights, _):
    """A face, aligned to the 112-pixel ArcFace template, in; 128 numbers out, which sit close
    together for one person's faces."""
    path = fetch("https://github.com/opencv/opencv_zoo/raw/47534e27c9851bb1128ccc0102f1145e27f23f98/"
                 "models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
                 "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79", weights)
    return SFace(path).eval(), 112, "FaceRecognition"


def convert_faces(model, tile, out):
    """An RGB image in (0…255, as OpenCV feeds SFace), the 128 numbers out as 32-bit floats."""
    import coremltools as ct
    from PIL import Image
    pixels = np.random.default_rng(0).integers(0, 256, (tile, tile, 3), dtype=np.uint8)
    example = torch.from_numpy(pixels).permute(2, 0, 1)[None].float()
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=example.shape, color_layout=ct.colorlayout.RGB)],
                         outputs=[ct.TensorType(name="embedding", dtype=np.float32)], convert_to="mlprogram",
                         compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
    with torch.no_grad():
        expected = model(example).numpy().ravel()
    got = mlmodel.predict({"image": Image.fromarray(pixels)})["embedding"].ravel()
    # what matters is the direction: faces are compared by angle
    cosine = float(got @ expected / np.linalg.norm(got) / np.linalg.norm(expected))
    print(f"FaceRecognition: cosine to PyTorch {cosine:.5f}")
    if cosine < 0.999:
        sys.exit("the converted model doesn't match")
    os.makedirs(out, exist_ok=True)
    mlmodel.short_description = "SFace face recognition (112x112 aligned faces)"
    mlmodel.save(os.path.join(out, "FaceRecognition.mlpackage"))


def quantize_inpaint(mlmodel):
    """8-bit weights for the plain convolutions between LaMa's local and global branches (three
    quarters of it); the Fourier units and the first and last layers stay 16-bit, since
    quantizing those tints the fill."""
    import re
    import coremltools.optimize.coreml as cto
    block = list(mlmodel.get_spec().mlProgram.functions["main"].block_specializations.values())[0]
    names = [op.outputs[0].name for op in block.operations if op.type == "const"
             and re.search(r"_(convl2g|convg2l|convl2l)_weight_to_fp16$", op.outputs[0].name)]
    config = cto.OptimizationConfig(op_name_configs={n: cto.OpLinearQuantizerConfig(mode="linear_symmetric") for n in names})
    return cto.linear_quantize_weights(mlmodel, config)


MODELS = {"superresolution": super_resolution, "denoise": denoise, "inpaint": inpaint, "faces": faces}

# ---- used as Apple converted and published them in Core ML (all Apache-2.0) ----
HF = "https://huggingface.co/apple/"
CORE_ML = "Data/com.apple.CoreML/"
PUBLISHED = {
    # Depth Anything V2 Small: 16-bit activations, 8-bit palettized weights
    "depth": [("Depth", HF + "coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16P8.mlpackage/", {
        "Manifest.json": "5530317f2a7c4318b34efd9855694480a78122d8be89e703278b0f7b9337dbdc",
        CORE_ML + "model.mlmodel": "da3f4c6a8be93a439b1bc56ba57074c09f270b3d28052d798bc106d1259e5a1d",
        CORE_ML + "weights/weight.bin": "660a57cf7becfeac080a9bb02a263be59fd57b5c4d17ff8912833bc8b6edae04",
    })],
    # DETR ResNet-50 semantic segmentation (COCO things and stuff), 8-bit palettized weights
    "segmentation": [("Segmentation", HF + "coreml-detr-semantic-segmentation/resolve/main/"
                      "DETRResnet50SemanticSegmentationF16P8.mlpackage/", {
        "Manifest.json": "e7154240ddfd55b776642ae4f6b47d42bf8ad1b9425d97151d4d7b7875d0bf95",
        CORE_ML + "model.mlmodel": "3d3666837fe990d3948308e417949864b5c2ab0dd9f21091c755c8effa005c40",
        CORE_ML + "weights/weight.bin": "8e0a22ecc1921f81611864434714ae1989f3e992ec04994ed22a8ead6deccce7",
    })],
    # SAM 2.1 Tiny, 16-bit: the image encoder, the prompt encoder and the mask decoder
    "objects": [
        ("ObjectEncoder", HF + "coreml-sam2.1-tiny/resolve/main/SAM2_1TinyImageEncoderFLOAT16.mlpackage/", {
            "Manifest.json": "dd72aa75e3f2f92d0653696bf4d8350d87690d92b116b34912fe640f2b116e08",
            CORE_ML + "model.mlmodel": "6cbc50301ee3ff4a9366083f9647e1f06762759542d8dd0fac394ebc3682cce7",
            CORE_ML + "weights/weight.bin": "eab96eb8ff35720c79eedc0cac2a4ef32d685f9c994c39736027078528c48a97",
        }),
        ("ObjectPrompt", HF + "coreml-sam2.1-tiny/resolve/main/SAM2_1TinyPromptEncoderFLOAT16.mlpackage/", {
            "Manifest.json": "0c0f9b80f0445017dac52f81e93aeb50b9c2c9918708c882df4a65671fda2bd4",
            CORE_ML + "model.mlmodel": "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3",
            CORE_ML + "weights/weight.bin": "af466cf28ef8838f409c2bfd8cc0049b9efbf9db335d60a57dbfc5160af883f2",
        }),
        ("ObjectDecoder", HF + "coreml-sam2.1-tiny/resolve/main/SAM2_1TinyMaskDecoderFLOAT16.mlpackage/", {
            "Manifest.json": "dc6121b61ac560498080d55f9d5fb293cdb305f942a85adb5b71dc8e9d14a8aa",
            CORE_ML + "model.mlmodel": "4601f302d4c6936e15de3a22089c2afe1fa009ef703f82147ff829b4be677577",
            CORE_ML + "weights/weight.bin": "f5a8635981199fa1199007ed6798c61a326288548b74553b3c2ddb932fcdc8de",
        }),
    ],
}


def fetch_published(name, out):
    """Apple's Core ML packages are used as published: each file checked against its SHA-256
    and put into the package under the app's name for it."""
    for package, base, files in PUBLISHED[name]:
        for relative, sha256 in files.items():
            target = os.path.join(out, f"{package}.mlpackage", relative)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            print("downloading", base + relative)
            urllib.request.urlretrieve(base + relative, target)
            digest = hashlib.sha256(open(target, "rb").read()).hexdigest()
            if digest != sha256:
                sys.exit(f"{target}: SHA-256 {digest} is not the expected {sha256}")


def convert(name, weights, denoise, out):
    import coremltools as ct
    model, tile, output_name = MODELS[name](weights, denoise)
    if name == "faces":
        return convert_faces(model, tile, out)
    if name == "inpaint":
        # a smooth image with a rectangular hole: random noise has no structure to fill from
        ramp = torch.linspace(0, 1, tile)
        example = torch.stack([ramp[None, :].expand(tile, tile), ramp[:, None].expand(tile, tile),
                               torch.full((tile, tile), 0.5)])[None]
        mask = torch.zeros(1, 1, tile, tile)
        mask[:, :, tile // 3:tile // 2, tile // 3:tile // 2] = 1
        mlmodel = ct.convert(model, inputs=[ct.TensorType(name="image", shape=example.shape),
                                            ct.TensorType(name="mask", shape=mask.shape)],
                             outputs=[ct.TensorType(name="output")], convert_to="mlprogram",
                             compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
        mlmodel = quantize_inpaint(mlmodel)
        feed, inputs = {"image": example.numpy(), "mask": mask.numpy()}, (example, mask)
    else:
        example = torch.rand(1, 3, tile, tile)
        traced = torch.jit.trace(model, example)
        mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=example.shape)],
                             outputs=[ct.TensorType(name="output")], convert_to="mlprogram",
                             compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
        feed, inputs = {"input": example.numpy()}, (example,)
    # the conversion should change nothing but rounding
    with torch.no_grad():
        expected = model(*inputs).numpy()
    got = mlmodel.predict(feed)["output"]
    error, mean = float(np.abs(got - expected).max()), float(np.abs(got - expected).mean())
    print(f"{output_name}: difference from PyTorch largest {error:.4f}, mean {mean:.5f}")
    if error > 0.05 and mean > 0.002:
        sys.exit("the converted model doesn't match")
    os.makedirs(out, exist_ok=True)
    mlmodel.short_description = f"{output_name} ({tile}x{tile} tiles)"
    mlmodel.save(os.path.join(out, f"{output_name}.mlpackage"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("model", choices=sorted(MODELS) + sorted(PUBLISHED))
    parser.add_argument("--weights", default=os.path.join(ROOT, ".build", "model-weights"))
    parser.add_argument("--denoise", type=float, default=0.0, help="super resolution: 0 keeps texture, 1 smooths")
    parser.add_argument("--out", default=OUT)
    arguments = parser.parse_args()
    if arguments.model in PUBLISHED:
        fetch_published(arguments.model, arguments.out)
    else:
        convert(arguments.model, arguments.weights, arguments.denoise, arguments.out)
