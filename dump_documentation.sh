#!/bin/bash
# Script to dump all relevant project files for documentation

echo "=== SSH PHONE PROJECT DOCUMENTATION DUMP ==="
echo ""
echo "This dump contains all relevant files for the sshphone project."
echo "Copy everything below this line to your Anthropic workbench."
echo ""
echo "================================================"
echo ""

# Main scripts
echo "=== copy_from_device_to_comp.sh ==="
cat copy_from_device_to_comp.sh
echo ""
echo "=== END copy_from_device_to_comp.sh ==="
echo ""

echo "=== delete_previously_copied_photos.sh ==="
cat delete_previously_copied_photos.sh
echo ""
echo "=== END delete_previously_copied_photos.sh ==="
echo ""

echo "=== update_imported_to_lightroom_hashes.sh ==="
cat update_imported_to_lightroom_hashes.sh
echo ""
echo "=== END update_imported_to_lightroom_hashes.sh ==="
echo ""

# Configuration
echo "=== config.conf ==="
cat config.conf
echo ""
echo "=== END config.conf ==="
echo ""

# Documentation
echo "=== readme.md ==="
cat readme.md
echo ""
echo "=== END readme.md ==="
echo ""

echo "=== LOG_FILES_GUIDE.md ==="
cat LOG_FILES_GUIDE.md
echo ""
echo "=== END LOG_FILES_GUIDE.md ==="
echo ""

echo "=== MY_PREFERENCES.md ==="
cat MY_PREFERENCES.md
echo ""
echo "=== END MY_PREFERENCES.md ==="
echo ""

# Log files (if they exist)
echo "=== device_sync_log_2025.csv (first 20 lines) ==="
if [ -f device_sync_log_2025.csv ]; then
    head -20 device_sync_log_2025.csv
else
    echo "File does not exist"
fi
echo ""
echo "=== END device_sync_log_2025.csv ==="
echo ""

echo "=== device_copied_hashes.txt (first 20 lines) ==="
if [ -f device_copied_hashes.txt ]; then
    head -20 device_copied_hashes.txt
else
    echo "File does not exist"
fi
echo ""
echo "=== END device_copied_hashes.txt ==="
echo ""

# Project structure
echo "=== PROJECT STRUCTURE ==="
find . -type f -name "*.sh" -o -name "*.conf" -o -name "*.md" -o -name "*.csv" -o -name "*.txt" | grep -v ".git" | sort
echo ""
echo "=== END PROJECT STRUCTURE ==="
echo ""

echo "=== END OF DOCUMENTATION DUMP ===" 