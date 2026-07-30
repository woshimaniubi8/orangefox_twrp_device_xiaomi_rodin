#!/usr/bin/env python3
"""Build a rodin vendor-boot DTB without Android USB offload coupling."""

import argparse
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile


MTK_DTB_MAGIC = b"\xd7\xb7\xab\x1e"
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
XHCI_NODE = "/soc/usb0@11201000/xhci0@11200000"
USB_OFFLOAD_PROPERTY = "mediatek,usb-offload"
WRAPPER_SIZE_OFFSET = 4
INNER_DTB_SIZE_OFFSET = 32
INNER_DTB_OFFSET_OFFSET = 36


def read_be32(data: bytes, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def patch_dtb(input_path: pathlib.Path, output_path: pathlib.Path) -> None:
    fdtget = shutil.which("fdtget")
    fdtput = shutil.which("fdtput")
    if not fdtget or not fdtput:
        raise RuntimeError("fdtget and fdtput from device-tree-compiler are required")

    stock = input_path.read_bytes()
    if len(stock) < 64 or stock[:4] != MTK_DTB_MAGIC:
        raise RuntimeError("unexpected MediaTek DTB wrapper")

    wrapper_size = read_be32(stock, WRAPPER_SIZE_OFFSET)
    inner_size = read_be32(stock, INNER_DTB_SIZE_OFFSET)
    inner_offset = read_be32(stock, INNER_DTB_OFFSET_OFFSET)
    if wrapper_size != len(stock) or inner_offset < 64 or inner_offset + inner_size > len(stock):
        raise RuntimeError("invalid MediaTek DTB wrapper sizes")

    trailing_data = stock[inner_offset + inner_size :]
    inner_dtb = stock[inner_offset : inner_offset + inner_size]
    if inner_dtb[:4] != FDT_MAGIC:
        raise RuntimeError("MediaTek wrapper does not contain an FDT at its declared offset")

    with tempfile.TemporaryDirectory(prefix="rodin-dtb-") as temporary_directory:
        inner_path = pathlib.Path(temporary_directory) / "inner.dtb"
        inner_path.write_bytes(inner_dtb)

        present = subprocess.run(
            [fdtget, "-t", "x", str(inner_path), XHCI_NODE, USB_OFFLOAD_PROPERTY],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if present.returncode != 0:
            raise RuntimeError("stock DTB lacks the expected xHCI USB-offload property")

        subprocess.run(
            [fdtput, "-d", str(inner_path), XHCI_NODE, USB_OFFLOAD_PROPERTY],
            check=True,
        )
        removed = subprocess.run(
            [fdtget, "-t", "x", str(inner_path), XHCI_NODE, USB_OFFLOAD_PROPERTY],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if removed.returncode == 0:
            raise RuntimeError("failed to remove the xHCI USB-offload property")

        compatible = subprocess.run(
            [fdtget, "-t", "s", str(inner_path), XHCI_NODE, "compatible"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
        if compatible.stdout.strip() != "mediatek,mtk-xhci":
            raise RuntimeError("xHCI compatible value changed while patching DTB")
        patched_inner = inner_path.read_bytes()

    wrapper = bytearray(stock[:inner_offset])
    final_size = inner_offset + len(patched_inner) + len(trailing_data)
    struct.pack_into(">I", wrapper, WRAPPER_SIZE_OFFSET, final_size)
    struct.pack_into(">I", wrapper, INNER_DTB_SIZE_OFFSET, len(patched_inner))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(wrapper + patched_inner + trailing_data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()

    try:
        patch_dtb(arguments.input, arguments.output)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"DTB patch failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
