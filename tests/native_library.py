import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LIBRARY=ROOT/'extension/share_pointcloud/bin'/('macos-arm64/libshare_cloud_resident.dylib' if sys.platform=='darwin' else 'share_cloud_resident_097.dll')
