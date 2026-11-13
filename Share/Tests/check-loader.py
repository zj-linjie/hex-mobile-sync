#!/usr/bin/env python3
"""Run ShareLoader provider regressions on macOS without installing an app.

Uses the real loader, TransferStaging and core models. Only UIKit's UIImage
encoding API is stubbed; native UIImage conversion and sheet visuals still
need iOS verification. Builds its own temporary copy of HexMobileCore.
"""
from pathlib import Path
import subprocess
import tempfile

share = Path(__file__).resolve().parents[1]
mobile = share.parent
loader = (share / 'Sources/ShareLoader.swift').read_text().replace(
    'import UIKit',
    '''// Native UIImage encoding is outside this macOS harness.
class UIImage {
    func pngData() -> Data? { nil }
    func jpegData(compressionQuality: Double) -> Data? { nil }
}''')
with tempfile.TemporaryDirectory(prefix='.loader-checks-', dir=share / 'Tests') as temporary:
    directory = Path(temporary)
    core_sources = sorted((mobile / 'Packages/HexMobileCore/Sources/HexMobileCore').glob('*.swift'))
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
        '-emit-library', '-emit-module', '-module-name', 'HexMobileCore',
        *map(str, core_sources), '-o', str(directory / 'libHexMobileCore.dylib'),
        '-emit-module-path', str(directory / 'HexMobileCore.swiftmodule'),
    ], check=True)
    adapted = directory / 'ShareLoader.swift'
    adapted.write_text(loader)
    executable = directory / 'share-loader-checks'
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
        '-strict-concurrency=complete', '-I', str(directory), '-L', str(directory), '-lHexMobileCore',
        '-Xlinker', '-rpath', '-Xlinker', str(directory),
        str(adapted), str(mobile / 'App/Sources/Transfers/TransferDraft.swift'),
        str(share / 'Tests/ShareLoaderChecks.swift'), '-o', str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
