#!/usr/bin/env python3
"""Install fixed aircraft weights for a local build, without overwriting an existing resource.

The application never calls this build helper. Uses only Python's standard library; a local
--source-file can reuse an already downloaded model. Photos and existing bird models are untouched.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlparse
from urllib.request import Request, urlopen


class InstallError(Exception):
    pass


def read_manifest(directory: Path) -> dict:
    meta = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    name, size, digest, revision = (meta.get(k) for k in ("file", "bytes", "sha256", "revision"))
    if (not isinstance(name, str) or Path(name).name != name or ".." in name or "\\" in name
            or not name.endswith(".onnx") or type(size) is not int or size <= 0
            or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision)):
        raise InstallError("飞机模型说明中的文件名、版本或校验信息无效。")
    address = urlparse(meta.get("url", ""))
    if (address.scheme != "https" or address.hostname != "huggingface.co" or address.query
            or address.username or address.password or address.fragment or address.port is not None
            or f"/resolve/{revision}/" not in address.path):
        raise InstallError("飞机模型必须使用说明文件中固定版本的公开HTTPS地址。")
    return meta


def verify(path: Path, meta: dict):
    if not path.is_file() or path.stat().st_size != meta["bytes"]:
        raise InstallError("已有飞机模型的大小不匹配，已保留该文件，未覆盖。")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024*1024), b""):
            digest.update(block)
    if digest.hexdigest() != meta["sha256"]:
        raise InstallError("已有飞机模型的校验值不匹配，已保留该文件，未覆盖。")


def install(directory: Path, source: Path | None = None, *, opener=urlopen) -> bool:
    meta = read_manifest(directory)
    destination = directory / meta["file"]
    if destination.exists() or destination.is_symlink():
        verify(destination, meta)
        return False
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".AircraftParts-", suffix=".part", delete=False) as output:
            temporary = Path(output.name)
            if source is not None:
                stream = source.open("rb")
            else:
                request = Request(meta["url"], headers={"User-Agent": "BirdLock-model-build/1"})
                stream = opener(request, timeout=30)
                if urlparse(stream.geturl()).scheme != "https":
                    stream.close()
                    raise InstallError("飞机模型下载没有保持HTTPS连接。")
            with stream:
                digest = hashlib.sha256()
                size = 0
                while True:
                    block = stream.read(1024*1024)
                    if not block:
                        break
                    size += len(block)
                    if size > meta["bytes"]:
                        raise InstallError("飞机模型超过预期大小，未安装。")
                    output.write(block)
                    digest.update(block)
                if size != meta["bytes"] or digest.hexdigest() != meta["sha256"]:
                    raise InstallError("飞机模型下载或复制校验失败，未安装。")
                output.flush()
                os.fsync(output.fileno())
        # Public weights must remain readable after a bundle is copied to another Mac account.
        os.chmod(temporary, 0o644)
        try:
            # Same-directory hard link publishes the complete file without a replacement race.
            os.link(temporary, destination)
        except FileExistsError:
            verify(destination, meta)
            return False
        except OSError as error:
            raise InstallError("当前目录不支持安全安装模型，请改用本机开发目录。") from error
        return True
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="为本地构建安装固定版本飞机模型；不覆盖已有资源。")
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parents[1] / "SharedResources/AircraftModels")
    parser.add_argument("--source-file", type=Path, help="复用已下载的模型，仍须通过完整校验")
    args = parser.parse_args()
    try:
        installed = install(args.directory, args.source_file)
    except KeyboardInterrupt:
        print("已取消模型安装。")
        return 130
    except InstallError as error:
        print(str(error))
        return 1
    except Exception as error:
        # Avoid logging redirected download credentials, temporary URLs or unrelated local paths.
        print(f"模型安装未完成（{type(error).__name__}）；已有资源保持原样。")
        return 1
    print("飞机模型已安装并校验。" if installed else "已有飞机模型校验通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
