#!/usr/bin/env python3
"""
directory_tree_to_md.py

Generate a Markdown file that represents the directory tree of a given folder.

Usage:
    python directory_tree_to_md.py <directory_path> [--output <output_file>]

Example:
    python directory_tree_to_md.py /path/to/my_project
    python directory_tree_to_md.py /path/to/my_project -o custom_tree.md
"""

import argparse
from pathlib import Path
import sys


def parse_args() -> argparse.Namespace:
    """
    Parse command-line arguments.

    Returns:
        argparse.Namespace: Parsed arguments including 'directory' and optional 'output'.
    """
    parser = argparse.ArgumentParser(
        description="Generate a Markdown tree of a directory structure"
    )
    parser.add_argument(
        "directory",
        type=Path,
        help="Path to the directory to analyze",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output Markdown file path (defaults to <directory_name>_tree.md)",
    )
    return parser.parse_args()


def generate_tree(path: Path, prefix: str = "") -> list[str]:
    """
    Recursively generate lines for the directory tree in Markdown format.

    Args:
        path (Path): Directory path to traverse.
        prefix (str): Indentation prefix for nested items.

    Returns:
        list[str]: Lines representing the tree structure.
    """
    lines: list[str] = []
    entries = sorted(path.iterdir(), key=lambda p: (p.is_file(), p.name.lower()))

    for entry in entries:
        if entry.is_dir():
            lines.append(f"{prefix}- **{entry.name}/**")
            lines.extend(generate_tree(entry, prefix + "  "))
        else:
            lines.append(f"{prefix}- {entry.name}")
    return lines


def main() -> None:
    """
    Main entry point: validates input, determines output filename, generates tree,
    and writes to a Markdown file.
    """
    args = parse_args()
    root = args.directory

    if not root.exists():
        print(f"Error: Directory '{root}' not found.", file=sys.stderr)
        sys.exit(1)
    if not root.is_dir():
        print(f"Error: '{root}' is not a directory.", file=sys.stderr)
        sys.exit(1)

    # Determine output file path dynamically if not provided
    if args.output:
        output_path = args.output
    else:
        default_name = f"{root.name}_tree.md"
        output_path = Path(default_name)

    # Build Markdown content
    header = f"# Directory Tree for {root.resolve()}\n"
    tree_lines = generate_tree(root)
    content = header + "\n".join(tree_lines) + "\n"

    # Write to the output file
    try:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"Markdown file written to '{output_path}'")
    except Exception as e:
        print(f"Error writing file '{output_path}': {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
