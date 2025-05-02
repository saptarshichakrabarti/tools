#!/usr/bin/env python3
"""
scanner.py
Scan a directory recursively and emit metadata as JSON.

Usage:
  scanner.py [OPTIONS] ROOT_DIR

Options:
  -i, --include-hidden    Include hidden files and directories (those starting with '.').
  -o, --output FILE       Path to output JSON file (default: <ROOT_DIR_NAME>.json).
  -v, --verbose           Enable debug logging.

Examples:
  # Scan current directory, output to "tools.json":
  scanner.py .

  # Scan /var/log including hidden items, output to custom file:
  scanner.py -i -o logs_scan.json /var/log

  # Verbose scan of ~/projects, default output: "projects.json":
  scanner.py -v ~/projects
"""

import argparse
import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path
from stat import S_ISDIR, S_ISLNK, S_ISREG, filemode
from typing import Any, Dict, List, Optional

# Version of the output schema
SCANNER_OUTPUT_VERSION = "1.0"


def format_timestamp(epoch: Optional[float]) -> Optional[str]:
    """
    Convert a UNIX timestamp to an ISO 8601 UTC string (with 'Z' suffix).

    Args:
        epoch: Seconds since the epoch, or None.

    Returns:
        ISO 8601 UTC string, or None if input is None or invalid.
    """
    if epoch is None:
        return None
    try:
        dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
        return dt.isoformat(timespec="seconds").replace("+00:00", "Z")
    except (OSError, ValueError, OverflowError):
        logging.debug("Invalid timestamp %s", epoch)
        return None


def get_file_metadata(path: Path, root: Path) -> Optional[Dict[str, Any]]:
    """
    Gather metadata for a filesystem item: file, folder, or symlink.

    Uses lstat() so that symlink metadata is reported instead of target metadata.

    Args:
        path: Path to the filesystem item.
        root: Root path of the scan for computing relative paths.

    Returns:
        A dictionary of metadata fields, or None on error.
    """
    try:
        st = path.lstat()
    except OSError as err:
        logging.warning("Cannot lstat %s: %s", path, err)
        return None

    mode = st.st_mode
    if S_ISDIR(mode):
        kind = "folder"
    elif S_ISREG(mode):
        kind = "file"
    elif S_ISLNK(mode):
        kind = "symlink"
    else:
        kind = "unknown"

    try:
        rel = path.relative_to(root)
        rel_path = rel.as_posix() or "."
    except ValueError:
        rel_path = path.as_posix()
        logging.debug("Using absolute path for %s", path)

    data: Dict[str, Any] = {
        "path": rel_path,
        "type": kind,
        "permissions": filemode(mode),
        "modified_utc": format_timestamp(st.st_mtime),
        "accessed_utc": format_timestamp(st.st_atime),
        "metadata_changed_utc": format_timestamp(st.st_ctime),
    }

    # Include creation time if available (e.g., macOS st_birthtime)
    if hasattr(st, "st_birthtime"):
        data["created_utc"] = format_timestamp(getattr(st, "st_birthtime"))

    if kind == "file":
        data["size_bytes"] = st.st_size
        ext = path.suffix.lstrip(".").lower()
        data["extension"] = ext or None
    elif kind == "symlink":
        try:
            data["symlink_target"] = str(path.readlink())
        except OSError as err:
            logging.warning("Cannot read symlink target for %s: %s", path, err)
            data["symlink_target"] = None

    return data


def scan_directory(root: Path, include_hidden: bool = False) -> List[Dict[str, Any]]:
    """
    Recursively scan a directory and collect metadata for each item.

    Args:
        root: Root directory Path to scan (must exist).
        include_hidden: Whether to include hidden entries (prefix '.').

    Returns:
        List of metadata dictionaries for each scanned item, including the root as '.'.
    """
    items: List[Dict[str, Any]] = []

    # Include root metadata first
    root_meta = get_file_metadata(root, root)
    if root_meta is None:
        logging.error("Cannot access root directory: %s", root)
        sys.exit(1)
    root_meta["path"] = "."
    items.append(root_meta)

    # Walk tree
    for path in root.rglob("*"):
        if not include_hidden and any(
            part.startswith(".") for part in path.relative_to(root).parts
        ):
            continue
        meta = get_file_metadata(path, root)
        if meta:
            items.append(meta)

    return items


def main() -> None:
    """
    Parse arguments, perform directory scan, and write JSON output.
    """
    parser = argparse.ArgumentParser(
        description="Scan directory structure and output metadata as JSON."
    )
    parser.add_argument(
        "root_dir", type=Path, help="Directory to scan (absolute or relative)."
    )
    parser.add_argument(
        "-i",
        "--include-hidden",
        action="store_true",
        help="Include hidden files and directories (prefix '.').",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output JSON file path (default: <ROOT_DIR_NAME>.json).",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable debug logging."
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    root = args.root_dir.resolve()
    if not root.is_dir():
        if root.is_symlink() and root.resolve().is_dir():
            logging.warning("Root is a symlink to a directory: %s", root)
        else:
            logging.error("Not a directory or symlink: %s", root)
            sys.exit(1)

    default_name = f"{root.name}.json"
    output_path = args.output if args.output else root.parent / default_name

    logging.info("Scanning %s (include_hidden=%s)", root, args.include_hidden)
    results = scan_directory(root, include_hidden=args.include_hidden)

    output = {
        "scanner_version": SCANNER_OUTPUT_VERSION,
        "scanned_path": str(root),
        "timestamp_utc": datetime.now(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "items": results,
    }

    try:
        with output_path.open("w", encoding="utf-8") as f:
            json.dump(output, f, indent=2, sort_keys=True)
        logging.info("Wrote output to %s", output_path)
    except OSError as err:
        logging.error("Failed to write output file %s: %s", output_path, err)
        sys.exit(1)


if __name__ == "__main__":
    main()
