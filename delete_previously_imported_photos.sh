#!/bin/bash
# File: delete_previously_imported_photos.sh
#
# Purpose:
#   Safely delete photos from one or more source folders (e.g., /mnt/i/FraMobil, /mnt/i/FraKamera) that have already been imported to Lightroom.
#   Imported photos are identified by matching file content (SHA1 hash) with files in /mnt/i/kopiert/Imported on ... (and subfolders),
#   regardless of filename or folder structure. This prevents accidental deletion of unimported photos, even if filenames have changed.
#
# Logic & Workflow:
# 1. Present a menu to select one or more source folders to process.
# 2. Recursively scan each selected source folder and /mnt/i/kopiert/Imported on ... for all files.
# 3. Compute SHA1 hashes for all files, caching results to avoid redundant hashing.
# 4. Identify files in each source folder whose hashes match any file in /mnt/i/kopiert/Imported on ...
# 5. Show a summary for each folder: total files scanned, number of matches (to be deleted), and number of files to keep.
# 6. Prompt for confirmation before deleting any files from each folder.
# 7. Delete only the files that are confirmed as already imported.
# 8. Log actions and provide a summary at the end.
#
# This script is safe, robust, and efficient for large photo collections. It is intended to be run as-needed to clean up your source folders.
#
# Requirements: bash, find, sha1sum, sort, awk, grep, comm
#
# Usage:
#   bash delete_previously_imported_photos.sh
#

set -e
trap 'echo -e "\033[0;31m❌ An error occurred. Exiting.\033[0m"' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

# Candidate source folders (add more as needed)
CANDIDATE_FOLDERS=("/mnt/i/FraMobil" "/mnt/i/FraKamera")

# Imported to Lightroom folder
KOPIERT="/mnt/i/kopiert"
KOPIERT_HASHES="kopiert_hashes.txt"

# Interactive folder selection
echo -e "${WHITE}Available source folders:${NC}"
select folder in "${CANDIDATE_FOLDERS[@]}" "All"; do
  if [[ -n "$folder" ]]; then
    if [[ "$folder" == "All" ]]; then
      SELECTED_FOLDERS=("${CANDIDATE_FOLDERS[@]}")
    else
      SELECTED_FOLDERS=("$folder")
    fi
    break
  else
    echo -e "${YELLOW}Please select a valid option.${NC}"
  fi
done

# Optionally allow multi-selection
while true; do
  echo -ne "${YELLOW}Add another folder? (y/N): ${NC}"
  read addmore
  if [[ ! "$addmore" =~ ^[Yy]$ ]]; then
    break
  fi
  echo -e "${WHITE}Available source folders:${NC}"
  select folder in "${CANDIDATE_FOLDERS[@]}"; do
    if [[ -n "$folder" && ! " ${SELECTED_FOLDERS[@]} " =~ " $folder " ]]; then
      SELECTED_FOLDERS+=("$folder")
      break
    else
      echo -e "${YELLOW}Please select a valid option or one not already selected.${NC}"
    fi
  done
done

# Remove duplicates
SELECTED_FOLDERS=($(printf "%s\n" "${SELECTED_FOLDERS[@]}" | awk '!seen[$0]++'))

if [[ ${#SELECTED_FOLDERS[@]} -eq 0 ]]; then
  echo -e "${RED}No source folders selected. Exiting.${NC}"
  exit 1
fi

echo -e "${GREEN}Selected folder(s): $(IFS=, ; echo "${SELECTED_FOLDERS[*]}")${NC}"



# Summary log
YEAR=$(date +%Y)
SUMMARY_LOG="delete_imported_summary_$YEAR.txt"

# Ask for dry run mode
DRY_RUN=0
echo -ne "${YELLOW}Dry run (no files will be deleted)? (y/N): ${NC}"
read dryrun_confirm
if [[ "$dryrun_confirm" =~ ^[Yy]$ ]]; then
  DRY_RUN=1
  echo -e "${GRAY}Dry run mode enabled. No files will actually be deleted.${NC}"
fi

# Incremental hashing function
incremental_hash() {
  local folder="$1"
  local hashfile="$2"
  local tmpfile="${hashfile}.tmp"
  local filelistfile="${hashfile}.filelist"

  # Get all files in folder
  find "$folder" -type f | sort > "$filelistfile"

  # If hashfile does not exist, hash all files
  if [ ! -f "$hashfile" ]; then
    cat "$filelistfile" | xargs -d '\n' -I{} sha1sum "{}" > "$hashfile"
    return
  fi

  # Get list of already hashed files
  awk '{print $2}' "$hashfile" | sort > "${hashfile}.hashedfiles"
  # Find new files
  comm -23 "$filelistfile" "${hashfile}.hashedfiles" > "${hashfile}.newfiles"

  # Hash only new files and append
  if [ -s "${hashfile}.newfiles" ]; then
    cat "${hashfile}.newfiles" | xargs -d '\n' -I{} sha1sum "{}" >> "$hashfile"
  fi

  # Optionally, remove hashes for files that no longer exist
  awk 'NR==FNR{f[$1]=1; next} f[$2]' "$filelistfile" "$hashfile" > "$tmpfile"
  mv "$tmpfile" "$hashfile"

  rm -f "${hashfile}.hashedfiles" "${hashfile}.newfiles" "$filelistfile"
}

# --- Step 1: Generate/cached hashes for KOPIERT ---
echo -e "${YELLOW}Scanning $KOPIERT for files...${NC}"
incremental_hash "$KOPIERT" "$KOPIERT_HASHES"
awk '{print $1}' "$KOPIERT_HASHES" | sort > kopiert_hashes_only.txt

# --- Step 2: Process each selected source folder ---
for SRCFOLDER in "${SELECTED_FOLDERS[@]}"; do
  SRC_HASHES="$(basename "$SRCFOLDER" | tr -c 'A-Za-z0-9' '_')_hashes.txt"
  echo -e "${YELLOW}Scanning $SRCFOLDER for files...${NC}"
  incremental_hash "$SRCFOLDER" "$SRC_HASHES"
  awk '{print $1}' "$SRC_HASHES" | sort > src_hashes_only.txt
  comm -12 src_hashes_only.txt kopiert_hashes_only.txt > already_imported_hashes.txt
  awk 'NR==FNR{h[$1]=1; next} h[$1]{print $2}' already_imported_hashes.txt "$SRC_HASHES" > files_to_delete.txt
  TOTAL_FILES=$(wc -l < src_hashes_only.txt)
  TO_DELETE=$(wc -l < files_to_delete.txt)
  TO_KEEP=$((TOTAL_FILES - TO_DELETE))
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  echo "" >> "$SUMMARY_LOG"
  echo "[$NOW] delete_previously_imported_photos.sh run for $SRCFOLDER" >> "$SUMMARY_LOG"
  echo "  Total files in $SRCFOLDER: $TOTAL_FILES" | tee -a "$SUMMARY_LOG"
  echo "  Files already imported (to be deleted): $TO_DELETE" | tee -a "$SUMMARY_LOG"
  echo "  Files to keep: $TO_KEEP" | tee -a "$SUMMARY_LOG"
  if [[ $TO_DELETE -eq 0 ]]; then
    echo -e "${GREEN}No files to delete in $SRCFOLDER. All files are not yet imported.${NC}"
    continue
  fi
  echo -e "${WHITE}Files to be deleted from $SRCFOLDER:${NC}"
  head -20 files_to_delete.txt
  [ $TO_DELETE -gt 20 ] && echo -e "${GRAY}...and $((TO_DELETE-20)) more${NC}"
  echo -ne "${YELLOW}Proceed to delete these $TO_DELETE files from $SRCFOLDER? (y/N): ${NC}"
  read confirm
  echo "  User confirmation: $confirm" >> "$SUMMARY_LOG"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Deletion cancelled for $SRCFOLDER.${NC}"
    echo "  Deletion cancelled by user for $SRCFOLDER." >> "$SUMMARY_LOG"
    continue
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}Dry run: The following files would be deleted from $SRCFOLDER:${NC}"
    while read -r file; do
      echo -e "${GRAY}Would delete: $file${NC}"
      NOW=$(date '+%Y-%m-%d %H:%M:%S')
      echo "$NOW,dryrun,$file,success" >> "$SUMMARY_LOG"
    done < files_to_delete.txt
    echo -e "${GREEN}Dry run complete. $TO_DELETE files would be deleted from $SRCFOLDER.${NC}"
    echo "  Dry run complete. $TO_DELETE files would be deleted from $SRCFOLDER." >> "$SUMMARY_LOG"
    continue
  fi
  echo -e "${YELLOW}Deleting files from $SRCFOLDER...${NC}"
  while read -r file; do
    if rm -f "$file"; then
      echo -e "${GREEN}Deleted: $file${NC}"
      NOW=$(date '+%Y-%m-%d %H:%M:%S')
      echo "$NOW,deleted,$file,success" >> "$SUMMARY_LOG"
    else
      echo -e "${RED}Failed to delete: $file${NC}"
      NOW=$(date '+%Y-%m-%d %H:%M:%S')
      echo "$NOW,delete_failed,$file,fail" >> "$SUMMARY_LOG"
    fi
  done < files_to_delete.txt
  echo -e "${GREEN}Deletion complete. $TO_DELETE files deleted from $SRCFOLDER.${NC}"
  echo "  Deletion complete. $TO_DELETE files deleted from $SRCFOLDER." >> "$SUMMARY_LOG"
done 