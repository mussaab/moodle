#!/bin/bash
# Config
backup_root="/var/backups/moodle/mariadb"
full_dir="$backup_root/full"
inc_dir="$backup_root/inc"
tmp_restore="/tmp/mariadb_restore"
mkdir -p "$tmp_restore"

# --- Disk space check before backup ---

# Find latest full backup directory
latest_full=$(ls -td "$full_dir"/*/ 2>/dev/null | head -1)

if [ -n "$latest_full" ]; then
    # Calculate size of latest full backup in MB
    last_full_size=$(du -sm "$latest_full" | awk '{print $1}')

    # Get available space in backup target partition in MB
    available_space=$(df -Pm "$backup_dir" | awk 'NR==2 {print $4}')

    # Require double the size of last full backup
    required_space=$(( last_full_size * 2 ))

    if [ "$available_space" -lt "$required_space" ]; then
        echo "❌ Not enough disk space for a new backup."
        echo "   Required at least ${required_space}MB (2× last full backup size: ${last_full_size}MB)."
        echo "   Available: ${available_space}MB."
        exit 1
    fi
else
    echo "ℹ️ No previous full backup found, skipping space comparison."
fi

# Step 1: Find latest incremental backup
latest_inc=$(find "$inc_dir" -mindepth 1 -maxdepth 1 -type f -name "*.tar.gz" | sort | tail -n1)
echo "Latest incremental backup: $(basename "$latest_inc")"

# Step 2: List user databases from latest full backup
latest_full=$(find "$full_dir" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)
echo "Detecting user databases from latest full backup..."

db_array=()
index=1
for db_path in "$latest_full"/*; do
    db_name=$(basename "$db_path")
    if [[ -d "$db_path" && ! "$db_name" =~ ^(mysql|performance_schema|information_schema|sys)$ ]]; then
        echo "$index) $db_name"
        db_array+=("$db_name")
        ((index++))
    fi
done

if [ ${#db_array[@]} -eq 0 ]; then
    echo "No user databases found in the backup."
    exit 1
fi

read -p "Select the database to restore (number): " db_choice
selected_db="${db_array[$((db_choice - 1))]}"
echo "Selected database: $selected_db"

# Step 3: List restore points
echo "Available restore points:"
restore_points=()
index=1

for dir in $(find "$full_dir" -mindepth 1 -maxdepth 1 -type d | sort); do
    echo "$index) Full folder: $(basename "$dir")"
    restore_points+=("$dir")
    ((index++))
done

for file in $(find "$full_dir" -mindepth 1 -maxdepth 1 -type f -name "*.tar.gz" | sort); do
    echo "$index) Full archive: $(basename "$file")"
    restore_points+=("$file")
    ((index++))
done

for file in $(find "$inc_dir" -mindepth 1 -maxdepth 1 -type f -name "*.tar.gz" | sort); do
    echo "$index) Incremental archive: $(basename "$file")"
    restore_points+=("$file")
    ((index++))
done

read -p "Select restore point (number): " restore_choice
selected_restore="${restore_points[$((restore_choice - 1))]}"
echo "Selected restore point: $selected_restore"

# Step 4: Restore logic
if [ -d "$selected_restore" ]; then
    echo "Restoring from full backup folder..."
    systemctl stop mariadb
    mv /var/lib/mysql /var/lib/mysql.bak.$(date +%s)
    mariabackup --prepare --target-dir="$selected_restore"
    mariabackup --copy-back --target-dir="$selected_restore"
    chown -R mysql:mysql /var/lib/mysql
    systemctl start mariadb

elif [[ "$selected_restore" == *.tar.gz ]]; then
    extracted_dir="$tmp_restore/$(basename "$selected_restore" .tar.gz)"
    mkdir -p "$extracted_dir"
    echo "Extracting archive to $extracted_dir..."
    tar -xzf "$selected_restore" -C "$extracted_dir"

    if [[ "$selected_restore" == "$inc_dir"* ]]; then
        echo "Detected incremental backup. Finding base full backup..."

        inc_name=$(basename "$selected_restore" .tar.gz)
        formatted_ts=$(echo "$inc_name" | sed 's/_/ /; s/-/:/3; s/-/:/3')
        inc_ts=$(date -d "$formatted_ts" +%s)

        full_candidates=()
        for path in $(find "$full_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type f -name "*.tar.gz" \)); do
            name=$(basename "$path")
            name=${name%.tar.gz}
            formatted_name=$(echo "$name" | sed 's/_/ /; s/-/:/3; s/-/:/3')
            ts=$(date -d "$formatted_name" +%s 2>/dev/null)
            if [ "$ts" -le "$inc_ts" ]; then
                full_candidates+=("$ts:$path")
            fi
        done

        if [ ${#full_candidates[@]} -eq 0 ]; then
            echo "No matching full backup found for incremental."
            exit 1
        fi

        IFS=$'\n' sorted=($(sort -t: -k1 -n <<<"${full_candidates[*]}"))
        base_entry="${sorted[-1]}"
        base_path="${base_entry#*:}"

        if [[ "$base_path" == *.tar.gz ]]; then
            base_dir="$tmp_restore/$(basename "$base_path" .tar.gz)"
            mkdir -p "$base_dir"
            echo "Extracting base full backup archive to $base_dir..."
            tar -xzf "$base_path" -C "$base_dir"
        else
            base_dir="$base_path"
        fi

        echo "Preparing full backup..."
        mariabackup --prepare --target-dir="$base_dir"
        echo "Applying incremental backup..."
        mariabackup --prepare --target-dir="$base_dir" --incremental-dir="$extracted_dir"

        echo "Stopping MariaDB and restoring..."
        systemctl stop mariadb
        mv /var/lib/mysql /var/lib/mysql.bak.$(date +%s)
        mariabackup --copy-back --target-dir="$base_dir"
        chown -R mysql:mysql /var/lib/mysql
        systemctl start mariadb

    else
        echo "Restoring from extracted full backup..."
        systemctl stop mariadb
        mv /var/lib/mysql /var/lib/mysql.bak.$(date +%s)
        mariabackup --prepare --target-dir="$extracted_dir"
        mariabackup --copy-back --target-dir="$extracted_dir"
        chown -R mysql:mysql /var/lib/mysql
        systemctl start mariadb
    fi
else
    echo "Invalid restore point selected."
    exit 1
fi

echo "✅ Restore completed successfully."
