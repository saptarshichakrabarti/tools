#!/usr/bin/env python3
"""
Script to recursively find and delete __pycache__ folders.

This script scans a specified directory (and its subdirectories) for any
folders named "__pycache__" and removes them. It includes a dry-run
option to see what would be deleted without making any changes.

Usage:
  python3 clean_pycache.py [DIRECTORY_PATH] [-d | --dry-run]

Arguments:
  DIRECTORY_PATH (optional): The path to the root directory to scan.
                             If not provided, defaults to the current
                             working directory ('.').

Options:
  -h, --help          Show this help message and exit.
  -d, --dry-run       Perform a dry run: show what would be deleted
                      without actually deleting anything.

Examples:
  1. Clean __pycache__ folders in the current directory:
     python3 clean_pycache.py

  2. Clean __pycache__ folders in a specific project directory:
     python3 clean_pycache.py /path/to/my/project

  3. Perform a dry run to see what would be cleaned in the current directory:
     python3 clean_pycache.py --dry-run

  4. Perform a dry run for a specific project directory:
     python3 clean_pycache.py /path/to/your/project -d

If the script is made executable (e.g., `chmod +x clean_pycache.py` on Linux/macOS):
  ./clean_pycache.py
  ./clean_pycache.py /path/to/my/project
  ./clean_pycache.py --dry-run
"""

import argparse
import shutil
from pathlib import Path


def clean_pycache(directory_path_str: str, dry_run: bool = False) -> int:
    """
    Recursively finds and deletes __pycache__ folders within the given directory.

    Args:
        directory_path_str (str): The path to the root directory to scan.
                                  This can be a relative or absolute path.
        dry_run (bool): If True, only prints what would be deleted without
                        actually deleting anything. Defaults to False.

    Returns:
        int: The number of __pycache__ folders found (and deleted if not dry_run).
             If dry_run is True, this is the number of folders that *would* be
             deleted.
    """
    root_dir = Path(directory_path_str).resolve()  # Get absolute path

    if not root_dir.is_dir():
        print(f"Error: '{root_dir}' is not a valid directory.")
        return 0

    print(f"Scanning '{root_dir}' for __pycache__ folders...")
    if dry_run:
        print("--- DRY RUN MODE: No files will be deleted. ---")

    pycache_folders_found = 0
    pycache_folders_deleted = 0

    # Use rglob to recursively find all directories named '__pycache__'
    for pycache_dir in root_dir.rglob("__pycache__"):
        # Ensure it's actually a directory and its name is exactly __pycache__
        if pycache_dir.is_dir() and pycache_dir.name == "__pycache__":
            pycache_folders_found += 1
            if dry_run:
                print(f"[DRY RUN] Would delete: {pycache_dir}")
            else:
                print(f"Deleting: {pycache_dir}")
                try:
                    shutil.rmtree(pycache_dir)
                    pycache_folders_deleted += 1
                except OSError as e:
                    print(f"Error deleting {pycache_dir}: {e}")
                    print("  Skipping this folder.")

    if dry_run:
        if pycache_folders_found > 0:
            print(
                f"\n[DRY RUN] Found {pycache_folders_found} __pycache__ folder(s) that would be deleted."
            )
        else:
            print(f"\n[DRY RUN] No __pycache__ folders found in '{root_dir}'.")
        return pycache_folders_found
    else:
        if pycache_folders_deleted > 0:
            print(
                f"\nSuccessfully deleted {pycache_folders_deleted} __pycache__ folder(s)."
            )
        elif pycache_folders_found > 0 and pycache_folders_deleted == 0:
            print(
                f"\nFound {pycache_folders_found} __pycache__ folder(s) but could not delete any (check permissions)."
            )
        else:
            print(f"\nNo __pycache__ folders found to delete in '{root_dir}'.")
        return pycache_folders_deleted


if __name__ == "__main__":
    # The main script docstring (at the top) serves as the primary usage guide.
    # argparse will use its description if provided, and also generates help text.
    parser = argparse.ArgumentParser(
        description="Recursively clean __pycache__ folders from a specified directory.",
        formatter_class=argparse.RawDescriptionHelpFormatter,  # To preserve formatting of epilog/description
        epilog=__doc__,  # Use the module's docstring for detailed help
    )
    parser.add_argument(
        "directory",
        type=str,
        help="The root directory to scan and clean. Defaults to the current directory.",
        nargs="?",
        default=".",
    )
    parser.add_argument(
        "-d",
        "--dry-run",
        action="store_true",
        help="Perform a dry run: show what would be deleted without actually deleting anything.",
    )

    args = parser.parse_args()

    cleaned_count = clean_pycache(args.directory, args.dry_run)

    if args.dry_run:
        print(f"Dry run complete. {cleaned_count} __pycache__ folder(s) identified.")
    else:
        print(f"Cleaning complete. {cleaned_count} __pycache__ folder(s) removed.")
