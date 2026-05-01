#!/usr/bin/env bash
# MariaDB Backup Script for Moodle
#   - Weekly full backups (uncompressed, kept hot)
#   - Daily incrementals (compressed)
#   - Compresses full backups older than $full_age_days
#   - Deletes fulls and incrementals older than $keep_full_days / $keep_inc_days
# Credentials live in $defaults_file (chmod 600), NOT on the command line.
set -euo pipefail

# -------- Config --------
backup_root="/var/backups/moodle/mariadb"
full_dir="$backup_root/full"
inc_dir="$backup_root/inc"
log_file="/var/log/mariadb_backup.log"
lock_file="/var/lock/mariadb_backup.lock"
defaults_file="/etc/mysql/mariabackup.cnf"
full_age_days=7        # rotate to new full when latest full is at least this old
keep_full_days=28      # delete fulls older than this
keep_inc_days=28       # delete incrementals older than this

# -------- Logging --------
mkdir -p "$(dirname "$log_file")"
exec > >(tee -a "$log_file") 2>&1

trap 'rc=$?; echo "[$(date -u +%FT%TZ)] ❌ Backup FAILED (exit $rc) at line $LINENO"; exit $rc' ERR
echo "=== [$(date -u +%FT%TZ)] Backup run started ==="

# -------- Single-instance lock --------
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another backup is already running; exiting."
  exit 0
fi

# -------- Sanity checks --------
if [[ ! -r "$defaults_file" ]]; then
  echo "❌ Missing or unreadable defaults file: $defaults_file"
  echo "   Expected format:"
  echo "     [client]"
  echo "     user=<backup_user>"
  echo "     password=<backup_password>"
  exit 1
fi
command -v mariabackup >/dev/null || { echo "❌ mariabackup not installed"; exit 1; }

# -------- Resources --------
cores=$(nproc)
parallel=$((cores > 1 ? cores - 1 : 1))
mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
# Cap at min(2 GiB, RAM/4) so backups don't starve the live DB
mem_quarter=$(( mem_kb * 1024 / 4 ))
mem_cap=$(( 2 * 1024 * 1024 * 1024 ))
mem_use=$(( mem_quarter < mem_cap ? mem_quarter : mem_cap ))

# -------- Compression --------
if command -v pigz >/dev/null 2>&1; then
  compress_cmd=(pigz -p "$parallel")
else
  compress_cmd=(gzip)
fi
ext="gz"

now=$(date +%s)
mkdir -p "$full_dir" "$inc_dir"

backup_cmd=(mariabackup
  --defaults-extra-file="$defaults_file"
  --backup
  --parallel="$parallel"
  --use-memory="$mem_use"
)

# -------- Pick base or take initial full --------
mapfile -t full_dirs < <(find "$full_dir" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#full_dirs[@]} -eq 0 ]]; then
  echo "No uncompressed full backup base found. Creating initial full backup..."
  ts=$(date +"%Y-%m-%d_%H-%M-%S")
  target="$full_dir/$ts"
  "${backup_cmd[@]}" --target-dir="$target"
  echo "[$(date -u +%FT%TZ)] ✅ Initial full backup complete: $target"
  exit 0
fi

latest_full="${full_dirs[-1]}"
latest_name=$(basename "$latest_full")
parsable=$(echo "$latest_name" | sed -E 's/_/ /; s/([0-9]{2})-([0-9]{2})-([0-9]{2})$/\1:\2:\3/')
latest_ts=$(date -d "$parsable" +%s)
age_days=$(( (now - latest_ts) / 86400 ))

ts=$(date +"%Y-%m-%d_%H-%M-%S")

if (( age_days >= full_age_days )); then
  echo "Latest full is $age_days days old — taking new full backup..."
  target="$full_dir/$ts"
  "${backup_cmd[@]}" --target-dir="$target"
  echo "[$(date -u +%FT%TZ)] ✅ Full backup complete: $target"
else
  echo "Latest full is $age_days days old — taking incremental against $latest_full..."
  target="$inc_dir/$ts"
  "${backup_cmd[@]}" --target-dir="$target" --incremental-basedir="$latest_full"
  echo "Compressing incremental..."
  if tar -cf - -C "$target" . | "${compress_cmd[@]}" > "$target.tar.$ext"; then
    rm -rf "$target"
    echo "[$(date -u +%FT%TZ)] ✅ Incremental backup complete: $target.tar.$ext"
  else
    echo "❌ Compression of incremental failed; leaving uncompressed dir at $target"
    rm -f "$target.tar.$ext"
    exit 1
  fi
fi

# -------- Retention --------
echo "Applying retention policy..."

# 1) Compress fulls older than $full_age_days; delete fulls older than $keep_full_days
mapfile -t fulls < <(find "$full_dir" -mindepth 1 -maxdepth 1 -type d | sort)
last_idx=$(( ${#fulls[@]} - 1 ))
for i in "${!fulls[@]}"; do
  (( i == last_idx )) && continue   # never touch the most recent base
  folder="${fulls[$i]}"
  fname=$(basename "$folder")
  fdate=${fname%%_*}
  fts=$(date -d "$fdate" +%s 2>/dev/null) || continue
  age=$(( (now - fts) / 86400 ))
  if (( age > keep_full_days )); then
    echo "  Deleting full backup older than $keep_full_days days: $folder"
    rm -rf "$folder"
  elif (( age > full_age_days )); then
    echo "  Compressing full backup older than $full_age_days days: $folder"
    if tar -cf - -C "$folder" . | "${compress_cmd[@]}" > "$folder.tar.$ext"; then
      rm -rf "$folder"
    else
      echo "  ⚠️ Compression failed, keeping uncompressed dir: $folder"
      rm -f "$folder.tar.$ext"
    fi
  fi
done

# 2) Delete compressed fulls older than $keep_full_days
while IFS= read -r f; do
  fname=$(basename "$f" ".tar.$ext")
  fdate=${fname%%_*}
  fts=$(date -d "$fdate" +%s 2>/dev/null) || continue
  age=$(( (now - fts) / 86400 ))
  if (( age > keep_full_days )); then
    echo "  Deleting compressed full older than $keep_full_days days: $f"
    rm -f "$f"
  fi
done < <(find "$full_dir" -mindepth 1 -maxdepth 1 -type f -name "*.tar.$ext")

# 3) Delete incrementals older than $keep_inc_days
while IFS= read -r f; do
  fname=$(basename "$f" ".tar.$ext")
  fdate=${fname%%_*}
  fts=$(date -d "$fdate" +%s 2>/dev/null) || continue
  age=$(( (now - fts) / 86400 ))
  if (( age > keep_inc_days )); then
    echo "  Deleting incremental older than $keep_inc_days days: $f"
    rm -f "$f"
  fi
done < <(find "$inc_dir" -mindepth 1 -maxdepth 1 -type f -name "*.tar.$ext")

echo "[$(date -u +%FT%TZ)] ✅ Retention complete"
echo "=== Backup run finished ==="
