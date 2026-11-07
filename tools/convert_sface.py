#!/usr/bin/env python3
"""
Convert the OpenCV Zoo SFace face-recognition model (ONNX, Apache-2.0) into
the Core ML package that FaceUnlock bundles:

    Models/SFace.mlpackage
        input : "image"     112x112 RGB image, raw 0..255 pixels
        output: "embedding" 128 floats (not L2-normalised; Swift does that)

The ONNX graph already contains its own normalisation ((px - 127.5) / 128),
so the Core ML image input applies no scale/bias.

The ONNX file is NOT committed. Download it yourself (≈37 MB):

    https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface
    file: face_recognition_sface_2021dec.onnx
    sha256: 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79

Then, in a throwaway virtualenv outside the repo:

    pip install coremltools onnx onnx2torch torch onnxruntime numpy pillow
    python -I tools/convert_sface.py --onnx /path/to/face_recognition_sface_2021dec.onnx

The script refuses to write the model unless the converted Core ML output
agrees with onnxruntime on several random inputs (cosine > 0.999).
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

EXPECTED_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "Models" / "SFace.mlpackage"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def strip_initializer_inputs(model):
    """Old ONNX exports list constants (here the normalisation scalars) as
    graph inputs too. Drop them so the graph has a single real input."""
    init_names = {i.name for i in model.graph.initializer}
    real_inputs = [i for i in model.graph.input if i.name not in init_names]
    del model.graph.input[:]
    model.graph.input.extend(real_inputs)
    return model


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--onnx", required=True, help="path to face_recognition_sface_2021dec.onnx")
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT))
    args = ap.parse_args()

    onnx_path = Path(args.onnx).expanduser().resolve()
    if not onnx_path.is_file():
        die(f"not a file: {onnx_path}")
    digest = sha256(onnx_path)
    if digest != EXPECTED_SHA256:
        die(f"sha256 mismatch: got {digest}, expected {EXPECTED_SHA256}")

    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch
    import coremltools as ct
    from onnx2torch import convert
    from PIL import Image

    model = strip_initializer_inputs(onnx.load(str(onnx_path)))
    onnx.checker.check_model(model)
    if [i.name for i in model.graph.input] != ["data"]:
        die(f"unexpected graph inputs: {[i.name for i in model.graph.input]}")

    torch_model = convert(model).eval()
    example = torch.rand(1, 3, 112, 112) * 255.0
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 112, 112),
                             scale=1.0, bias=[0.0, 0.0, 0.0],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "SFace (MobileFaceNet, OpenCV Zoo, Apache-2.0) 128-d face embedding"
    mlmodel.license = "Apache-2.0 (OpenCV Zoo face_recognition_sface)"

    # Parity: ONNX (fp32) vs Core ML on random RGB images.
    sess = ort.InferenceSession(onnx_path.as_posix(), providers=["CPUExecutionProvider"])
    feed_name = sess.get_inputs()[0].name
    rng = np.random.default_rng(42)
    worst = 1.0
    for _ in range(5):
        px = rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)
        chw = px.astype(np.float32).transpose(2, 0, 1)[None]
        ref = sess.run(None, {feed_name: chw})[0].reshape(-1)
        out = np.asarray(mlmodel.predict({"image": Image.fromarray(px, "RGB")})["embedding"]).reshape(-1)
        if ref.shape != (128,) or out.shape != (128,):
            die(f"unexpected output shapes {ref.shape} / {out.shape}")
        cos = float(ref @ out / (np.linalg.norm(ref) * np.linalg.norm(out)))
        worst = min(worst, cos)
    print(f"ONNX vs Core ML worst cosine over 5 random inputs: {worst:.6f}")
    if worst < 0.999:
        die("parity check failed; not writing the model")

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(out_path.as_posix())
    print(f"saved {out_path}")


if __name__ == "__main__":
    main()
