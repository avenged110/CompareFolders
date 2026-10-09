#!/bin/sh
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
swiftc -O -swift-version 6 -strict-memory-safety -target arm64-apple-macos15.6 \
    -o "$OUT/verify" \
    CompareFolders/Core/*.swift \
    CompareFolders/Model/*.swift \
    CompareFolders/Support/OpenPanelPresenter.swift \
    Verification/main.swift
"$OUT/verify"
