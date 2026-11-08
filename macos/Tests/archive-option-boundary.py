#!/usr/bin/env python3
"""Regression: option-looking filenames stay filenames in ZIP and TAR."""
from pathlib import Path
import subprocess
import tempfile
import zipfile


with tempfile.TemporaryDirectory(prefix="bao-archive-options-") as directory:
    root = Path(directory)
    marker = "marker-should-not-exist"
    zip_names = ["--test", f"--unzip-command=touch {marker}", "ordinary.txt"]
    for name in zip_names:
        (root / name).write_text("safe regression fixture", encoding="utf-8")
    zip_path = root / "safe.zip"
    subprocess.run(
        ["/usr/bin/zip", "-qry", str(zip_path), "--", *zip_names],
        cwd=root,
        check=True,
    )
    with zipfile.ZipFile(zip_path) as archive:
        assert set(archive.namelist()) == set(zip_names)

    tar_names = [
        "--checkpoint=1",
        f"--checkpoint-action=exec=touch {marker}",
        "ordinary.tar.txt",
    ]
    for name in tar_names:
        (root / name).write_text("safe regression fixture", encoding="utf-8")
    tar_path = root / "safe.tar.gz"
    subprocess.run(
        ["/usr/bin/tar", "-czf", str(tar_path), "--", *tar_names],
        cwd=root,
        check=True,
    )
    listing = subprocess.run(
        ["/usr/bin/tar", "-tzf", str(tar_path)],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    assert set(listing) == set(tar_names)
    assert not (root / marker).exists()

print("archive option-boundary regression passed")
