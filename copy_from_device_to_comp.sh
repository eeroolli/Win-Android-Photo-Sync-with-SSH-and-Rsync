#!/bin/bash
# File: copy_from_device_to_comp.sh
#
# Purpose:
#   Copy photos and videos from your device (phone/camera) to your computer, avoiding re-copy of files already copied previously.
#   Uses copied_device_files.log to track all files that have been copied from the device, and device_sync_log_YYYY.csv to log all actions.
#
# IMPORTANT LOG FILES:
#   sync_log_YYYY.txt - MAIN LOG: Human-readable summary of all operations (most important for users)
#   device_sync_log_YYYY.csv - Detailed CSV log of each file copied/moved (for analysis)
#   copied_device_files.log - Database of all files copied from device (for filtering)
#   device_copied_hashes.txt - SHA1 hash database for deduplication and safe deletion
#
# Logic & Workflow:
# 1. Loads configuration (connection, folders, exclusions, import log, etc.).
# 2. Lists subfolders on the phone (excluding those in config) and lets you select which to process.
# 3. For each selected subfolder:
#    - Prompts for copy/move, file selection criteria (all, since last, after/before date), and deletion options.
#    - Builds a file list using date filters and import log.
#    - Filters out files already present in copied_device_files.log (by relative path).
#    - Shows a summary (file count, oldest/newest, files to delete if chosen).
#    - Prompts for confirmation before syncing and before deleting.
#    - Performs sync with rsync.
#    - Updates the import log with files that were copied/moved.
#    - If deletion is chosen, only deletes files that are both on the phone and in the import log, after a final confirmation.
#
# This ensures you only import new files, never re-copy files already imported, and gives you full control and feedback at every step.
#
# Dependency: csvtool (install with sudo apt-get install csvtool)
# Example: To check if a hash exists in the Lightroom import CSV
# Always use csvtool and strip quotes for robust comparison:
# if csvtool col 1,2 imported_to_lightroom_hashes.csv | tail -n +2 | while IFS=, read -r hash path; do
#   path_unquoted=$(echo "$path" | sed 's/^"\(.*\)"$/\1/')
#   # compare $path_unquoted to your filesystem path
# done

set -e
trap 'echo -e "\033[0;31m❌ An error occurred. Exiting.\033[0m"' ERR



# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

# Source config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}Config file $CONFIG_FILE not found!${NC}"
  exit 1
fi
source "$CONFIG_FILE"

# At the start of the script, update the Lightroom hash CSV and persistent hash file
UPDATE_HASH_SCRIPT="$SCRIPT_DIR/update_imported_to_lightroom_hashes.sh"
if [ ! -x "$UPDATE_HASH_SCRIPT" ]; then
  echo "Error: $UPDATE_HASH_SCRIPT not found or not executable!"
  exit 1
fi
"$UPDATE_HASH_SCRIPT"

# Use config values for logs
YEAR=$(date +%Y)
SUMMARY_LOG="$SCRIPT_DIR/sync_log_${YEAR}.txt"
FILE_LOG="$SCRIPT_DIR/device_sync_log_${YEAR}.csv"
COPY_LOG_FILE="$IMPORT_LOG_FILE"

# set -x

# Helper: join array with delimiter
join_by() { local IFS="$1"; shift; echo "$*"; }

# List subfolders on phone, filter with EXCLUDE_FOLDERS
IFS=',' read -ra EXCL <<< "$EXCLUDE_FOLDERS"
EXCL_PATTERN=$(join_by '|' "${EXCL[@]}")

SUBFOLDERS=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "ls -1d $REMOTE_DIR*/ 2>/dev/null | xargs -n1 basename" | grep -vE "^($EXCL_PATTERN)" || true)

if [ -z "$SUBFOLDERS" ]; then
  echo -e "${RED}No subfolders found in $REMOTE_DIR!${NC}"
  exit 1
fi

# Prompt for subfolder selection
echo -e "${WHITE}Available subfolders on phone:${NC}"
select folder in $SUBFOLDERS "All"; do
  if [[ -n "$folder" ]]; then
    if [[ "$folder" == "All" ]]; then
      SELECTED_FOLDERS=($SUBFOLDERS)
    else
      SELECTED_FOLDERS=("$folder")
    fi
    break
  else
    echo -e "${YELLOW}Please select a valid option.${NC}"
  fi
done

echo -e "${GREEN}Selected folder(s): $(join_by ', ' "${SELECTED_FOLDERS[@]}")${NC}\n"

# Write CSV header if file does not exist
if [ ! -f "$FILE_LOG" ]; then
  echo "datetime,action,src_path,dest_path,status" > "$FILE_LOG"
fi

# Test SSH connection before proceeding
ssh -i "$SSH_KEY" -p "$PHONE_PORT" -o ConnectTimeout=5 "$PHONE_USER@$PHONE_IP" 'echo OK' >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo -e "${RED}Could not connect to device via SSH!${NC}"
  echo -e "${YELLOW}Please check that Termux is running on your mobile, and that the SSH server is started (sshd).${NC}"
  echo -e "${YELLOW}You can usually start it by opening Termux and running: 'sshd'${NC}"
  exit 1
fi

# Helper: get mtime for a file on the device
get_device_file_mtime() {
  ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%Y' '$1'" 2>/dev/null
}

# Load copied files (filename + mtime) into an associative array for fast lookup
declare -A copied
if [ -f "$COPY_LOG_FILE" ]; then
  while read -r line; do
    # Format: /mnt/i/FraMobil/Camera/filename.jpg|mtime
    basepath="${line%%|*}"
    mtime="${line##*|}"
    relpath="${basepath#/mnt/i/FraMobil/}"
    relpath="${relpath#/mnt/i/FraKamera/}"
    copied["$relpath|$mtime"]=1
  done < "$COPY_LOG_FILE"
fi

# For each selected subfolder, prompt for options
for SUBF in "${SELECTED_FOLDERS[@]}"; do
  # --- Write summary header ---
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  echo "" >> "$SUMMARY_LOG"
  echo "[$NOW] Processing subfolder: $SUBF" >> "$SUMMARY_LOG"
  echo "  Selection rule: $FILE_FILTER" >> "$SUMMARY_LOG"
  echo "  Action: $ACTION from $REMOTE_DIR/$SUBF to $LOCAL_DIR/$SUBF" >> "$SUMMARY_LOG"

  # Prompt for copy or move
  echo -ne "${YELLOW}Do you want to copy or move files from $SUBF? (c/m) [c]: ${NC}"
  read cmode
  [[ -z "$cmode" ]] && cmode="c"
  if [[ "$cmode" == "m" ]]; then
    ACTION="move"
  else
    ACTION="copy"
  fi

  # Prompt for file selection criteria
  echo -e "${WHITE}File selection options:${NC}"
  echo "  1) All files"
  echo "  2) Since last copy/move (default)"
  echo "  3) After a date"
  echo "  4) Before a date"
  echo "  5) Between two dates"
  echo -ne "${YELLOW}Choose file selection [2]: ${NC}"
  read fsel
  [[ -z "$fsel" ]] && fsel=2

  # --- Determine last sync/move time from CSV log if needed ---
  LAST_SYNC_DATE=""
  if [[ "$fsel" == "2" ]]; then
    LAST_SYNC_DATE=$(awk -F, -v subf="$SUBF" 'tolower($2) ~ /copy|move/ && $3 ~ subf {print $1}' "$FILE_LOG" | sort | tail -1)
  fi

  case $fsel in
    1) FILE_FILTER="all";;
    3)
      echo -ne "${YELLOW}Enter start date (format: YYYY-MM-DD): ${NC}"
      read START_DATE
      FILE_FILTER="after";;
    4)
      echo -ne "${YELLOW}Enter end date (format: YYYY-MM-DD): ${NC}"
      read END_DATE
      FILE_FILTER="before";;
    5)
      echo -ne "${YELLOW}Enter start date (format: YYYY-MM-DD): ${NC}"
      read START_DATE
      echo -ne "${YELLOW}Enter end date (format: YYYY-MM-DD): ${NC}"
      read END_DATE
      FILE_FILTER="between";;
    *) FILE_FILTER="since_last";;
  esac

  # Prompt for deletion
  echo -ne "${YELLOW}Delete files on phone that have been copied? (y/N): ${NC}"
  read delopt
  [[ "$delopt" =~ ^[Yy]$ ]] && DELETE_COPIED=1 || DELETE_COPIED=0

  # --- Build file list on phone ---
  REMOTE_SUBFOLDER="$REMOTE_DIR/$SUBF"
  # List files, filter by date and EXCLUDE_BEFORE_DATE
  FIND_CMD="find '$REMOTE_SUBFOLDER' -type f"
  if [[ "$FILE_FILTER" == "after" && -n "$START_DATE" ]]; then
    # Use the later of EXCLUDE_BEFORE_DATE and START_DATE
    if [[ -n "$EXCLUDE_BEFORE_DATE" ]]; then
      if [[ "$START_DATE" < "$EXCLUDE_BEFORE_DATE" ]]; then
        FIND_CMD+=" -newermt '$EXCLUDE_BEFORE_DATE'"
      else
        FIND_CMD+=" -newermt '$START_DATE'"
      fi
    else
      FIND_CMD+=" -newermt '$START_DATE'"
    fi
  elif [[ "$FILE_FILTER" == "before" && -n "$END_DATE" ]]; then
    FIND_CMD+=" ! -newermt '$END_DATE'"
  elif [[ "$FILE_FILTER" == "between" && -n "$START_DATE" && -n "$END_DATE" ]]; then
    FIND_CMD+=" -newermt '$START_DATE' ! -newermt '$END_DATE'"
  elif [[ "$FILE_FILTER" == "since_last" && -n "$LAST_SYNC_DATE" ]]; then
    FIND_CMD+=" -newermt '$LAST_SYNC_DATE'"
  elif [[ "$FILE_FILTER" == "all" ]]; then
    if [[ -n "$EXCLUDE_BEFORE_DATE" ]]; then
      FIND_CMD+=" -newermt '$EXCLUDE_BEFORE_DATE'"
    fi
  fi
  FILE_LIST=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD" | sort || true)
  FILE_COUNT=$(echo "$FILE_LIST" | grep -c . || true)

  # Debug output removed for cleaner interface

  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to list files on the device. Check SSH connection, permissions, and path.${NC}"
    exit 1
  fi

  # --- Filter out already copied files ---
  FILTERED_FILE_LIST=""
  while read -r phone_file; do
    relpath="${phone_file#$REMOTE_DIR/}"
    mtime=$(get_device_file_mtime "$phone_file")
    if [[ -z "${copied[$relpath|$mtime]}" ]]; then
      FILTERED_FILE_LIST+="$phone_file|$mtime"$'\n'
    fi
    # else: already copied (by name+mtime)
  done <<< "$FILE_LIST"
  FILE_LIST="$FILTERED_FILE_LIST"
  FILE_COUNT=$(echo "$FILE_LIST" | grep -c . || true)

  # Get oldest and newest file dates
  if [[ $FILE_COUNT -gt 0 ]]; then
    OLDEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-" || true)
    NEWEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-" || true)
    OLDEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$OLDEST_FILE' | cut -d'.' -f1" || true)
    NEWEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$NEWEST_FILE' | cut -d'.' -f1" || true)
  else
    OLDEST_DATE="-"
    NEWEST_DATE="-"
  fi

  # --- Show summary in terminal (same format as log file) ---
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "\n${WHITE}[$NOW] Processing subfolder: $SUBF${NC}"
  echo -e "  ${GRAY}Selection rule: ${WHITE}$FILE_FILTER${NC}"
  echo -e "  ${GRAY}Action: ${WHITE}$ACTION from $REMOTE_DIR/$SUBF to $LOCAL_DIR/$SUBF${NC}"
  
  if [[ $FILE_COUNT -gt 0 ]]; then
    echo -e "  ${GRAY}Number of files: ${WHITE}$FILE_COUNT${NC}"
    echo -e "  ${GRAY}Oldest file: ${WHITE}$OLDEST_DATE${NC}"
    echo -e "  ${GRAY}Newest file: ${WHITE}$NEWEST_DATE${NC}"
  else
    echo -e "  ${GRAY}Number of files: ${WHITE}0${NC}"
    echo -e "  ${GRAY}Oldest file: ${WHITE}-${NC}"
    echo -e "  ${GRAY}Newest file: ${WHITE}-${NC}"
  fi
  
  # Write to log file (same format)
  echo "" >> "$SUMMARY_LOG"
  echo "[$NOW] Processing subfolder: $SUBF" >> "$SUMMARY_LOG"
  echo "  Selection rule: $FILE_FILTER" >> "$SUMMARY_LOG"
  echo "  Action: $ACTION from $REMOTE_DIR/$SUBF to $LOCAL_DIR/$SUBF" >> "$SUMMARY_LOG"
  echo "  Number of files: $FILE_COUNT" >> "$SUMMARY_LOG"
  echo "  Oldest file: $OLDEST_DATE" >> "$SUMMARY_LOG"
  echo "  Newest file: $NEWEST_DATE" >> "$SUMMARY_LOG"

  if [[ -z "$FILE_LIST" || $FILE_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}  No files to copy or move for $SUBF. Nothing to do.${NC}"
    echo "  No files to copy or move for $SUBF. Nothing to do." >> "$SUMMARY_LOG"
    continue
  fi

  # --- Deletion preview ---
  if [[ $DELETE_COPIED -eq 1 && $FILE_COUNT -gt 0 ]]; then
    # Only delete files that are in the copy log
    if [ -f "$COPY_LOG_FILE" ]; then
      FILES_TO_DELETE=$(comm -12 <(echo "$FILE_LIST" | sort || true) <(awk '{print $1}' "$COPY_LOG_FILE" | sort || true) || true)
      DELETE_COUNT=$(echo "$FILES_TO_DELETE" | grep -c . || true)
    else
      DELETE_COUNT=0
    fi
    echo -e "  ${GRAY}Files to be deleted: ${WHITE}$DELETE_COUNT${NC}"
    echo "  Files to be deleted: $DELETE_COUNT" >> "$SUMMARY_LOG"
  fi

  # --- Confirm ---
  echo -ne "${YELLOW}Proceed with action for $SUBF? (y/N): ${NC}"
  read go
  if [[ ! "$go" =~ ^[Yy]$ ]]; then
    echo -e "${RED}  Skipped by user.${NC}"
    echo "  Skipped by user." >> "$SUMMARY_LOG"
    continue
  fi

  # --- Perform sync ---
  LOCAL_SUBFOLDER="$LOCAL_DIR/$SUBF"
  mkdir -p "$LOCAL_SUBFOLDER"
  RSYNC_OPTS="-av --progress"
  [[ "$ACTION" == "copy" ]] && RSYNC_OPTS+=" --ignore-existing"
  RSYNC_CMD="rsync $RSYNC_OPTS -e \"ssh -i $SSH_KEY -p $PHONE_PORT\" $PHONE_USER@$PHONE_IP:'$REMOTE_SUBFOLDER/' '$LOCAL_SUBFOLDER/'"
  echo -e "${GREEN}Starting sync for $SUBF...${NC}"
  # Perform sync and log files after completion
  eval "$RSYNC_CMD --progress"
  
  # Log all files that were copied/moved by checking what's new in the local folder
  find "$LOCAL_SUBFOLDER" -type f -newer "$FILE_LOG" 2>/dev/null | while read -r local_file; do
    rel_path="${local_file#$LOCAL_SUBFOLDER/}"
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    src="$REMOTE_SUBFOLDER/$rel_path"
    dest="$local_file"
    echo "$NOW,$ACTION,$src,$dest,success" >> "$FILE_LOG"
  done
  echo -e "${GREEN}  Sync complete for $SUBF.${NC}"
  echo "  Sync complete for $SUBF." >> "$SUMMARY_LOG"

  # --- Update copy log ---
  # Log all files now present in local subfolder
  if [ -d "$COPY_LOG_FILE" ]; then
    echo "Error: COPY_LOG_FILE ($COPY_LOG_FILE) is a directory, not a file!"
    exit 1
  fi
  find "$LOCAL_SUBFOLDER" -type f | while read -r f; do
    echo "$f" >> "$COPY_LOG_FILE"
  done

  # --- Deletion step ---
  if [[ $DELETE_COPIED -eq 1 && $DELETE_COUNT -gt 0 ]]; then
    echo -ne "${YELLOW}About to delete $DELETE_COUNT files from phone in $SUBF. Continue? (y/N): ${NC}"
    read del_confirm
    if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
      echo "$FILES_TO_DELETE" | while read -r del_file; do
        ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "rm -f '$del_file'" && \
        NOW=$(date '+%Y-%m-%d %H:%M:%S'); echo "$NOW,deleted,$del_file,,success" >> "$FILE_LOG"
      done
      echo -e "${GREEN}  Deleted $DELETE_COUNT files from phone in $SUBF.${NC}"
      echo "  Deleted $DELETE_COUNT files from phone in $SUBF." >> "$SUMMARY_LOG"
    else
      echo -e "${RED}  Deletion cancelled for $SUBF.${NC}"
      echo "  Deletion cancelled for $SUBF." >> "$SUMMARY_LOG"
    fi
  fi

  # --- Perform incremental hashing for new files ---
  # (Assume LOCAL_SUBFOLDER is set)
  HASH_LOG="$SCRIPT_DIR/device_copied_hashes.txt"
  if [ ! -f "$HASH_LOG" ]; then
    touch "$HASH_LOG"
  fi
  find "$LOCAL_SUBFOLDER" -type f | while read -r f; do
    # Check if file is already hashed
    if ! grep -q " $f$" "$HASH_LOG"; then
      sha1sum "$f" >> "$HASH_LOG"
    fi
    # Update copy log with filename|mtime
    mtime=$(stat -c '%Y' "$f")
    echo "$f|$mtime" >> "$COPY_LOG_FILE"
  done

  if [ $? -ne 0 ]; then
    echo -e "${RED}Error during hashing of copied files. Please check file permissions and disk space.${NC}"
    echo "  Hashing error for $SUBF." >> "$SUMMARY_LOG"
    continue
  fi

done

# --- Clean up temp files ---
# Remove any temporary files that might have been created during this run
rm -f /tmp/rsync_* /tmp/ssh_* 2>/dev/null || true



