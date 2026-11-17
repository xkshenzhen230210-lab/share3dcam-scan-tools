import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mac_release', ROOT/'tools/mac_release.py')
mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac)


class MacPackageTests(unittest.TestCase):
    def binary(self, path, kind=2, cpu=0x0100000C):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(struct.pack('<8I', 0xFEEDFACF, cpu, 0, kind, 0, 0, 0, 0))

    def test_rejects_missing_native_renderer_instead_of_shipping_broken_rbz(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'extension/share_pointcloud').mkdir(parents=True)
            with self.assertRaises(FileNotFoundError): mac.package(root, root/'out')

    def test_m_series_package_retains_bilingual_ui_excludes_windows_and_sets_execute(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); ext=root/'extension'; folder=ext/'share_pointcloud'
            folder.mkdir(parents=True)
            (ext/'share_pointcloud.rb').write_text("extension.version = '0.11.0-mac.1'", encoding='utf-8')
            (folder/'translations.js').write_text('中 English', encoding='utf-8')
            self.binary(folder/'bin/macos-arm64/share_cloud_engine')
            self.binary(folder/'bin/macos-arm64/libshare_cloud_resident.dylib', 6)
            self.binary(folder/'bin/unwanted.exe')
            result=mac.package(root, root/'out')
            with zipfile.ZipFile(result) as z:
                self.assertTrue(all('.exe' not in n and '.dll' not in n for n in z.namelist()))
                self.assertIn('中 English',z.read('share_pointcloud/translations.js').decode())
                entry=z.getinfo('share_pointcloud/bin/macos-arm64/share_cloud_engine')
                self.assertEqual((entry.external_attr >> 16) & 0o111, 0o111)
                info=json.loads(z.read('share_pointcloud/bin/macos-arm64/build.json'))
                self.assertEqual(info['architecture'],'arm64')
                self.assertFalse(info['sketchup_mac_acceptance_passed'])

    def test_rejects_intel_and_pe_binaries(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'binary';self.binary(p,cpu=0x01000007)
            with self.assertRaises(ValueError): mac.require_arm64(p,2)
            p.write_bytes(b'MZ'+b'\0'*100)
            with self.assertRaises(ValueError): mac.require_arm64(p,2)
