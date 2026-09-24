"""Build non-bootable UDF provisioning media from a private staging directory."""

import argparse
import io
import json
import os
from pathlib import Path
import stat
import tempfile

import pycdlib


def build(source: Path, output: Path, label: str) -> dict:
    root_attributes = source.lstat()
    if source.is_symlink() or getattr(root_attributes, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
        raise ValueError("source cannot be a link")
    source = source.resolve(strict=True)
    if not source.is_dir() or output.exists():
        raise ValueError("source must be a directory and output must not exist")
    if not label or len(label) > 32 or not all(c.isascii() and (c.isalnum() or c == "_") for c in label):
        raise ValueError("invalid media label")
    entries = sorted(source.rglob("*"), key=lambda path: (len(path.parts), str(path)))
    if len(entries) > 20000:
        raise ValueError("too many provisioning files")
    total = 0
    for path in entries:
        attributes = path.lstat()
        if path.is_symlink() or getattr(attributes, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
            raise ValueError("links/reparse points are not allowed in provisioning media")
        if not path.is_dir() and not path.is_file():
            raise ValueError("unsupported file type")
        if path.is_file():
            total += attributes.st_size
    if total > 4 * 1024**3:
        raise ValueError("provisioning media exceeds 4 GiB")
    if output.resolve().is_relative_to(source):
        raise ValueError("output cannot be inside the source tree")

    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, udf="2.60", vol_ident=label)
    aliases = {Path("."): ""}
    file_count = 0
    temporary = None
    iso_open = True
    try:
        for index, path in enumerate(entries, 1):
            relative = path.relative_to(source)
            parent = aliases[relative.parent]
            udf_path = "/" + relative.as_posix()
            if path.is_dir():
                alias = parent + f"/D{index:07d}"
                iso.add_directory(iso_path=alias, udf_path=udf_path)
                aliases[relative] = alias
            else:
                alias = parent + f"/F{index:07d}.BIN;1"
                iso.add_file(str(path), iso_path=alias, udf_path=udf_path)
                file_count += 1
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".limiar-iso-", delete=False) as stream:
            temporary = Path(stream.name)
            iso.write_fp(stream)
        iso.close()
        iso_open = False
        # Verify before publication. A failed build must not leave a reusable partial ISO.
        if (source / "Autounattend.xml").is_file():
            check = pycdlib.PyCdlib()
            try:
                check.open(str(temporary))
                extracted = io.BytesIO()
                check.get_file_from_iso_fp(extracted, udf_path="/Autounattend.xml")
                if extracted.getvalue() != (source / "Autounattend.xml").read_bytes():
                    raise ValueError("unattend media round-trip failed")
            finally:
                check.close()
        os.link(temporary, output)
    finally:
        if iso_open:
            iso.close()
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {"files": file_count, "input_bytes": total, "output_bytes": output.stat().st_size}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--label", default="LIMIAR_AUTO")
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.output, args.label)))
