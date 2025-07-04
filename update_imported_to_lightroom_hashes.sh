#!/bin/bash
# update_imported_to_lightroom_hashes.sh
# Incrementally hash all files in /mnt/i/imported_to_lightroom and generate a CSV with hash, path, original filename, and imported date.

set -e

IMPORT_DIR="/mnt/i/imported_to_lightroom"
CSV_FILE="imported_to_lightroom_hashes.csv"
COPY_LOG="copied_device_files.log"

# Incremental hashing function for CSV-only workflow
incremental_hash_csv() {
  local folder="$1"
  local csvfile="$2"
  local copylog="$3"
  local tmpfile="${csvfile}.tmp"
  local filelistfile="${csvfile}.filelist"

  # Build a map of hash -> original filename from the copy log
  declare -A hash_to_orig
  if [ -f "$copylog" ]; then
    while IFS='|' read -r orig_path mtime; do
      if [ -f "$orig_path" ]; then
        hash=$(sha1sum "$orig_path" | awk '{print $1}')
        hash_to_orig["$hash"]=$(basename "$orig_path")
      fi
    done < "$copylog"
  fi

  # Get all files in folder
  find "$folder" -type f | sort > "$filelistfile"

  # Read existing CSV into a map for incremental update
  declare -A path_to_hash
  declare -A hash_to_row
  if [ -f "$csvfile" ]; then
    tail -n +2 "$csvfile" | while IFS=, read -r hash path orig imported_date; do
      # Remove quotes from path
      path=${path%"}
      path=${path#"}
      path_to_hash["$path"]="$hash"
      hash_to_row["$hash"]="$hash,$path,$orig,$imported_date"
    done
  fi

  echo "sha1sum,absolute_path,original_filename,imported_date" > "$tmpfile"

  while IFS= read -r f; do
    # If file already in CSV and unchanged, reuse row
    if [[ -n "${path_to_hash[$f]}" ]]; then
      hash="${path_to_hash[$f]}"
      echo "${hash_to_row[$hash]}" >> "$tmpfile"
      continue
    fi
    hash=$(sha1sum "$f" | awk '{print $1}')
    orig="${hash_to_orig[$hash]}"
    imported_date=""
    if [[ "$f" =~ Imported\ on\ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
      imported_date="${BASH_REMATCH[1]}"
    fi
    echo "$hash,\"$f\",${orig:-unknown},$imported_date" >> "$tmpfile"
  done < "$filelistfile"

  mv "$tmpfile" "$csvfile"
  rm -f "$filelistfile"
}

echo "Incrementally hashing $IMPORT_DIR and updating $CSV_FILE ..."
incremental_hash_csv "$IMPORT_DIR" "$CSV_FILE" "$COPY_LOG"
echo "Done."