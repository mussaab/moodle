#!/usr/bin/env bash
# MariaDB Restore Script for Moodle (instance-level restore)
#
# Discovers all available restore points (uncompressed full dirs, compressed
# full archives, and compressed incrementals), lets the operator pick one,
# builds the correct prepare chain (base full + every incremental up to and
# including the chosen point), and copies the data back into /var/lib/mysql.
#
# All staging happens under $tmp_root — original backups are never modified.
set -euo pipefail

# -------- Config --------
backup_root="/var/backups/moodle/mariadb"
full_dir="$backup_root/full"
inc_dir="$backup_root/inc"
tmp_root="/var/tmp/mariadb_restore"      # /var/tmp survives reboots and isn't tmpfs
defaults_file="/etc/mysql/mariabackup.cnf"
keep_old_datadirs=3                      # keep last N /var/lib/mysql.bak.*

# -------- Sanity --------
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi
command -v mariabackup >/dev/null || { echo "❌ mariabackup not installed"; exit 1; }
[[ -r "$defaults_file" ]] || { echo "❌ Missing or unreadable defaults file: $defaults_file"; exit 1; }
mkdir -p "$tmp_root" "$full_dir" "$inc_dir"

# -------- Helpers --------
ts_to_epoch() {
  # "YYYY-MM-DD_HH-MM-SS" → epoch seconds (returns nonzero if unparsable)
  local s="$1"
  s=$(echo "$s" | sed -E 's/_/ /; s/([0-9]{2})-([0-9]{2})-([0-9]{2})$/\1:\2:\3/')
  date -d "$s" +%s 2>/dev/null
}

stage() {
  # Copy/extract $1 into a fresh dir under $tmp_root, echo the path on stdout.
  # Logs to stderr so command substitution captures only the path.
  local src="$1"
  local name; name=$(basename "$src")
  name=${name%.tar.gz}
  local out="$tmp_root/$name"
  rm -rf "$out"
  mkdir -p "$out"
  if [[ -f "$src" ]]; then
    echo "Extracting $src ..." >&2
    tar -xzf "$src" -C "$out"
  else
    echo "Copying $src to scratch ..." >&2
    cp -a "$src/." "$out/"
  fi
  echo "$out"
}

# -------- Discover restore points --------
declare -a rp_paths rp_labels rp_epochs

while IFS= read -r d; do
  fname=$(basename "$d")
  ep=$(ts_to_epoch "$fname") || continue
  rp_paths+=("$d");   rp_labels+=("Full (dir):     $fname");     rp_epochs+=("$ep")
done < <(find "$full_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

while IFS= read -r f; do
  fname=$(basename "$f" .tar.gz)
  ep=$(ts_to_epoch "$fname") || continue
  rp_paths+=("$f");   rp_labels+=("Full (archive): $fname");     rp_epochs+=("$ep")
done < <(find "$full_dir" -mindepth 1 -maxdepth 1 -type f -name "*.tar.gz" 2>/dev/null | sort)

while IFS= read -r f; do
  fname=$(basename "$f" .tar.gz)
  ep=$(ts_to_epoch "$fname") || continue
  rp_paths+=("$f");   rp_labels+=("Incremental:    $fname");     rp_epochs+=("$ep")
done < <(find "$inc_dir" -mindepth 1 -maxdepth 1 -type f -name "*.tar.gz" 2>/dev/null | sort)

if [[ ${#rp_paths[@]} -eq 0 ]]; then
  echo "❌ No backups found in $backup_root."
  exit 1
fi

echo "Available restore points:"
for i in "${!rp_paths[@]}"; do
  printf "  %d) %s\n" $((i+1)) "${rp_labels[$i]}"
done

# -------- Selection + validation --------
read -rp "Select restore point (number): " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#rp_paths[@]} )); then
  echo "❌ Invalid selection."
  exit 1
fi
idx=$((choice - 1))
selected_path="${rp_paths[$idx]}"
selected_epoch="${rp_epochs[$idx]}"
selected_label="${rp_labels[$idx]}"
echo "Selected: $selected_label"

# -------- Build prepare chain --------
# A full = chain of length 1.
# An incremental = base full + every incremental in (base..selected], in order.
declare -a chain_paths chain_kinds

if [[ "$selected_label" == Incremental:* ]]; then
  base_path=""; base_epoch=0
  for i in "${!rp_paths[@]}"; do
    [[ "${rp_labels[$i]}" == Full* ]] || continue
    ep="${rp_epochs[$i]}"
    if (( ep <= selected_epoch && ep >= base_epoch )); then
      base_path="${rp_paths[$i]}"
      base_epoch=$ep
    fi
  done
  if [[ -z "$base_path" ]]; then
    echo "❌ No full backup found at or before the selected incremental."
    exit 1
  fi
  chain_paths+=("$base_path"); chain_kinds+=("full")

  for i in "${!rp_paths[@]}"; do
    [[ "${rp_labels[$i]}" == Incremental:* ]] || continue
    ep="${rp_epochs[$i]}"
    if (( ep > base_epoch && ep <= selected_epoch )); then
      chain_paths+=("${rp_paths[$i]}"); chain_kinds+=("inc")
    fi
  done
else
  chain_paths+=("$selected_path"); chain_kinds+=("full")
fi

echo
echo "Restore chain:"
for i in "${!chain_paths[@]}"; do
  echo "  - [${chain_kinds[$i]}] ${chain_paths[$i]}"
done

# -------- Confirmation --------
cat <<EOF

⚠️  WARNING: This will:
   1. Stop MariaDB
   2. Move /var/lib/mysql to /var/lib/mysql.bak.<timestamp>
   3. Restore the entire instance (ALL databases) from the chain above
   4. Start MariaDB

NOTE: mariabackup operates at instance level — every database in the backup
      will be restored, not just one.

Type EXACTLY 'YES' to continue.
EOF
read -r confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

# -------- Stage chain --------
echo "Cleaning scratch dir $tmp_root ..."
rm -rf "$tmp_root"
mkdir -p "$tmp_root"

base_dir=$(stage "${chain_paths[0]}")

declare -a staged_incs=()
for ((i=1; i<${#chain_paths[@]}; i++)); do
  staged_incs+=("$(stage "${chain_paths[$i]}")")
done

# -------- Prepare chain --------
mb=(mariabackup --defaults-extra-file="$defaults_file")

if (( ${#staged_incs[@]} == 0 )); then
  echo "Preparing base (final)..."
  "${mb[@]}" --prepare --target-dir="$base_dir"
else
  echo "Preparing base (apply-log-only)..."
  "${mb[@]}" --prepare --apply-log-only --target-dir="$base_dir"

  last_idx=$(( ${#staged_incs[@]} - 1 ))
  for i in "${!staged_incs[@]}"; do
    if (( i == last_idx )); then
      echo "Applying incremental $((i+1))/${#staged_incs[@]} (final): ${staged_incs[$i]}"
      "${mb[@]}" --prepare --target-dir="$base_dir" --incremental-dir="${staged_incs[$i]}"
    else
      echo "Applying incremental $((i+1))/${#staged_incs[@]} (apply-log-only): ${staged_incs[$i]}"
      "${mb[@]}" --prepare --apply-log-only --target-dir="$base_dir" --incremental-dir="${staged_incs[$i]}"
    fi
  done
fi

# -------- Stop MariaDB and copy back --------
echo "Stopping MariaDB..."
systemctl stop mariadb

bak=""
if [[ -d /var/lib/mysql ]]; then
  bak="/var/lib/mysql.bak.$(date +%s)"
  echo "Moving existing /var/lib/mysql to $bak ..."
  mv /var/lib/mysql "$bak"
fi

echo "Restoring data files..."
"${mb[@]}" --copy-back --target-dir="$base_dir"
chown -R mysql:mysql /var/lib/mysql

echo "Starting MariaDB..."
systemctl start mariadb

# -------- Cleanup older datadir backups --------
mapfile -t old_dirs < <(ls -dt /var/lib/mysql.bak.* 2>/dev/null || true)
if (( ${#old_dirs[@]} > keep_old_datadirs )); then
  for ((i=keep_old_datadirs; i<${#old_dirs[@]}; i++)); do
    echo "Pruning old datadir backup: ${old_dirs[$i]}"
    rm -rf "${old_dirs[$i]}"
  done
fi

echo "✅ Restore completed successfully."
[[ -n "$bak" ]] && echo "ℹ️  Previous datadir saved at: $bak"
echo "ℹ️  Scratch staging dir: $tmp_root (safe to delete)"
