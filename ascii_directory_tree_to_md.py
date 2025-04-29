#!/usr/bin/env python3
"""
ascii_directory_tree_to_md.py

Generate an ASCII-style directory tree and output it as a Markdown file.

Usage:
    python ascii_directory_tree_to_md.py <directory_path> [--output <output_file>]

Example:
    python ascii_directory_tree_to_md.py /path/to/my_project
    python ascii_directory_tree_to_md.py /path/to/my_project -o custom_tree.md
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
        description="Generate an ASCII-style directory tree in Markdown format"
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


def generate_tree(path: Path, prefix: str = "", is_last: bool = True) -> list[str]:
    """
    Recursively generate lines for the directory tree using ASCII connectors.

    Args:
        path (Path): Directory or file path to represent.
        prefix (str): String prefix for the current line (indentation and connectors).
        is_last (bool): Whether this entry is the last in its parent's list.

    Returns:
        list[str]: Lines representing the ASCII tree.
    """
    lines: list[str] = []
    connector = "└── " if is_last else "├── "
    name = f"{path.name}/" if path.is_dir() else path.name
    lines.append(f"{prefix}{connector}{name}")

    if path.is_dir():
        entries = sorted(path.iterdir(), key=lambda p: (p.is_file(), p.name.lower()))
        for index, entry in enumerate(entries):
            last_entry = index == len(entries) - 1
            child_prefix = prefix + ("    " if is_last else "│   ")
            lines.extend(generate_tree(entry, child_prefix, last_entry))
    return lines


def main() -> None:
    """
    Main entry point: validates input, determines output filename, builds the tree,
    and writes to a Markdown file.
    """
    args = parse_args()
    root = args.directory

    # Validate input path
    if not root.exists():
        print(f"Error: Directory '{root}' not found.", file=sys.stderr)
        sys.exit(1)
    if not root.is_dir():
        print(f"Error: '{root}' is not a directory.", file=sys.stderr)
        sys.exit(1)

    # Determine output file path
    if args.output:
        output_path = args.output
    else:
        default_name = f"{root.name}_tree.md"
        output_path = Path(default_name)

    # Header uses the root directory name to label the tree
    header = f"[{root.name}]/"
    entries = sorted(root.iterdir(), key=lambda p: (p.is_file(), p.name.lower()))
    tree_lines: list[str] = []
    for idx, entry in enumerate(entries):
        last = idx == len(entries) - 1
        tree_lines.extend(generate_tree(entry, "", last))

    # Wrap ASCII tree in Markdown code fences
    fence = "```"
    content_lines = [fence, header] + tree_lines + [fence]
    content = "\n".join(content_lines) + "\n"

    # Write to the output Markdown file
    try:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"Markdown file written to '{output_path}'")
    except Exception as e:
        print(f"Error writing file '{output_path}': {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
