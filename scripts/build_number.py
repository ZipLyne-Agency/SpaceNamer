#!/usr/bin/env python3
"""Derive a deterministic, monotonically increasing CFBundleVersion."""

from __future__ import annotations

import re
import sys


def for_version(version: str) -> int:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if match is None:
        raise ValueError("version must be numeric MAJOR.MINOR.PATCH")
    major, minor, patch = (int(value) for value in match.groups())
    if minor > 999 or patch > 999:
        raise ValueError("minor and patch components must be at most 999")
    # The trailing 000001 leaves room for a future emergency rebuild policy
    # without changing the ordering of semantic versions.
    return major * 1_000_000_000_000 + minor * 1_000_000_000 + patch * 1_000_000 + 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} MAJOR.MINOR.PATCH")
    try:
        print(for_version(sys.argv[1]))
    except ValueError as error:
        raise SystemExit(str(error)) from error
