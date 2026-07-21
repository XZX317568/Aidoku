#!/usr/bin/env python3
"""
Convert Real-CUGAN (2x, no-denoise) PyTorch model to CoreML format
compatible with Aidoku's MultiArrayModel block-based interface.

Aidoku MultiArrayModel interface:
  - Input:  [1, 3, blockSize, blockSize]  (float32, values in [0,1])
  - Output: [1, 3, effectiveBlock*scale, effectiveBlock*scale]
    where effectiveBlock = blockSize - 2*shrinkSize

For Real-CUGAN we use: blockSize=196, shrinkSize=20, scale=2
  - Input:  [1, 3, 196, 196]
  - Output: [1, 3, 312, 312]  ((196-40)*2)

Architecture inlined from bilibili/ailab Real-CUGAN upcunet_v3.py (MIT license).
"""
import os
import sys
import urllib.request
import zipfile

import torch
import torch.nn as nn
import torch.nn.functional as F

# ---------------------------------------------------------------------------
# Real-CUGAN architecture (from upcunet_v3.py, MIT license, bilibili/ailab)
# ---------------------------------------------------------------------------
class SEBlock(nn.Module):
    def __init__(self, in_channels, reduction=8, bias=False):
        super(SEBlock, self).__init__()
        self.conv1 = nn.Conv2d(in_channels, in_channels // reduction, 1, 1, 0, bias=bias)
        self.conv2 = nn.Conv2d(in_channels // reduction, in_channels, 1, 1, 0, bias=bias)

    def forward(self, x):
        x0 = torch.mean(x, dim=(2, 3), keepdim=True)
        x0 = self.conv1(x0)
        x0 = F.relu(x0, inplace=True)
        x0 = self.conv2(x0)
        x0 = torch.sigmoid(x0)
        x = torch.mul(x, x0)
        return x


class UNetConv(nn.Module):
    def __init__(self, in_channels, mid_channels, out_channels, se):
        super(UNetConv, self).__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_channels, mid_channels, 3, 1, 0),
            nn.LeakyReLU(0.1, inplace=True),
            nn.Conv2d(mid_channels, out_channels, 3, 1, 0),
            nn.LeakyReLU(0.1, inplace=True),
        )
        if se:
            self.seblock = SEBlock(out_channels, reduction=8, bias=True)
        else:
            self.seblock = None

    def forward(self, x):
        z = self.conv(x)
        if self.seblock is not None:
            z = self.seblock(z)
        return z


class UNet1(nn.Module):
    def __init__(self, in_channels, out_channels, deconv):
        super(UNet1, self).__init__()
        self.conv1 = UNetConv(in_channels, 32, 64, se=False)
        self.conv1_down = nn.Conv2d(64, 64, 2, 2, 0)
        self.conv2 = UNetConv(64, 128, 64, se=True)
        self.conv2_up = nn.ConvTranspose2d(64, 64, 2, 2, 0)
        self.conv3 = nn.Conv2d(64, 64, 3, 1, 0)
        if deconv:
            self.conv_bottom = nn.ConvTranspose2d(64, out_channels, 4, 2, 3)
        else:
            self.conv_bottom = nn.Conv2d(64, out_channels, 3, 1, 0)

    def forward(self, x):
        x1 = self.conv1(x)
        x2 = self.conv1_down(x1)
        x1 = x1[:, :, 4:-4, 4:-4]  # crop 4px border (was F.pad negative, unsupported by CoreML)
        x2 = F.leaky_relu(x2, 0.1, inplace=True)
        x2 = self.conv2(x2)
        x2 = self.conv2_up(x2)
        x2 = F.leaky_relu(x2, 0.1, inplace=True)
        x3 = self.conv3(x1 + x2)
        x3 = F.leaky_relu(x3, 0.1, inplace=True)
        z = self.conv_bottom(x3)
        return z


class UNet2(nn.Module):
    def __init__(self, in_channels, out_channels, deconv):
        super(UNet2, self).__init__()
        self.conv1 = UNetConv(in_channels, 32, 64, se=False)
        self.conv1_down = nn.Conv2d(64, 64, 2, 2, 0)
        self.conv2 = UNetConv(64, 64, 128, se=True)
        self.conv2_down = nn.Conv2d(128, 128, 2, 2, 0)
        self.conv3 = UNetConv(128, 256, 128, se=True)
        self.conv3_up = nn.ConvTranspose2d(128, 128, 2, 2, 0)
        self.conv4 = UNetConv(128, 64, 64, se=True)
        self.conv4_up = nn.ConvTranspose2d(64, 64, 2, 2, 0)
        self.conv5 = nn.Conv2d(64, 64, 3, 1, 0)
        if deconv:
            self.conv_bottom = nn.ConvTranspose2d(64, out_channels, 4, 2, 3)
        else:
            self.conv_bottom = nn.Conv2d(64, out_channels, 3, 1, 0)

    def forward(self, x, alpha=1):
        x1 = self.conv1(x)
        x2 = self.conv1_down(x1)
        x1 = x1[:, :, 16:-16, 16:-16]  # crop 16px border (was F.pad negative, unsupported by CoreML)
        x2 = F.leaky_relu(x2, 0.1, inplace=True)
        x2 = self.conv2(x2)
        x3 = self.conv2_down(x2)
        x2 = x2[:, :, 4:-4, 4:-4]  # crop 4px border (was F.pad negative, unsupported by CoreML)
        x3 = F.leaky_relu(x3, 0.1, inplace=True)
        x3 = self.conv3(x3)
        x3 = self.conv3_up(x3)
        x3 = F.leaky_relu(x3, 0.1, inplace=True)
        x4 = self.conv4(x2 + x3)
        x4 = x4 * alpha
        x4 = self.conv4_up(x4)
        x4 = F.leaky_relu(x4, 0.1, inplace=True)
        x5 = self.conv5(x1 + x4)
        x5 = F.leaky_relu(x5, 0.1, inplace=True)
        z = self.conv_bottom(x5)
        return z


class UpCunet2x(nn.Module):
    def __init__(self, in_channels=3, out_channels=3):
        super(UpCunet2x, self).__init__()
        self.unet1 = UNet1(in_channels, out_channels, deconv=True)
        self.unet2 = UNet2(in_channels, out_channels, deconv=False)


# ---------------------------------------------------------------------------
# Wrapper matching Aidoku's MultiArrayModel block interface
# ---------------------------------------------------------------------------
class AidokuRealCUGANBlock(nn.Module):
    """
    Wraps Real-CUGAN 2x into Aidoku's block interface.

    Input:  [1, 3, blockSize, blockSize] in [0,1]  (blockSize includes shrink border)
    Output: [1, 3, (blockSize-2*shrink)*2, (blockSize-2*shrink)*2] in [0,1]

    IMPORTANT: All sizes are hardcoded Python ints (no dynamic x.shape access)
    because torch.jit.trace turns shape access into 0-dim tensors that
    coremltools cannot convert to scalar op parameters.

    Logic is identical to the official UpCunet2x.forward(tile_mode=0, alpha=1)
    followed by Aidoku's shrink-border crop:
        inp = reflect_pad(x, 18)          # ensure even + border
        out1 = unet1(inp)                 # 2x upsample
        out2 = unet2(out1, alpha=1)       # refinement
        result = out2 + crop20(out1)      # residual add
        result = center_crop(result)      # drop shrink border
    """
    def __init__(self, model, shrink_size, scale=2):
        super(AidokuRealCUGANBlock, self).__init__()
        self.unet1 = model.unet1
        self.unet2 = model.unet2
        self.shrink_size = shrink_size
        self.scale = scale

    def forward(self, x):
        # For BLOCK_SIZE=196 (even): ph = pw = 196, so pad = (18,18,18,18)
        inp = F.pad(x, (18, 18, 18, 18), 'reflect')
        out1 = self.unet1.forward(inp)          # 2x upsample
        out2 = self.unet2.forward(out1, 1)      # refinement (residual)
        # F.pad(out1, (-20,-20,-20,-20)) == crop 20px border each side
        out1c = out1[:, :, 20:-20, 20:-20]
        result = torch.add(out2, out1c)         # [0,1] range, 2x of input
        # Center-crop to Aidoku's expected output: (196 - 2*20) * 2 = 312
        # crop offset = shrink*scale = 40, target size = 312
        result = result[:, :, 40:352, 40:352]
        return result


# ---------------------------------------------------------------------------
# Main conversion
# ---------------------------------------------------------------------------
WEIGHTS_URL = "https://github.com/bilibili/ailab/releases/download/Real-CUGAN/updated_weights.zip"
BLOCK_SIZE = 196   # Aidoku config: input block size (includes shrink border)
SHRINK_SIZE = 20   # Aidoku config: border to discard per side (input pixels)
SCALE = 2


def download_weights(workdir):
    """Download and extract Real-CUGAN weights, return path to the 2x no-denoise .pth."""
    zip_path = os.path.join(workdir, "updated_weights.zip")
    if not os.path.exists(zip_path):
        print(f"Downloading weights from {WEIGHTS_URL} ...")
        urllib.request.urlretrieve(WEIGHTS_URL, zip_path)
        print("Download complete.")
    else:
        print("Using cached weights zip.")

    print("Extracting ...")
    with zipfile.ZipFile(zip_path, 'r') as zf:
        zf.extractall(workdir)

    # Locate the 2x no-denoise weight file
    candidates = []
    for root, _, files in os.walk(workdir):
        for f in files:
            if f.endswith(".pth"):
                candidates.append(os.path.join(root, f))

    print("Found .pth files:")
    for c in candidates:
        print(f"  {c}")

    # Prefer the 2x no-denoise model (check this FIRST to avoid matching denoise1x/2x/3x)
    for c in candidates:
        base = os.path.basename(c).lower()
        if "2x" in base and ("no-denoise" in base or "nodenoise" in base or "no_denoise" in base):
            return c
    # Fallback: conservative 2x model
    for c in candidates:
        base = os.path.basename(c).lower()
        if "2x" in base and "conservative" in base:
            return c
    # Fallback: any 2x model
    for c in candidates:
        if "2x" in os.path.basename(c).lower():
            return c

    raise RuntimeError("Could not locate a 2x .pth weight file. See list above.")


def diagnose_shapes(model):
    """Print intermediate tensor shapes for the full forward pass (debug aid)."""
    print("--- Shape diagnostics ---")
    try:
        with torch.no_grad():
            x = torch.rand(1, 3, BLOCK_SIZE, BLOCK_SIZE)
            print(f"input:            {list(x.shape)}")
            inp = F.pad(x, (18, 18, 18, 18), 'reflect')
            print(f"after reflect18:  {list(inp.shape)}")
            out1 = model.unet1.forward(inp)
            print(f"unet1 output:     {list(out1.shape)}")
            out2 = model.unet2.forward(out1, 1)
            print(f"unet2 output:     {list(out2.shape)}")
            out1c = out1[:, :, 20:-20, 20:-20]
            print(f"unet1 cropped:    {list(out1c.shape)}")
            added = torch.add(out2, out1c)
            print(f"after add:        {list(added.shape)}")
            final = added[:, :, 40:352, 40:352]
            print(f"final crop:       {list(final.shape)}")
    except Exception as e:
        print(f"diagnostics FAILED: {e}")
    print("--- end diagnostics ---")


def main():
    workdir = os.path.dirname(os.path.abspath(__file__))
    workdir = os.path.join(workdir, "realcugan_work")
    os.makedirs(workdir, exist_ok=True)

    weight_path = download_weights(workdir)
    print(f"Using weight file: {weight_path}")

    # Load model
    print("Loading PyTorch model ...")
    model = UpCunet2x(in_channels=3, out_channels=3)
    state_dict = torch.load(weight_path, map_location="cpu")
    # Some checkpoints wrap the state_dict; handle both cases
    if "state_dict" in state_dict:
        state_dict = state_dict["state_dict"]
    missing, unexpected = model.load_state_dict(state_dict, strict=False)
    print(f"load_state_dict: missing={len(missing)}, unexpected={len(unexpected)}")
    if missing:
        print(f"  missing keys (first 10): {missing[:10]}")
    if unexpected:
        print(f"  unexpected keys (first 10): {unexpected[:10]}")
    model.eval()

    # Wrap for Aidoku block interface
    wrapper = AidokuRealCUGANBlock(model, shrink_size=SHRINK_SIZE, scale=SCALE)
    wrapper.eval()

    # Verify sizes with a dummy forward pass
    dummy = torch.rand(1, 3, BLOCK_SIZE, BLOCK_SIZE)
    with torch.no_grad():
        out = wrapper(dummy)
    expected_out = (BLOCK_SIZE - 2 * SHRINK_SIZE) * SCALE
    print(f"Input shape:  {list(dummy.shape)}")
    print(f"Output shape: {list(out.shape)}")
    print(f"Expected output: [1, 3, {expected_out}, {expected_out}]")
    assert out.shape == (1, 3, expected_out, expected_out), \
        f"Output shape mismatch! Got {out.shape}, expected (1,3,{expected_out},{expected_out})"
    print("Size verification PASSED.")

    # Diagnostic: print intermediate shapes to confirm dimension flow
    diagnose_shapes(model)

    # Trace the model
    print("Tracing model ...")
    traced = torch.jit.trace(wrapper, dummy)
    print("Trace complete.")

    # Convert to CoreML
    print("Converting to CoreML (this may take a few minutes) ...")
    import coremltools as ct
    print(f"coremltools version: {ct.__version__}")
    print(f"torch version: {torch.__version__}")

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 3, BLOCK_SIZE, BLOCK_SIZE))],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        skip_model_load=True,
    )

    out_path = os.path.join(workdir, "RealCUGAN_2x_anime.mlpackage")
    mlmodel.save(out_path)
    print(f"Saved CoreML model to: {out_path}")

    # Zip the .mlpackage (it's a directory) for distribution.
    # IMPORTANT: archive entries must be at the TOP LEVEL (Manifest.json, Data/...)
    # with NO wrapping directory, matching the official Aidoku model zips.
    # Aidoku unzips into Models/<name>.mlpackage/, so a wrapping dir would nest wrongly.
    zip_out = out_path + ".zip"
    print(f"Zipping to: {zip_out}")
    with zipfile.ZipFile(zip_out, "w", zipfile.ZIP_STORED) as zf:
        for root, dirs, files in os.walk(out_path):
            for d in dirs:
                full = os.path.join(root, d)
                arcname = os.path.relpath(full, out_path) + "/"
                zf.writestr(arcname, "")
            for f in files:
                full = os.path.join(root, f)
                arcname = os.path.relpath(full, out_path)
                zf.write(full, arcname)
    print(f"Zip size: {os.path.getsize(zip_out) / 1024 / 1024:.1f} MB")
    print("DONE.")


if __name__ == "__main__":
    main()
