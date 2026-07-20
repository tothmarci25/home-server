#!/usr/bin/env bash
#
# hardlink-mkv.sh — Hard link every .mkv file found under a source directory
# (recursively, through nested folders) into a single destination directory.
#
# Hard links share the same inode as the original, so they consume no extra
# disk space and must live on the same filesystem as the source files.
#
# Usage:
#   ./hardlink-mkv.sh [-f] [-n] <source-dir> <dest-dir>
#
#   -f   Force: overwrite existing files in the destination.
#   -n   Dry run: print what would be done without linking anything.
#
# Examples:
#   ./hardlink-mkv.sh /mnt/media/tv /mnt/media/all-mkv
#   ./hardlink-mkv.sh -n /mnt/downloads /mnt/plex/movies

set -euo pipefail

force=0
dry_run=0

usage() {
	echo "Usage: $0 [-f] [-n] <source-dir> <dest-dir>" >&2
	echo "  -f   Force overwrite existing destination files" >&2
	echo "  -n   Dry run (no changes made)" >&2
	exit 1
}

while getopts ":fn" opt; do
	case "$opt" in
		f) force=1 ;;
		n) dry_run=1 ;;
		*) usage ;;
	esac
done
shift $((OPTIND - 1))

[ "$#" -eq 2 ] || usage

src=$1
dest=$2

if [ ! -d "$src" ]; then
	echo "Error: source directory '$src' does not exist." >&2
	exit 1
fi

# Return the numeric device ID of a path, using GNU stat (Linux) with a
# BSD/macOS fallback so the check works wherever the script is run.
device_id() {
	stat -c '%d' "$1" 2>/dev/null || stat -f '%d' "$1"
}

# Warn early if source and dest are on different filesystems — hard links
# cannot cross filesystem boundaries.
if [ -d "$dest" ]; then
	src_dev=$(device_id "$src")
	dest_dev=$(device_id "$dest")
	if [ "$src_dev" != "$dest_dev" ]; then
		echo "Error: source and destination are on different filesystems;" >&2
		echo "       hard links cannot span filesystems." >&2
		exit 1
	fi
fi

if [ "$dry_run" -eq 0 ]; then
	mkdir -p "$dest"
fi

linked=0
skipped=0

# -print0 / read -d '' handles spaces and unusual characters in filenames.
while IFS= read -r -d '' file; do
	base=$(basename "$file")
	target="$dest/$base"

	if [ -e "$target" ] && [ "$force" -eq 0 ]; then
		echo "SKIP  (exists): $target"
		skipped=$((skipped + 1))
		continue
	fi

	if [ "$dry_run" -eq 1 ]; then
		echo "DRYRUN: '$file' -> '$target'"
		linked=$((linked + 1))
		continue
	fi

	# ln -f removes an existing target first; harmless when it does not exist.
	if ln -f "$file" "$target"; then
		echo "LINK: '$file' -> '$target'"
		linked=$((linked + 1))
	else
		echo "FAIL: could not link '$file'" >&2
		skipped=$((skipped + 1))
	fi
done < <(find "$src" -type f -iname '*.mkv' -print0)

echo "----"
if [ "$dry_run" -eq 1 ]; then
	echo "Dry run complete: $linked would be linked, $skipped skipped."
else
	echo "Done: $linked linked, $skipped skipped."
fi
