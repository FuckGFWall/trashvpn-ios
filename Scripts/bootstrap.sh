#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Downloads Vendor
if [[ ! -d Vendor/Clash.xcframework ]]; then
  curl --fail --location --retry 3 \
    https://github.com/ProjectClash/Clash/releases/download/v1.19.33-clash.4/Clash.xcframework.zip \
    -o Downloads/Clash.xcframework.zip
  echo '914516ee009606cf4b3fec411b5f269a2b49c49677209cb172bfefaf20188a76  Downloads/Clash.xcframework.zip' | shasum -a 256 -c -
  ditto -xk Downloads/Clash.xcframework.zip Vendor
fi
mkdir -p App/Licenses
cp LICENSE Vendor/NOTICE Vendor/THIRD_PARTY_LICENSES.md App/Licenses/
cp -R Vendor/THIRD_PARTY_LICENSES App/Licenses/
if ! command -v xcodegen >/dev/null; then
  echo '请先安装 XcodeGen：brew install xcodegen' >&2
  exit 1
fi
xcodegen generate
