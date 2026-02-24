#!/bin/bash
# update_imported_to_lightroom_hashes.sh
# Fast, truly incremental hashing for Lightroom import folder.
# CSV columns: sha1sum,absolute_path,original_filename,created_date,import_date,mtime,size

set -e

# Source config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file $CONFIG_FILE not found!"
  exit 1
fi
source "$CONFIG_FILE"

IMPORT_DIR="$IMPORTED_TO_LR"
CSV_FILE="$LIGHTROOM_HASH_CSV"
DEVICE_HASHES="$DEVICE_HASH_LOG"

start_time=$(date +%s)
echo "[INFO] Start: $(date)"

# Build hash -> original filename map from device_copied_hashes.txt
# (hash, path)
declare -A hash_to_orig
if [ -f "$DEVICE_HASHES" ]; then
  while read -r hash path; do
    hash_to_orig["$hash"]="$(basename "$path")"
  done < "$DEVICE_HASHES"
fi

# Build path+mtime+size -> hash map from existing CSV
# (path, mtime, size, hash, orig, created_date, import_date)
declare -A filekey_to_row
if [ -f "$CSV_FILE" ]; then
  {
    read # skip header
    while IFS=, read -r hash path orig created_date import_date mtime size; do
      path_unquoted=$(echo "$path" | sed 's/^"\(.*\)"$/\1/')
      filekey="${path_unquoted}|${mtime}|${size}"
      filekey_to_row["$filekey"]="$hash,$path,$orig,$created_date,$import_date,$mtime,$size"
    done
  } < "$CSV_FILE"
fi

mid_time=$(date +%s)
echo "[INFO] Finished loading CSV and device hashes: $(date) (Elapsed: $((mid_time-start_time))s)"

# Prepare output
TMP_CSV="${CSV_FILE}.tmp"
echo "sha1sum,absolute_path,original_filename,created_date,import_date,mtime,size" > "$TMP_CSV"

# Cache for parent folder import date
declare -A folder_import_date

count=0
skipped=0
hashed=0

trap 'echo "[ERROR] at line $LINENO: $BASH_COMMAND"' ERR

# Use the original approach but with better error handling
find "$IMPORT_DIR" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
  count=$((count + 1))
  mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo "0")
  size=$(stat -c '%s' "$f" 2>/dev/null || echo "0")
  filekey="$f|$mtime|$size"
  hash=""
  orig=""
  created_date=$(stat -c '%W' "$f" 2>/dev/null || echo "0")
  [ "$created_date" = "0" ] && created_date=$(stat -c '%Y' "$f" 2>/dev/null || echo "0")
  created_date_fmt=$(date -d "@$created_date" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "1970-01-01 00:00:00")
  parent_dir=$(dirname "$f")
  if [[ -z "${folder_import_date[$parent_dir]}" ]]; then
    import_date=$(stat -c '%W' "$parent_dir" 2>/dev/null || echo "0")
    [ "$import_date" = "0" ] && import_date=$(stat -c '%Y' "$parent_dir" 2>/dev/null || echo "0")
    import_date_fmt=$(date -d "@$import_date" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "1970-01-01 00:00:00")
    folder_import_date["$parent_dir"]="$import_date_fmt"
  fi
  import_date_fmt="${folder_import_date[$parent_dir]}"
  # Check if we can reuse hash
  if [[ -n "${filekey_to_row[$filekey]}" ]]; then
    row="${filekey_to_row[$filekey]}"
    echo "$row" >> "$TMP_CSV"
    skipped=$((skipped + 1))
    continue
  fi
  hash=$(sha1sum "$f" 2>/dev/null | awk '{print $1}' || echo "")
  if [[ -n "$hash" ]]; then
    orig="${hash_to_orig[$hash]}"
    safe_f="${f//\"/\"\"}"
    echo "$hash,\"$safe_f\",$orig,$created_date_fmt,$import_date_fmt,$mtime,$size" >> "$TMP_CSV"
    hashed=$((hashed + 1))
  fi
done

# Note: Variables count, skipped, hashed won't be available in parent shell due to subshell
# We'll calculate them from the output file instead

end_time=$(date +%s)
echo "[INFO] Finished hashing: $(date) (Elapsed: $((end_time-mid_time))s)"

# Calculate statistics from the output file
total_lines=$(wc -l < "$TMP_CSV" 2>/dev/null || echo "1")
total_files=$((total_lines - 1))  # Subtract header line
skipped_files=$(grep -c "^[^,]*,\"[^\"]*\",[^,]*,[^,]*,[^,]*,[^,]*,[^,]*$" "$TMP_CSV" 2>/dev/null || echo "0")
hashed_files=$((total_files - skipped_files))

echo "[INFO] Total files: $total_files, Skipped (cache hit): $skipped_files, Hashed: $hashed_files"

mv "$TMP_CSV" "$CSV_FILE"
echo "Done. CSV updated: $CSV_FILE"
echo "[INFO] Total elapsed: $((end_time-start_time))s"
