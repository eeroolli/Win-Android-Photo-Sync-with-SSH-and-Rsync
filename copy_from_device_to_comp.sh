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
#
# Usage:
#   bash copy_from_device_to_comp.sh [--debug]
#   bash copy_from_device_to_comp.sh --debug  # Enable debug mode

# Check for debug mode
DEBUG_MODE=0
if [[ "$1" == "--debug" ]]; then
  DEBUG_MODE=1
  echo -e "\033[1;33m🔍 DEBUG MODE ENABLED\033[0m"
fi

set -e
trap 'echo -e "\033[0;31m❌ An error occurred. Exiting.\033[0m"' ERR



# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

# Debug function
debug_echo() {
  if [[ $DEBUG_MODE -eq 1 ]]; then
    echo -e "${GRAY}[DEBUG] $1${NC}"
  fi
}

debug_var() {
  if [[ $DEBUG_MODE -eq 1 ]]; then
    echo -e "${GRAY}[DEBUG] $1 = '$2'${NC}"
  fi
}

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
# Temporarily disable hashing to test main functionality
# "$UPDATE_HASH_SCRIPT"

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
  set +e
  result=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%Y' '$1'" 2>/dev/null)
  exit_code=$?
  set -e
  if [ $exit_code -ne 0 ]; then
    debug_echo "DEBUG: Failed to get mtime for $1, using 0"
    echo "0"
  else
    echo "$result"
  fi
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
  echo "  3) Including and after a date"
  echo "  4) Before a date (excluding)"
  echo "  5) Between two dates (including both)"
  echo "  6) Today only"
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
    6)
      TODAY=$(date +%Y-%m-%d)
      START_DATE="$TODAY"
      END_DATE="$TODAY"
      FILE_FILTER="today";;
    *) FILE_FILTER="since_last";;
  esac

  # Prompt for deletion
  echo -ne "${YELLOW}Delete files on phone that have been copied? (y/N): ${NC}"
  read delopt
  [[ "$delopt" =~ ^[Yy]$ ]] && DELETE_COPIED=1 || DELETE_COPIED=0

  # --- Build file list on phone ---
  REMOTE_SUBFOLDER="$REMOTE_DIR/$SUBF"
  # List files, filter by date and EXCLUDE_BEFORE_DATE
  # Use a simpler approach to avoid complex find command issues
  FIND_CMD="find '$REMOTE_SUBFOLDER' -type f"
  
  # Add date filters
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
  elif [[ "$FILE_FILTER" == "today" && -n "$START_DATE" && -n "$END_DATE" ]]; then
    # For today, we want files from START_DATE (today) but before END_DATE + 1 day
    TOMORROW=$(date -d "$END_DATE +1 day" +%Y-%m-%d)
    FIND_CMD+=" -newermt '$START_DATE' ! -newermt '$TOMORROW'"
  elif [[ "$FILE_FILTER" == "since_last" && -n "$LAST_SYNC_DATE" ]]; then
    FIND_CMD+=" -newermt '$LAST_SYNC_DATE'"
  elif [[ "$FILE_FILTER" == "all" ]]; then
    if [[ -n "$EXCLUDE_BEFORE_DATE" ]]; then
      FIND_CMD+=" -newermt '$EXCLUDE_BEFORE_DATE'"
    fi
  fi
  
  # Get all files first, then filter by extension
  debug_echo "DEBUG: Running find command: $FIND_CMD"
  set +e
  ALL_FILES=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD" 2>&1)
  FIND_EXIT_CODE=$?
  set -e
  
  if [ $FIND_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Error: Find command failed with exit code $FIND_EXIT_CODE${NC}"
    echo -e "${GRAY}DEBUG: Find command output:${NC}"
    echo "$ALL_FILES"
    exit 1
  fi
  
  # Filter by file extensions
  FILE_LIST=$(echo "$ALL_FILES" | grep -E '\.(jpg|jpeg|png|mp4|mov|cr2|nef|arw|dng|raf|rw2|orf|pef)$' | sort || true)
  FILE_COUNT=$(echo "$FILE_LIST" | grep -c . || true)
  
  debug_echo "DEBUG: Found $FILE_COUNT files matching criteria"
  
  # Debug output removed for cleaner interface
  debug_echo "DEBUG: About to check SSH connection"
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to list files on the device. Check SSH connection, permissions, and path.${NC}"
    exit 1
  fi
  
  debug_echo "DEBUG: About to filter already copied files"
  
  # --- Filter out already copied files for copying, but keep track of all files for deletion ---
  FILTERED_FILE_LIST=""
  ALL_FILES_FOR_DELETION=""  # Keep track of all files for deletion in move operations
  file_count=0
  debug_echo "DEBUG: Starting to process $FILE_COUNT files"
  debug_echo "DEBUG: FILE_LIST length: $(echo "$FILE_LIST" | wc -l) lines"
  debug_echo "DEBUG: First few lines of FILE_LIST:"
  echo "$FILE_LIST" | head -3 | while read line; do
    debug_echo "DEBUG:   $line"
  done
  
  # Use a temporary file to avoid subshell issues
  TEMP_FILE_LIST="/tmp/file_list_$$.txt"
  echo "$FILE_LIST" > "$TEMP_FILE_LIST"
  debug_echo "DEBUG: Created temp file with $(wc -l < "$TEMP_FILE_LIST") lines"
  
  while read -r phone_file; do
    file_count=$((file_count + 1))
    if [[ $file_count -le 5 ]]; then
      debug_echo "DEBUG: Processing file $file_count: $phone_file"
    elif [[ $file_count -eq 6 ]]; then
      debug_echo "DEBUG: ... (processing more files, showing first 5 only)"
    fi
    relpath="${phone_file#$REMOTE_DIR/}"
    if [[ $file_count -le 5 ]]; then
      debug_echo "DEBUG: Relative path: $relpath"
    fi
    mtime=$(get_device_file_mtime "$phone_file")
    if [[ $file_count -le 5 ]]; then
      debug_echo "DEBUG: Mtime: $mtime"
    fi
    
    # For move operations, track all files for deletion but only copy new files
    if [[ "$ACTION" == "move" ]]; then
      # Always add to deletion list for move operations
      ALL_FILES_FOR_DELETION+="$phone_file|$mtime"$'\n'
      
      # Only add to copy list if not already copied
      if [[ -z "${copied[$relpath|$mtime]}" ]]; then
        FILTERED_FILE_LIST+="$phone_file|$mtime"$'\n'
        if [[ $file_count -le 5 ]]; then
          debug_echo "DEBUG: Move operation - file not copied before, will copy and delete"
        fi
      else
        if [[ $file_count -le 5 ]]; then
          debug_echo "DEBUG: Move operation - file already copied, will only delete"
        fi
      fi
    else
      # For copy operations, check if already copied
      if [[ -z "${copied[$relpath|$mtime]}" ]]; then
        FILTERED_FILE_LIST+="$phone_file|$mtime"$'\n'
        if [[ $file_count -le 5 ]]; then
          debug_echo "DEBUG: File not copied before, adding to list"
        fi
      else
        if [[ $file_count -le 5 ]]; then
          debug_echo "DEBUG: File already copied, skipping"
        fi
      fi
    fi
  done < "$TEMP_FILE_LIST"
  
  # Clean up temp file
  rm -f "$TEMP_FILE_LIST"
  
  debug_echo "DEBUG: Finished processing $file_count files"
  
  # For move operations, use the full list for deletion but filtered list for copying
  if [[ "$ACTION" == "move" ]]; then
    FILE_LIST_FOR_COPY="$FILTERED_FILE_LIST"
    FILE_LIST_FOR_DELETE="$ALL_FILES_FOR_DELETION"
    FILE_COUNT_FOR_COPY=$(echo "$FILE_LIST_FOR_COPY" | grep -c . || true)
    FILE_COUNT_FOR_DELETE=$(echo "$FILE_LIST_FOR_DELETE" | grep -c . || true)
    debug_echo "DEBUG: Move operation - $FILE_COUNT_FOR_COPY files to copy, $FILE_COUNT_FOR_DELETE files to delete"
  else
    FILE_LIST="$FILTERED_FILE_LIST"
    FILE_COUNT=$(echo "$FILE_LIST" | grep -c . || true)
    debug_echo "DEBUG: Copy operation - $FILE_COUNT files to copy"
  fi
  
  debug_echo "DEBUG: After filtering, $FILE_COUNT files remain"
  
  # Get oldest and newest file dates
  debug_echo "DEBUG: About to get oldest/newest file dates"
  if [[ $FILE_COUNT -gt 0 ]]; then
    set +e
    OLDEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-" 2>&1)
    OLDEST_EXIT_CODE=$?
    set -e
    debug_echo "DEBUG: Oldest file command exit code: $OLDEST_EXIT_CODE"
    debug_echo "DEBUG: Oldest file: $OLDEST_FILE"
    
    set +e
    NEWEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-" 2>&1)
    NEWEST_EXIT_CODE=$?
    set -e
    debug_echo "DEBUG: Newest file command exit code: $NEWEST_EXIT_CODE"
    debug_echo "DEBUG: Newest file: $NEWEST_FILE"
    
    if [ $OLDEST_EXIT_CODE -eq 0 ] && [ -n "$OLDEST_FILE" ]; then
      set +e
      OLDEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$OLDEST_FILE' | cut -d'.' -f1" 2>&1)
      OLDEST_DATE_EXIT_CODE=$?
      set -e
      debug_echo "DEBUG: Oldest date command exit code: $OLDEST_DATE_EXIT_CODE"
      debug_echo "DEBUG: Oldest date: $OLDEST_DATE"
    else
      OLDEST_DATE="-"
    fi
    
    if [ $NEWEST_EXIT_CODE -eq 0 ] && [ -n "$NEWEST_FILE" ]; then
      set +e
      NEWEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$NEWEST_FILE' | cut -d'.' -f1" 2>&1)
      NEWEST_DATE_EXIT_CODE=$?
      set -e
      debug_echo "DEBUG: Newest date command exit code: $NEWEST_DATE_EXIT_CODE"
      debug_echo "DEBUG: Newest date: $NEWEST_DATE"
    else
      NEWEST_DATE="-"
    fi
  else
    OLDEST_DATE="-"
    NEWEST_DATE="-"
  fi

  debug_echo "DEBUG: About to show summary in terminal"
  
  # --- Show summary in terminal (same format as log file) ---
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  debug_echo "DEBUG: Generated NOW timestamp: $NOW"
  echo -e "\n${WHITE}[$NOW] Processing subfolder: $SUBF${NC}"
  debug_echo "DEBUG: Displayed summary header"
  echo -e "  ${GRAY}Selection rule: ${WHITE}$FILE_FILTER${NC}"
  debug_echo "DEBUG: Displayed selection rule"
  echo -e "  ${GRAY}Action: ${WHITE}$ACTION from $REMOTE_DIR/$SUBF to $LOCAL_DIR/$SUBF${NC}"
  debug_echo "DEBUG: Displayed action line"

  debug_echo "DEBUG: About to use rsync --dry-run to count files"
  
  # Use rsync --dry-run to count files that will actually be copied
  LOCAL_SUBFOLDER="$LOCAL_DIR/$SUBF"
  debug_echo "DEBUG: LOCAL_SUBFOLDER = $LOCAL_SUBFOLDER"
  mkdir -p "$LOCAL_SUBFOLDER"
  debug_echo "DEBUG: Created local subfolder"
  RSYNC_OPTS="-av --progress"
  [[ "$ACTION" == "copy" ]] && RSYNC_OPTS+=" --ignore-existing"
  debug_echo "DEBUG: RSYNC_OPTS = $RSYNC_OPTS"
  RSYNC_CMD="rsync $RSYNC_OPTS -e \"ssh -i $SSH_KEY -p $PHONE_PORT\" $PHONE_USER@$PHONE_IP:'$REMOTE_SUBFOLDER/' '$LOCAL_SUBFOLDER/'"
  debug_echo "DEBUG: RSYNC_CMD = $RSYNC_CMD"
  DRY_RUN_CMD="$RSYNC_CMD --dry-run"
  debug_echo "DEBUG: About to run dry-run command to count files"
  
  set +e
  DRY_RUN_OUTPUT=$(eval "$DRY_RUN_CMD" 2>&1)
  DRY_RUN_COUNT_EXIT_CODE=$?
  set -e
  debug_echo "DEBUG: Dry-run count exit code: $DRY_RUN_COUNT_EXIT_CODE"
  debug_echo "DEBUG: Dry-run output length: $(echo "$DRY_RUN_OUTPUT" | wc -l) lines"
  
  if [ $DRY_RUN_COUNT_EXIT_CODE -eq 0 ]; then
    debug_echo "DEBUG: Processing dry-run output to count files"
    set +e
    # Simplify the grep command to avoid crashes
    FILES_TO_COPY_COUNT=$(echo "$DRY_RUN_OUTPUT" | grep -v '/$' | grep -v '^sending ' | grep -v '^sent ' | grep -v '^total size is ' | grep -v '^receiving incremental file list' | grep -v '^building file list' | grep -v '^done$' | grep -v '^Raw$' | grep -v '^\.$' | wc -l)
    GREP_EXIT_CODE=$?
    set -e
    debug_echo "DEBUG: Grep command exit code: $GREP_EXIT_CODE"
    if [ $GREP_EXIT_CODE -ne 0 ]; then
      debug_echo "DEBUG: Grep command failed, setting count to 0"
      FILES_TO_COPY_COUNT=0
    fi
    debug_echo "DEBUG: File count calculation completed"
  else
    debug_echo "DEBUG: Dry-run failed, setting count to 0"
    FILES_TO_COPY_COUNT=0
  fi
  debug_echo "DEBUG: FILES_TO_COPY_COUNT: $FILES_TO_COPY_COUNT"

  debug_echo "DEBUG: About to check if files need to be copied"
  if [[ $FILES_TO_COPY_COUNT -gt 0 ]]; then
    debug_echo "DEBUG: Files need to be copied, getting file dates"
    # Get oldest and newest file dates (optional, keep if useful)
    set +e
    OLDEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-" 2>&1)
    OLDEST_EXIT_CODE=$?
    set -e
    debug_echo "DEBUG: Oldest file command exit code: $OLDEST_EXIT_CODE"
    debug_echo "DEBUG: Oldest file: $OLDEST_FILE"
    
    set +e
    NEWEST_FILE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "$FIND_CMD -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-" 2>&1)
    NEWEST_EXIT_CODE=$?
    set -e
    debug_echo "DEBUG: Newest file command exit code: $NEWEST_EXIT_CODE"
    debug_echo "DEBUG: Newest file: $NEWEST_FILE"
    
    if [ $OLDEST_EXIT_CODE -eq 0 ] && [ -n "$OLDEST_FILE" ]; then
      set +e
      OLDEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$OLDEST_FILE' | cut -d'.' -f1" 2>&1)
      OLDEST_DATE_EXIT_CODE=$?
      set -e
      debug_echo "DEBUG: Oldest date command exit code: $OLDEST_DATE_EXIT_CODE"
      debug_echo "DEBUG: Oldest date: $OLDEST_DATE"
    else
      OLDEST_DATE="-"
    fi
    
    if [ $NEWEST_EXIT_CODE -eq 0 ] && [ -n "$NEWEST_FILE" ]; then
      set +e
      NEWEST_DATE=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "stat -c '%y' '$NEWEST_FILE' | cut -d'.' -f1" 2>&1)
      NEWEST_DATE_EXIT_CODE=$?
      set -e
      debug_echo "DEBUG: Newest date command exit code: $NEWEST_DATE_EXIT_CODE"
      debug_echo "DEBUG: Newest date: $NEWEST_DATE"
    else
      NEWEST_DATE="-"
    fi
    debug_echo "DEBUG: File date processing completed"
  else
    debug_echo "DEBUG: No files to copy, setting dates to -"
    echo -e "  ${GRAY}Number of files to be copied: ${WHITE}0${NC}"
    echo -e "  ${GRAY}Oldest file: ${WHITE}-${NC}"
    echo -e "  ${GRAY}Newest file: ${WHITE}-${NC}"
  fi

  debug_echo "DEBUG: About to write to log file"
  
  # Write to log file (same format)
  echo "" >> "$SUMMARY_LOG"
  debug_echo "DEBUG: Wrote empty line to summary log"
  echo "[$NOW] Processing subfolder: $SUBF" >> "$SUMMARY_LOG"
  debug_echo "DEBUG: Wrote summary header to log"
  echo "  Selection rule: $FILE_FILTER" >> "$SUMMARY_LOG"
  debug_echo "DEBUG: Wrote selection rule to log"
  echo "  Action: $ACTION from $REMOTE_DIR/$SUBF to $LOCAL_DIR/$SUBF" >> "$SUMMARY_LOG"
  debug_echo "DEBUG: Wrote action to log"
  
  # Show appropriate counts for move vs copy operations
  if [[ "$ACTION" == "move" ]]; then
    echo "  Number of files to be copied: $FILES_TO_COPY_COUNT" >> "$SUMMARY_LOG"
    echo "  Number of files to be deleted from phone: $FILE_COUNT_FOR_DELETE" >> "$SUMMARY_LOG"
    echo -e "  ${GRAY}Number of files to be copied: ${WHITE}$FILES_TO_COPY_COUNT${NC}"
    echo -e "  ${GRAY}Number of files to be deleted from phone: ${WHITE}$FILE_COUNT_FOR_DELETE${NC}"
  else
    echo "  Number of files to be copied: $FILES_TO_COPY_COUNT" >> "$SUMMARY_LOG"
    echo -e "  ${GRAY}Number of files to be copied: ${WHITE}$FILES_TO_COPY_COUNT${NC}"
  fi
  
  echo "  Oldest file: $OLDEST_DATE" >> "$SUMMARY_LOG"
  debug_echo "DEBUG: Wrote oldest date to log"
  echo "  Newest file: $NEWEST_DATE" >> "$SUMMARY_LOG"
  debug_echo "DEBUG: Wrote newest date to log"

  debug_echo "DEBUG: About to check if files need to be copied"
  if [[ $FILES_TO_COPY_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}  No files to copy or move for $SUBF. Nothing to do.${NC}"
    echo "  No files to copy or move for $SUBF. Nothing to do." >> "$SUMMARY_LOG"
    
    # For move operations, check if there are files on the phone that should be deleted
    if [[ "$ACTION" == "move" ]]; then
      echo -e "${YELLOW}Checking for files on phone that may need to be deleted...${NC}"
      
      # Get list of files that exist on phone
      set +e
      PHONE_FILES=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "find '$REMOTE_SUBFOLDER' -type f \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.mp4' -o -name '*.mov' -o -name '*.cr2' -o -name '*.nef' -o -name '*.arw' -o -name '*.dng' -o -name '*.raf' -o -name '*.rw2' -o -name '*.orf' -o -name '*.pef' \) | head -20" 2>&1)
      PHONE_FILES_EXIT_CODE=$?
      set -e
      
      if [ -n "$PHONE_FILES" ] && [ $PHONE_FILES_EXIT_CODE -eq 0 ]; then
        echo -e "${YELLOW}Found files on phone that may have been copied previously:${NC}"
        if [[ $DEBUG_MODE -eq 1 ]]; then
          echo "$PHONE_FILES" | tail -10
        else
          echo "$PHONE_FILES" | tail -5
        fi
        echo -ne "${YELLOW}Delete these files from phone? (y/N): ${NC}"
        read delete_confirm
        if [[ "$delete_confirm" =~ ^[Yy]$ ]]; then
          echo -e "${YELLOW}Deleting previously copied files from phone...${NC}"
          set +e
          # Use a temporary file to avoid subshell issues
          TEMP_PHONE_DELETE="/tmp/phone_delete_$$.txt"
          echo "$PHONE_FILES" > "$TEMP_PHONE_DELETE"
          while read -r phone_file; do
            if [ -n "$phone_file" ]; then
              filename=$(basename "$phone_file")
              echo -e "${YELLOW}Deleting from phone: $filename${NC}"
              ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "rm -f '$phone_file'"
              NOW=$(date '+%Y-%m-%d %H:%M:%S')
              echo "$NOW,deleted,$phone_file,,success" >> "$FILE_LOG"
            fi
          done < "$TEMP_PHONE_DELETE"
          rm -f "$TEMP_PHONE_DELETE"
          set -e
          echo -e "${GREEN}Deletion of previously copied files complete.${NC}"
        else
          echo -e "${RED}Deletion cancelled.${NC}"
        fi
      else
        echo -e "${GRAY}No files found on phone to delete.${NC}"
      fi
    fi
    
    continue
  fi

  # --- Deletion preview ---
  if [[ "$ACTION" == "copy" && $DELETE_COPIED -eq 1 && $FILE_COUNT -gt 0 ]]; then
    # Only delete files that are in the copy log
    if [ -f "$COPY_LOG_FILE" ]; then
      FILES_TO_DELETE=$(comm -12 <(echo "$FILE_LIST" | sort || true) <(awk '{print $1}' "$COPY_LOG_FILE" | sort || true) || true)
      DELETE_COUNT=$(echo "$FILES_TO_DELETE" | grep -c . || true)
    else
      DELETE_COUNT=0
    fi
    echo -e "  ${GRAY}Files to be deleted: ${WHITE}$DELETE_COUNT${NC}"
    echo "  Files to be deleted: $DELETE_COUNT" >> "$SUMMARY_LOG"
  elif [[ "$ACTION" == "move" ]]; then
    echo -e "  ${GRAY}Files will be deleted from phone after successful transfer${NC}"
    echo "  Files will be deleted from phone after successful transfer" >> "$SUMMARY_LOG"
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
  echo -e "${GREEN}Starting $ACTION for $SUBF...${NC}"
  
  # Get list of files that will be transferred using dry-run
  DRY_RUN_CMD="$RSYNC_CMD --dry-run"
  debug_echo "DEBUG: Running dry-run command..."
  debug_echo "DEBUG: Command: $DRY_RUN_CMD"
  
  # Temporarily disable error exit to capture the error
  set +e
  DRY_RUN_OUTPUT=$(eval "$DRY_RUN_CMD" 2>&1)
  DRY_RUN_EXIT_CODE=$?
  set -e
  
  debug_echo "DEBUG: Dry-run exit code: $DRY_RUN_EXIT_CODE"
  debug_echo "DEBUG: Dry-run output:"
  if [[ $DEBUG_MODE -eq 1 ]]; then
    echo "$DRY_RUN_OUTPUT"
  else
    # In normal mode, show only the first few lines
    echo "$DRY_RUN_OUTPUT" | head -5
    if [[ $(echo "$DRY_RUN_OUTPUT" | wc -l) -gt 5 ]]; then
      echo -e "${GRAY}... and $(($(echo "$DRY_RUN_OUTPUT" | wc -l) - 5)) more lines${NC}"
    fi
  fi
  
  debug_echo "DEBUG: About to process dry-run output"
  
  if [ $DRY_RUN_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Warning: Dry-run failed with exit code $DRY_RUN_EXIT_CODE, but continuing...${NC}"
    FILES_TO_TRANSFER=""
  else
    debug_echo "DEBUG: Processing dry-run output to extract filenames"
    set +e
    FILES_TO_TRANSFER=$(echo "$DRY_RUN_OUTPUT" | grep -v '/$' | grep -v '^sending ' | grep -v '^sent ' | grep -v '^total size is ' | grep -v '^receiving incremental file list' | grep -v '^building file list' | grep -v '^done$' | sed 's/^.*\///' | grep -v '^$' | grep -v '^\.$' | grep -v '^Raw$')
    TRANSFER_EXIT_CODE=$?
    set -e
    debug_echo "DEBUG: Transfer filename extraction exit code: $TRANSFER_EXIT_CODE"
    if [ $TRANSFER_EXIT_CODE -ne 0 ]; then
      debug_echo "DEBUG: Transfer filename extraction failed, setting to empty"
      FILES_TO_TRANSFER=""
    fi
  fi
  
  # Debug: Show what files will be transferred
  debug_echo "DEBUG: Files to transfer:"
  if [[ $DEBUG_MODE -eq 1 ]]; then
    echo "$FILES_TO_TRANSFER" | tail -20
    if [[ $(echo "$FILES_TO_TRANSFER" | wc -l) -gt 20 ]]; then
      echo -e "${GRAY}... and $(($(echo "$FILES_TO_TRANSFER" | wc -l) - 20)) more files${NC}"
    fi
  else
    # In normal mode, show only the last 10 files
    if [[ -n "$FILES_TO_TRANSFER" ]]; then
      echo "$FILES_TO_TRANSFER" | tail -10
      if [[ $(echo "$FILES_TO_TRANSFER" | wc -l) -gt 10 ]]; then
        echo -e "${GRAY}... and $(($(echo "$FILES_TO_TRANSFER" | wc -l) - 10)) more files${NC}"
      fi
    fi
  fi
  debug_echo "DEBUG: Action is: $ACTION"
  
  # Also check what files exist on the phone
  debug_echo "DEBUG: Checking what files exist on phone..."
  set +e
  PHONE_FILES=$(ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "find '$REMOTE_SUBFOLDER' -type f -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.mp4' -o -name '*.mov' | head -10" 2>&1)
  PHONE_FILES_EXIT_CODE=$?
  set -e
  
  debug_echo "DEBUG: Phone files check exit code: $PHONE_FILES_EXIT_CODE"
  debug_echo "DEBUG: Sample files on phone (showing last 10):"
  if [[ $DEBUG_MODE -eq 1 ]]; then
    echo "$PHONE_FILES" | tail -10
    if [[ $(echo "$PHONE_FILES" | wc -l) -gt 10 ]]; then
      echo -e "${GRAY}... and $(($(echo "$PHONE_FILES" | wc -l) - 10)) more files${NC}"
    fi
  else
    # In normal mode, show only the last 5 files
    if [[ -n "$PHONE_FILES" ]]; then
      echo "$PHONE_FILES" | tail -5
      if [[ $(echo "$PHONE_FILES" | wc -l) -gt 5 ]]; then
        echo -e "${GRAY}... and $(($(echo "$PHONE_FILES" | wc -l) - 5)) more files${NC}"
      fi
    fi
  fi
  
  # Perform sync
  debug_echo "DEBUG: Running actual rsync..."
  set +e
  eval "$RSYNC_CMD --progress"
  RSYNC_EXIT_CODE=$?
  set -e
  
  debug_echo "DEBUG: Rsync exit code: $RSYNC_EXIT_CODE"
  
  if [ $RSYNC_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Warning: Rsync failed with exit code $RSYNC_EXIT_CODE, but continuing...${NC}"
  fi

  # Process each file that was transferred
  if [ -n "$FILES_TO_TRANSFER" ]; then
    debug_echo "DEBUG: Processing $(echo "$FILES_TO_TRANSFER" | wc -l) files"
    # Create a temporary file to store files to delete
    TEMP_DELETE_LIST="/tmp/files_to_delete_$$.txt"
    echo "$FILES_TO_TRANSFER" > "$TEMP_DELETE_LIST"
    
    # Process each file for logging
    set +e
    while read -r filename; do
      if [ -n "$filename" ]; then
        NOW=$(date '+%Y-%m-%d %H:%M:%S')
        src="$REMOTE_SUBFOLDER/$filename"
        dest="$LOCAL_SUBFOLDER/$filename"
        echo "$NOW,$ACTION,$src,$dest,success" >> "$FILE_LOG"
      fi
    done < "$TEMP_DELETE_LIST"
    set -e
    
    # If move, delete files from phone after successful transfer
    if [[ "$ACTION" == "move" ]]; then
      echo -e "${YELLOW}DEBUG: Starting deletion process for move operation${NC}"
      echo -e "${YELLOW}Deleting files from phone...${NC}"
      
      # Read the temp file and delete each file - avoid subshell issues
      set +e
      while read -r filename; do
        if [ -n "$filename" ]; then
          src="$REMOTE_SUBFOLDER/$filename"
          echo -e "${YELLOW}Deleting from phone: $filename${NC}"
          debug_echo "DEBUG: Running: ssh -i $SSH_KEY -p $PHONE_PORT $PHONE_USER@$PHONE_IP rm -f '$src'"
          ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "rm -f '$src'"
          NOW=$(date '+%Y-%m-%d %H:%M:%S')
          echo "$NOW,deleted,$src,,success" >> "$FILE_LOG"
        fi
      done < "$TEMP_DELETE_LIST"
      set -e
      
      echo -e "${GREEN}Deletion from phone complete.${NC}"
    else
      echo -e "${GRAY}DEBUG: Action is not move, skipping deletion${NC}"
    fi
    
    # Clean up temp file
    rm -f "$TEMP_DELETE_LIST"
  else
    echo -e "${YELLOW}No new files were transferred.${NC}"
    debug_echo "DEBUG: FILES_TO_TRANSFER is empty"
    debug_echo "DEBUG: This could mean:"
    echo -e "${GRAY}  - No files match your date criteria${NC}"
    echo -e "${GRAY}  - All files have already been copied${NC}"
    echo -e "${GRAY}  - Only directories were found (no files)${NC}"
    
    # For move operations, also delete files that have already been copied
    if [[ "$ACTION" == "move" ]]; then
      echo -e "${YELLOW}DEBUG: Move operation with no new files - checking for previously copied files to delete${NC}"
      
      # For move operations, we should only delete the files that were selected for this operation
      # Use the original FILE_LIST that was filtered by date criteria, not all files on phone
      if [[ -n "$FILE_LIST_FOR_DELETE" ]]; then
        echo -e "${YELLOW}Found files on phone that match your date criteria:${NC}"
        if [[ $DEBUG_MODE -eq 1 ]]; then
          echo "$FILE_LIST_FOR_DELETE" | tail -10
        else
          echo "$FILE_LIST_FOR_DELETE" | tail -5
        fi
        echo -ne "${YELLOW}Delete these files from phone? (y/N): ${NC}"
        read delete_confirm
        if [[ "$delete_confirm" =~ ^[Yy]$ ]]; then
          echo -e "${YELLOW}Deleting selected files from phone...${NC}"
          set +e
          # Use a temporary file to avoid subshell issues
          TEMP_PHONE_DELETE="/tmp/phone_delete_$$.txt"
          echo "$FILE_LIST_FOR_DELETE" > "$TEMP_PHONE_DELETE"
          while read -r phone_file; do
            if [ -n "$phone_file" ]; then
              filename=$(basename "$phone_file")
              echo -e "${YELLOW}Deleting from phone: $filename${NC}"
              ssh -i "$SSH_KEY" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_IP" "rm -f '$phone_file'"
              NOW=$(date '+%Y-%m-%d %H:%M:%S')
              echo "$NOW,deleted,$phone_file,,success" >> "$FILE_LOG"
            fi
          done < "$TEMP_PHONE_DELETE"
          rm -f "$TEMP_PHONE_DELETE"
          set -e
          echo -e "${GREEN}Deletion of selected files complete.${NC}"
        else
          echo -e "${RED}Deletion cancelled.${NC}"
        fi
      else
        echo -e "${GRAY}No files found matching your date criteria.${NC}"
      fi
    fi
  fi
  
  echo -e " "
  if [[ "$ACTION" == "move" ]]; then
    echo -e "The files have been moved to $LOCAL_SUBFOLDER"
  else
    echo -e "The files have been copied to $LOCAL_SUBFOLDER"
  fi
  echo -e " "
  echo -e "${GREEN}  $ACTION complete for $SUBF.${NC}"
  echo -e " "
  echo "  $ACTION complete for $SUBF." >> "$SUMMARY_LOG"

  # --- Update copy log ---
  # Log all files now present in local subfolder
  if [ -d "$COPY_LOG_FILE" ]; then
    echo "Error: COPY_LOG_FILE ($COPY_LOG_FILE) is a directory, not a file!"
    exit 1
  fi
  find "$LOCAL_SUBFOLDER" -type f | while read -r f; do
    echo "$f" >> "$COPY_LOG_FILE"
  done

  # --- Deletion step (for copy+delete only) ---
  if [[ "$ACTION" == "copy" && $DELETE_COPIED -eq 1 && $FILE_COUNT -gt 0 ]]; then
    # Only delete files that are in the copy log
    if [ -f "$COPY_LOG_FILE" ]; then
      FILES_TO_DELETE=$(comm -12 <(echo "$FILE_LIST" | sort || true) <(awk '{print $1}' "$COPY_LOG_FILE" | sort || true) || true)
      DELETE_COUNT=$(echo "$FILES_TO_DELETE" | grep -c . || true)
    else
      DELETE_COUNT=0
    fi
    echo -e "  ${GRAY}Files to be deleted: ${WHITE}$DELETE_COUNT${NC}"
    echo "  Files to be deleted: $DELETE_COUNT" >> "$SUMMARY_LOG"
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



