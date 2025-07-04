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
    while IFS=, read -r hash path orig imported_date; do
      path_to_hash["$path"]="$hash"
      hash_to_row["$hash"]="$hash,$path,$orig,$imported_date"
    done < <(tail -n +2 "$csvfile" | csvtool col 1,2,3,4 -)
  fi

  echo "sha1sum,absolute_path,original_filename,created_date,imported_date" > "$tmpfile"

  declare -A folder_import_date

  while IFS= read -r f; do
    hash=""
    orig=""
    if [[ -n "${path_to_hash[$f]}" ]]; then
      hash="${path_to_hash[$f]}"
      orig_field=$(echo "${hash_to_row[$hash]}" | awk -F, '{print $3}')
    else
      hash=$(sha1sum "$f" | awk '{print $1}')
      orig="${hash_to_orig[$hash]}"
    fi
    # Get file creation date
    created_date=$(stat -c '%W' "$f")
    if [[ "$created_date" == "0" ]]; then
      created_date=$(stat -c '%Y' "$f")
    fi
    created_date_fmt=$(date -d "@$created_date" '+%Y-%m-%d %H:%M:%S')
    # Get parent folder creation date as import date, with caching
    parent_dir=$(dirname "$f")
    if [[ -z "${folder_import_date[$parent_dir]}" ]]; then
      import_date=$(stat -c '%W' "$parent_dir")
      if [[ "$import_date" == "0" ]]; then
        import_date=$(stat -c '%Y' "$parent_dir")
      fi
      import_date_fmt=$(date -d "@$import_date" '+%Y-%m-%d %H:%M:%S')
      folder_import_date["$parent_dir"]="$import_date_fmt"
    fi
    import_date_fmt="${folder_import_date[$parent_dir]}"
    safe_f="${f//\"/\"\"}"
    echo "$hash,\"$safe_f\",${orig:-$orig_field},$created_date_fmt,$import_date_fmt" >> "$tmpfile"
  done < "$filelistfile"

  mv "$tmpfile" "$csvfile"
  rm -f "$filelistfile"
}

echo "Incrementally hashing $IMPORT_DIR and updating $CSV_FILE ..."
echo "Timestamp: $(date)"
incremental_hash_csv "$IMPORT_DIR" "$CSV_FILE" "$COPY_LOG"
echo "Done."
echo "Timestamp: $(date)"
