#!/bin/sh
# Build the universal (Intel + Apple silicon) binary and pack the npm package.
#   scripts/package-npm.sh            -> npm/opticensus-<version>.tgz
# The binary is the whole package: no install script, nothing downloaded.
set -eu
cd "$(dirname "$0")/.."

version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/OptiCensusCore/Product.swift)
packaged=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' npm/package.json)
[ "$version" = "$packaged" ] || { echo "Product.swift says $version, npm/package.json says $packaged" >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/opticensus
mkdir -p npm/bin
cp "$bin" npm/bin/opticensus
codesign --force --sign - npm/bin/opticensus      # ad-hoc: Apple silicon will not run an unsigned binary
cp README.md LICENSE npm/
lipo -info npm/bin/opticensus
npm/bin/opticensus version
(cd npm && npm pack --silent)
