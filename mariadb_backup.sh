#!/bin/bash
# MariaDB Backup Script - One uncompressed full backup + compressed incrementals

# Config
backup_root="/var/backups/moodle/mariadb"
full_dir="$backup_root/full"
inc_dir="$backup_root/inc"
user="Backup_Username"
password="Backup_User_Password"

# System resources to use
cores=$(nproc)
parallel=$((cores > 1 ? cores - 1 : 1))
mem_kb=$(free -k | awk '/Mem:/ {print $2}')
mem_bytes=$((mem_kb * 1024))
mem_use=$((mem_bytes / 2))

# Compression command
if command -v pigz &> /dev/null; then
    compress_cmd="pigz -p $parallel"
    ext="gz"
else
    compress_cmd="gzip"
    ext="gz"
fi

# Get current time
now=$(date +%s)

# Ensure backup directories exist
mkdir -p "$full_dir" "$inc_dir"

# Find all full backup folders
folders=($(find "$full_dir" -mindepth 1 -maxdepth 1 -type d | sort))

# If no backups exist, create a full backup
if [ ${#folders[@]} -eq 0 ]; then
    echo "No full backups found. Creating initial full backup..."
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    target="$full_dir/$timestamp"
    mariabackup --backup --target-dir="$target" --user="$user" --password="$password" \
        --parallel=$parallel --use-memory=$mem_use
    exit 0
fi

# Keep only the oldest full backup from today
today=$(date +%Y-%m-%d)
today_folders=($(find "$full_dir" -mindepth 1 -maxdepth 1 -type d -name "${today}_*" | sort))
if [ ${#today_folders[@]} -gt 1 ]; then
    echo "Cleaning up extra full backups from today..."
    for ((i=1; i<${#today_folders[@]}; i++)); do
        echo "Deleting: ${today_folders[$i]}"
        rm -rf "${today_folders[$i]}"
    done
fi

# Get latest full backup folder
latest=$(find "$full_dir" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n1)
folder=$(basename "$latest")

# Convert folder name to datetime
datetime=$(echo "$folder" | sed -E 's/_/ /; s/([0-9]{2})-([0-9]{2})-([0-9]{2})$/\1:\2:\3/')
timestamp=$(date -d "$datetime" +%s)
age=$(( (now - timestamp) / 86400 ))

# Decide backup type
if [ "$age" -ge 7 ]; then
    echo "Latest full backup is $age days old. Creating new full backup..."
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    target="$full_dir/$timestamp"
    mariabackup --backup --target-dir="$target" --user="$user" --password="$password" \
        --parallel=$parallel --use-memory=$mem_use
else
    echo "Latest full backup is $age days old. Creating incremental backup based on $latest..."
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    target="$inc_dir/$timestamp"
    mariabackup --backup \
      --target-dir="$target" \
      --incremental-basedir="$latest" \
      --user="$user" --password="$password" \
      --parallel=$parallel --use-memory=$mem_use

    # Compress and delete incremental backup
    echo "Compressing incremental backup..."
    tar -cf - -C "$target" . | $compress_cmd > "$target.tar.$ext"
    rm -rf "$target"
    echo "Incremental backup compressed and original deleted."
fi
# Clean up full backups
echo "Cleaning up full backups..."
full_folders=($(find "$full_dir" -mindepth 1 -maxdepth 1 -type d | sort))
latest_full="${full_folders[-1]}"

for folder in "${full_folders[@]}"; do
    if [ "$folder" != "$latest_full" ]; then
        folder_name=$(basename "$folder")
        folder_date=$(echo "$folder_name" | cut -d'_' -f1)
        folder_timestamp=$(date -d "$folder_date" +%s)
        age_days=$(( (now - folder_timestamp) / 86400 ))

        if [ "$age_days" -gt 28 ]; then
            echo "Deleting old full backup: $folder ($age_days days old)"
            rm -rf "$folder"
        elif [ "$age_days" -gt 7 ]; then
            echo "Compressing full backup: $folder ($age_days days old)"
            tar -cf - -C "$folder" . | $compress_cmd > "$folder.tar.$ext"
            rm -rf "$folder"
        fi
    fi
done
