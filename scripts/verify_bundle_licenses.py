#!/usr/bin/env python3
"""Verify that the app carries the source snapshot's complete license notices."""
from __future__ import annotations

from pathlib import Path
import sys


def verify_bundle_licenses(app: Path, source_root: Path | None = None) -> int:
    source_root = source_root or Path(__file__).resolve().parents[1]
    notices = source_root / "ThirdPartyNotices"
    resources = app / "Contents/Resources"
    bundled_notices = resources / "ThirdPartyNotices"
    if notices.is_symlink() or not notices.is_dir():
        raise ValueError("Diretório de licenças da fonte ausente ou inválido")
    notice_files = sorted(notices.iterdir())
    if not notice_files:
        raise ValueError("Diretório de licenças da fonte vazio")
    if bundled_notices.is_symlink() or not bundled_notices.is_dir():
        raise ValueError("Diretório de licenças ausente ou inválido no app")
    if {path.name for path in bundled_notices.iterdir()} != {path.name for path in notice_files}:
        raise ValueError("Conjunto de avisos do app difere da fonte")
    relative_paths = [Path("LICENSE"), Path("THIRD_PARTY_NOTICES.md")]
    relative_paths += [path.relative_to(source_root) for path in notice_files]
    for relative in relative_paths:
        source = source_root / relative
        bundled = resources / relative
        if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
            raise ValueError(f"Licença da fonte ausente, vazia ou inválida: {relative}")
        if bundled.is_symlink() or not bundled.is_file():
            raise ValueError(f"Licença ausente ou inválida no app: {relative}")
        if bundled.read_bytes() != source.read_bytes():
            raise ValueError(f"Licença do app difere da fonte: {relative}")
    return len(relative_paths)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Uso: verify_bundle_licenses.py APP")
        count = verify_bundle_licenses(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        sys.exit(f"Verificação de licenças bloqueada: {error}")
    print(f"{count} arquivos de licença e avisos conferidos byte a byte no app.")
