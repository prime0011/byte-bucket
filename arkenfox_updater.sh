#!/usr/bin/env bash

# Arkenfox Installer & Updater with Uninstall Support
# Usage:
#   arkenfox --install [--nogui] [--debug]
#   arkenfox --update [--debug]
#   arkenfox --uninstall [--debug]
# Optional:
#   --nogui : Skip Automator Quick Action setup
#   --debug : Enable debug mode output to terminal

# Exit on error, undefined variables, or failed pipes
set -euo pipefail

#########################
## Configuration
#########################

# Set directories for Arkenfox installation, logs, and user data
readonly ARKENFOX_DIR="$HOME/Library/Application Support/arkenfox"
readonly REPO_DIR="$ARKENFOX_DIR/user.js"
readonly LOG_DIR="$ARKENFOX_DIR/logs"
readonly AUTOMATOR_WORKFLOW="$HOME/Library/Services/Run Arkenfox Updater.workflow"
readonly PLIST_NAME="com.arkenfox.updater"
readonly LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
readonly GIT_MARKER="$ARKENFOX_DIR/.clt-installed"

# Files to back up (user.js, prefs.js)
readonly FILES_TO_BACKUP=("user.js" "prefs.js")

# Determine overrides file path (can be overridden via env var or CLI)
readonly USER_OVERRIDES="${OVERRIDES_FILE:-${ARKENFOX_OVERRIDES:-$ARKENFOX_DIR/user-overrides.js}}"

#########################
## Argument Parsing
#########################

# Initialize variables (no need for readonly here as they will change)
MODE=""
NO_GUI=0
DEBUG_MODE=0
AUTO_UPDATE_MODE=0

# Pre-scan for --debug so debug() output works during argument parsing
for arg in "$@"; do
  [[ "$arg" == "--debug" ]] && DEBUG_MODE=1 && break
done

# Function to display help message
print_help() {
  cat <<EOF
Arkenfox Installer & Updater with Uninstall Support

Usage:
  arkenfox --install [--nogui] [--debug]     Install Arkenfox (with optional no GUI automator and debug)
  arkenfox --update [--debug]                Update Arkenfox configuration
  arkenfox --auto-update [--debug]           Auto-run update (typically used in automated setups)
  arkenfox --uninstall [--debug]             Uninstall Arkenfox completely
  arkenfox --help                            Show this help message

Options:
  --nogui       Skip installing Automator Quick Action (useful for headless setups)
  --debug       Enable debug output to terminal
  --auto-update Run update automatically (no interactive prompts)

Requirements:
  - Firefox installed with at least one profile launched once
  - Xcode Command Line Tools (will be installed if missing)
  - Git (included in CLT on macOS; if missing, install via Homebrew or https://git-scm.com/)

Notes:
  - Installer will attempt to install Command Line Tools if missing
  - User configs are backed up automatically
  - Automator Quick Action can be skipped with --nogui

EOF
}

# Debug function: Outputs debug messages if DEBUG_MODE is enabled
debug() {
  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message"
  fi
}

# Output debug message about argument parsing
debug "🔍 [DEBUG] Parsing arguments..."

# Parse command-line arguments
for arg in "$@"; do
  debug "🔍 [DEBUG] Processing argument '$arg'..."
  case "$arg" in
    --install) MODE="install" ;;
    --update) MODE="update" ;;
    --auto-update) MODE="update"; AUTO_UPDATE_MODE=1 ;;  
    --uninstall) MODE="uninstall" ;;
    --nogui) NO_GUI=1 ;;
    --debug) DEBUG_MODE=1 ;;  # Already set by pre-scan, harmless
    --help|-h) print_help; exit 0 ;;
    *) echo "❌ [ERROR] Unknown argument: '$arg'."; print_help; exit 1 ;;
  esac
done

# If no mode was specified, display an error and show help
if [[ -z "$MODE" ]]; then
  echo "❌ [ERROR] No mode specified."
  print_help
  exit 1
fi

# Output final debug state after parsing arguments
debug "🔍 [DEBUG] After argument parsing: MODE='$MODE', NO_GUI='$NO_GUI', DEBUG_MODE='$DEBUG_MODE'."
 #########################
## Utility Functions
#########################

# Case-insensitive lowercase fallback for macOS Bash 3.2
to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Exit with an error message
error_exit() {
  local message="$1"  

  # Output the error message to stderr (console)
  echo "$message" >&2  

  # Log the error message to the log file
  log "$message"       

  exit 1
}

# Log function to append log messages to a file and output to console
log() {
  local message="$1"

  # Append message to the log file with timestamp
  mkdir -p "$LOG_DIR"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_DIR/arkenfox.log"
}

# Output message to console if in terminal mode and always write to log
info() {
  local msg="$1"
  if [[ "$AUTO_UPDATE_MODE" != "1" ]]; then
    echo "$msg"
  fi
  log "$msg"
}

# Notify function to send macOS notifications and log events
notify() {
  local msg="$1"
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$msg\" with title \"Arkenfox Updater\""
  fi
  # Log the message with timestamp
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

# Rotate logs if they exceed 1MB in size
rotate_log() {
  debug "🔍 [DEBUG] Checking log rotation..."  

  local files_to_check=("$LOG_DIR/arkenfox.log" "$LOG_DIR/arkenfox-launchd.log")

  for log_file in "${files_to_check[@]}"; do
    if [[ ! -f "$log_file" ]]; then
      debug "🔍 [DEBUG] No $log_file file to rotate."  # No file found
      continue
    fi

    local file_size
    file_size=$(stat -f%z "$log_file")
    debug "🔍 [DEBUG] Log size for $log_file is $file_size bytes."  # File size info

    if (( file_size > 1048576 )); then
      mv "$log_file" "$log_file.$(date +%Y%m%d%H%M%S)"
      log "🔄 [ACTION] Rotated log: $log_file."  # Log the rotation action
      echo "🔄 [ACTION] Rotated log: $log_file."  # Output to console separately
    fi
  done
}

# Take a system snapshot for diagnostic purposes
system_snapshot() {
  local snapshot_label="$1"
  
  debug "🔍 [DEBUG] Taking system snapshot: $snapshot_label"

  # Ensure snapshots directory exists, error_exit on failure
  if ! mkdir -p "$LOG_DIR/snapshots"; then
    error_exit "❌ [ERROR] Failed to create snapshots directory at $LOG_DIR/snapshots."
  fi

  log "🔄 [ACTION] === $snapshot_label system snapshot at $(date) ==="

  # Redirect output to snapshot file, error_exit if writing fails
  if ! {
    sw_vers
    echo "Disk Usage:"
    df -h /
    echo "Memory:"
    if ! vm_stat; then
      echo "vm_stat failed"
    fi
    echo "Processes:"
    ps aux | head -20
    echo
  } >> "$LOG_DIR/snapshots/$snapshot_label.txt"; then
    error_exit "❌ [ERROR] Failed to write system snapshot to $LOG_DIR/snapshots/$snapshot_label.txt."
  fi

  log "✅ [SUCCESS] System snapshot '$snapshot_label' completed and saved."
}

# Check if Xcode Command Line Tools are installed
check_clt() {
  debug "🔍 [DEBUG] Checking Xcode Command Line Tools..."

  if ! pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; then
    info "🔄 [ACTION] Installing Xcode Command Line Tools..."
    debug "🔍 [DEBUG] Xcode Command Line Tools not found, initiating installation..."

    # Setup trap early to catch SIGINT during wait
    trap 'echo; error_exit "🚨 [CRITICAL] Installation interrupted by user."' SIGINT

    set +e
    xcode-select --install 2>/dev/null || true
    set -e

    local tries=0
    local max_tries="${MAX_TRIES:-20}"
    local wait_sec="${WAIT_SEC:-15}"

    echo -n "🔄 [ACTION] Waiting for Command Line Tools installation"

    while ! pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; do
      (( tries++ ))

      if (( tries >= max_tries )); then
        echo
        error_exit "❌ [ERROR] Timed out waiting for Xcode Command Line Tools installation. Please install manually and rerun."
      fi

      if (( tries == 4 )); then
        echo
        info "⚠️ [WARNING] Reminder: If you see a popup asking to install Command Line Tools, please confirm it."
        info "⚠️ [WARNING] Please confirm the installer popup to continue installation."
        echo -n "🔄 [ACTION] Waiting for Command Line Tools installation"
      fi

      echo -n ". (${tries}/${max_tries}, ~ $((tries * wait_sec))s elapsed)"
      sleep "$wait_sec"
    done

    echo
    info "✅ [SUCCESS] Command Line Tools installation complete."

    sudo xcode-select --switch /Library/Developer/CommandLineTools

    touch "$GIT_MARKER"
    debug "🔍 [DEBUG] Xcode Command Line Tools installed successfully."

    # Reset trap after install
    trap - SIGINT  
  else
    log "ℹ️ [INFO] Xcode Command Line Tools already installed."
    debug "🔍 [DEBUG] Xcode Command Line Tools already installed."
  fi
}

# Check if Git is installed
check_git() {
  debug "🔍 [DEBUG] Checking for git command..."

  if ! command -v git &>/dev/null; then
    error_exit "❌ [ERROR] Git is not installed. Please install Git via Homebrew (brew install git) or from https://git-scm.com"
  fi

  log "✅ [SUCCESS] Git is installed."
}

# Find the Firefox default profile directory
find_profile() {
  debug "🔍 [DEBUG] Searching for Firefox default-release profile..."

  local firefox_profile_dir
  firefox_profile_dir=$(find "$HOME/Library/Application Support/Firefox/Profiles" -type d -name "*.default-release" 2>/dev/null | head -n 1)

  if [[ -z "$firefox_profile_dir" ]]; then
    error_exit "❌ [ERROR] Could not find Firefox default-release profile. Launch Firefox at least once."
  fi

  # Return the profile path silently
  echo "$firefox_profile_dir"
}

# Backup Firefox configuration files
backup_firefox_config() {
  local user_profile_dir="$1"
  debug "🔍 [DEBUG] Backing up Firefox configuration from $user_profile_dir."

  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)

  local backup_directory="$LOG_DIR/backups/$timestamp"
  mkdir -p "$backup_directory"

  local backup_manifest_file="$backup_directory/manifest.txt"

  # Write header information to manifest
  {
    echo "# Firefox backup created on $(date)"
    echo "# Profile: $user_profile_dir"
    echo ""
  } > "$backup_manifest_file"

  for file in "${FILES_TO_BACKUP[@]}"; do
    if [[ -f "$user_profile_dir/$file" ]]; then
      if cp "$user_profile_dir/$file" "$backup_directory/"; then
        info "✅ [SUCCESS] Successfully backed up $file from $user_profile_dir."
        echo "$file" >> "$backup_manifest_file"
      else
        info "❌ [ERROR] Failed to back up $file from $user_profile_dir."
      fi
    else
      debug "🔍 [DEBUG] The file $file does not exist. Skipping backup."
    fi
  done

  info "ℹ️ [INFO] Backup directory created: $backup_directory"
  echo "$backup_directory" > "$ARKENFOX_DIR/.last-backup"
}

# Restore Firefox backup if possible
restore_firefox_backup() {
  if pgrep -x "firefox" >/dev/null; then
    info "⚠️ [WARNING] Firefox is currently running. Please close it before restoring the backup."
    exit 1
  fi

  # Determine the user profile directory
  local user_profile_dir
  if ! user_profile_dir=$(find_profile); then
    error_exit "❌ [ERROR] Could not locate the Firefox profile directory. Aborting restore."
  fi
  debug "🔍 [DEBUG] Restoring Firefox backup to profile $user_profile_dir."

  # Find the latest backup directory
  local backup_directory
  backup_directory=$(ls -td "$LOG_DIR/backups/"*/ 2>/dev/null | head -1 || true)

  if [[ -z "$backup_directory" ]]; then
    info "ℹ️ [INFO] No backup directory found. Skipping restore."
    return
  fi

  local backup_manifest_file="$backup_directory/manifest.txt"

  if [[ ! -f "$backup_manifest_file" ]]; then
    info "ℹ️ [INFO] No manifest file found in backup. Skipping restore."
    return
  fi

  info "🔄 [ACTION] Restoring Firefox backup from: $backup_directory"

  # Iterate over the files listed in the manifest file
  while IFS= read -r file; do
    [[ "$file" =~ ^#.*$ || -z "$file" ]] && continue  # Skip comment or empty lines

    if [[ -f "$backup_directory/$file" ]]; then
      if [[ "$file" == "prefs.js" ]]; then
        info "⚠️ [WARNING] prefs.js is about to be restored from backup."
        read -rp "📝 [COMMAND] Restore prefs.js from backup? [y/N]: " user_confirmation_restore
        user_confirmation_restore=$(to_lower "$user_confirmation_restore")
        if [[ "$user_confirmation_restore" != "y" && "$user_confirmation_restore" != "yes" ]]; then
          info "ℹ️ [INFO] User declined to restore prefs.js; restoration skipped."
          continue
        fi
      fi
      cp "$backup_directory/$file" "$user_profile_dir/$file"
      info "✅ [SUCCESS] Restored $file to $user_profile_dir from backup."
    else
      info "⚠️ [WARNING] $file listed in manifest but not found in backup."
    fi
  done < "$backup_manifest_file"

  # Remove any files from the profile that weren't backed up
  for file in "${FILES_TO_BACKUP[@]}"; do
    if ! grep -qx "$file" "$backup_manifest_file" && [[ -f "$user_profile_dir/$file" ]]; then
      rm -f "$user_profile_dir/$file"
      info "⚠️ [WARNING] Removed $file from profile because it was not found in the backup."
    fi
  done
}

# Merge user.js and user-overrides.js, returning the merged file path
merge_userjs() {
  local user_profile_dir="$1"
  local user_profile_js_path="$user_profile_dir/user.js"
  local merge_conflicts_file="$LOG_DIR/merge-conflicts.log"
  local temp_merge_file
  temp_merge_file=$(mktemp)

  mkdir -p "$LOG_DIR"
  info "ℹ️ [INFO] Merging Arkenfox user.js with overrides..."

  # Clear previous merge logs or conflict files
  rm -f "$LOG_DIR"/{overrides.txt,conflicts.txt,"$merge_conflicts_file"}

  # Extract preference keys from the base user.js and sort them
  grep '^user_pref' "$REPO_DIR/user.js" | sed -E 's/user_pref\("([^"]+)",.*/\1/' | sort > "$LOG_DIR/base.txt"

  # If overrides file exists, process it
  if [[ -f "$USER_OVERRIDES" ]]; then
    debug "🔍 [DEBUG] Processing user-overrides.js for conflicts..."

    # Extract preference keys from the overrides file and sort them
    grep '^user_pref' "$USER_OVERRIDES" | sed -E 's/user_pref\("([^"]+)",.*/\1/' | sort > "$LOG_DIR/overrides.txt"

    # Detect conflicts (overlapping keys)
    comm -12 "$LOG_DIR/base.txt" "$LOG_DIR/overrides.txt" > "$LOG_DIR/conflicts.txt"

    if [[ -s "$LOG_DIR/conflicts.txt" ]]; then
      cp "$LOG_DIR/conflicts.txt" "$merge_conflicts_file"
      info "⚠️ [WARNING] Conflict(s) detected between user.js and user-overrides.js. Conflicting preferences saved to: $merge_conflicts_file"
    else
      info "ℹ️ [INFO] No conflicts detected between user.js and user-overrides.js."
    fi

    # Merge base and overrides into a temporary file
    cat "$REPO_DIR/user.js" "$USER_OVERRIDES" > "$temp_merge_file"
  else
    info "ℹ️ [INFO] No user-overrides.js file found — using base user.js only."
    cat "$REPO_DIR/user.js" > "$temp_merge_file"
  fi

  debug "🔍 [DEBUG] Merged user.js written to temporary file: $temp_merge_file"

  # Output the merged file path
  echo "$temp_merge_file"
}

# Show differences between current and merged user.js, asking for confirmation to apply changes
show_diff_and_confirm() {
  local profile_user_js_path="$1/user.js"
  local merged_user_js_path="$2"
  local user_confirmation

  # Check if diff is available
  if ! command -v diff >/dev/null 2>&1; then
    info "⚠️ [WARNING] 'diff' command not found. Skipping difference display."
    return 0
  fi

  # If no existing user.js, nothing to compare — just inform
  if [[ ! -f "$profile_user_js_path" ]]; then
    info "ℹ️ [INFO] No existing user.js found — a new one will be created."
    return 0
  fi

  # If no differences, skip prompt
  if cmp -s "$profile_user_js_path" "$merged_user_js_path"; then
    debug "🔍 [DEBUG] No differences between current and merged user.js."
    return 0
  fi

  # Show unified diff using less (if terminal attached)
  info "ℹ️ [INFO] Showing changes between current and updated user.js:"
  echo "--------------------------------------------------"
  diff -u "$profile_user_js_path" "$merged_user_js_path" | less -R || true
  echo "--------------------------------------------------"
  echo

  # Prompt user for confirmation
  read -rp "📝 [COMMAND] Apply these changes to user.js? [y/N]: " user_confirmation
  user_confirmation=$(to_lower "$user_confirmation")

  if [[ "$user_confirmation" == "y" || "$user_confirmation" == "yes" ]]; then
    info "✅ [SUCCESS] Changes confirmed — user.js will be updated."
    return 0
  else
    info "ℹ️ [INFO] Changes declined — user.js will not be modified."
    return 1
  fi
}  # Waits for Firefox to close before proceeding, with a custom message and interactive choice
wait_for_firefox_to_close() {
  local message="$1"  # Custom message to show
  local wait_for_user="$2"  # Flag to determine if user interaction is allowed (optional)

  # Check if Firefox is running
  while pgrep -x "firefox" >/dev/null; do
    # Show message and ask the user what they want to do (if in interactive mode)
    if [[ "$wait_for_user" != "0" ]]; then
      info "$message"
      read -rp "📝 [COMMAND] Do you want to wait for Firefox to close? [y/N]: " confirm
      confirm=$(to_lower "$confirm")
      if [[ "$confirm" != "y" ]]; then
        info "⚠️ [WARNING] Update aborted. Please close Firefox manually and try again."
        return 1  # Exit with an error if the user does not want to wait
      fi

      # Wait for Firefox to close if the user agreed to wait
      info "🔄 [ACTION] Waiting for Firefox to close..."
    fi

    # Loop and continuously check if Firefox is still running
    while pgrep -x "firefox" > /dev/null; do
      sleep 1
    done

    info "ℹ️ [INFO] Firefox has been closed. Continuing..."
  done
}
 #########################
## Main Functions
#########################

# Installs the launchd plist to schedule the agent to run the Arkenfox update
install_launchd() {
  debug "🔍 [DEBUG] Installing launchd plist..."

  # Ensure the directories for logs and launchd plist exist
  mkdir -p "$LOG_DIR"
  
  # Define the launchd plist file path
  local LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
  readonly LAUNCHD_PLIST
  
  info "🔄 [ACTION] Installing Arkenfox Updater agent..."

  # Create launchd plist file
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ARKENFOX_DIR/arkenfox.sh</string>
    <string>--auto-update</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

  # Unload existing launchd plist if loaded, then load the new one
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  launchctl load "$LAUNCHD_PLIST"

  info "ℹ️ [INFO] Arkenfox Updater agent has been scheduled to run daily."
}

# Installs Automator Quick Action workflow to run the Arkenfox update from macOS Services menu
install_automator() {
  if [[ "$NO_GUI" -eq 1 ]]; then
    debug "🔍 [DEBUG] Skipping Automator installation because --nogui is set."
    log "ℹ️ [INFO] Skipping Automator installation due to --nogui flag."
    return
  fi

  info "🔄 [ACTION] Checking if Automator Quick Action is already installed..."

  if [[ -d "$AUTOMATOR_WORKFLOW" ]]; then
    log "ℹ️ [INFO] Automator Quick Action already installed at $AUTOMATOR_WORKFLOW"
    debug "🔍 [DEBUG] Automator Quick Action already installed."

    read -rp "📝 [COMMAND] Automator Quick Action already exists. Overwrite? (y/N): " confirm
    confirm=$(to_lower "$confirm")

    if [[ -z "$confirm" || ( "$confirm" != "y" && "$confirm" != "yes" ) ]]; then
      log "ℹ️ [INFO] Skipping Automator install as per user request or default."
      debug "🔍 [DEBUG] User opted not to overwrite the existing workflow."
      info "⚠️ [WARNING] Skipping Automator Quick Action installation."
      return
    fi

    debug "🔍 [DEBUG] User opted to overwrite existing Automator Quick Action. Removing old workflow..."
    rm -rf "$AUTOMATOR_WORKFLOW"
  fi

  info "🔄 [ACTION] Installing Automator Quick Action for Arkenfox Updater..."

  if [[ ! -f "$ARKENFOX_DIR/arkenfox.sh" ]]; then
    error_exit "❌ [ERROR] arkenfox.sh script not found at $ARKENFOX_DIR."
  fi

  mkdir -p "$AUTOMATOR_WORKFLOW"

  local script_command="$ARKENFOX_DIR/arkenfox.sh --auto-update"

  cat > "$AUTOMATOR_WORKFLOW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AMApplicationBuild</key>
  <string>839</string>
  <key>AMApplicationVersion</key>
  <string>2.10</string>
  <key>AMDocumentType</key>
  <string>AutomatorWorkflow</string>
  <key>AMWorkflowIdentifier</key>
  <string>Run Arkenfox Updater</string>
  <key>AMWorkflowVersion</key>
  <integer>2</integer>
  <key>NSPrincipalClass</key>
  <string>AMWorkflow</string>
  <key>AMActions</key>
  <array>
    <dict>
      <key>AMActionVersion</key>
      <string>2.6</string>
      <key>AMBundleIdentifier</key>
      <string>com.apple.actions.runShellScript</string>
      <key>AMParameters</key>
      <dict>
        <key>shell</key>
        <string>/usr/bin/env bash</string>
        <key>script</key>
        <string>$script_command</string>
      </dict>
      <key>AMActionName</key>
      <string>Run Shell Script</string>
    </dict>
  </array>
</dict>
</plist>
EOF

  log "✅ [SUCCESS] Automator Quick Action installed at $AUTOMATOR_WORKFLOW"
  debug "🔍 [DEBUG] Automator Quick Action installed (direct workflow files)."
  info "ℹ️ [INFO] You can now manually run the Arkenfox Updater from the macOS Services menu."
}

# Installs Arkenfox, waits for Firefox to close, manages profile files, and installs macOS launch agents and Automator workflows
install() {
  info "🔄 [ACTION] Starting installation..."

  wait_for_firefox_to_close "⚠️ [WARNING] Firefox is running. Please close it to continue the installation."

  info "ℹ️ [INFO] Firefox is now closed. Continuing with the installation..."

  # Check for required tools (CLT, Git)
  check_clt || { 
    error_exit "❌ [ERROR] Command Line Tools are not installed. Please install Xcode Command Line Tools." 
  }

  check_git || { 
    error_exit "❌ [ERROR] Git is not installed. Please install Git." 
  }

  # Create necessary directories for Arkenfox installation and logs
  mkdir -p "$ARKENFOX_DIR"
  mkdir -p "$LOG_DIR"
  debug "🔍 [DEBUG] Created installation directories: $ARKENFOX_DIR, $LOG_DIR"

  # Clone or update Arkenfox repo
  if [[ ! -d "$ARKENFOX_DIR/.git" ]]; then
    info "🔄 [ACTION] Cloning Arkenfox user.js from GitHub..."
    git clone https://github.com/arkenfox/user.js "$ARKENFOX_DIR"
  else
    info "🔄 [ACTION] Updating existing Arkenfox repository..."
    cd "$ARKENFOX_DIR" && git pull
  fi

  # Find Firefox profile directory
  local profile_dir
  if ! profile_dir=$(find_profile); then
    error_exit "❌ [ERROR] Could not find Firefox default-release profile. Launch Firefox at least once before installing."
  fi
  info "ℹ️ [INFO] Located Firefox profile directory: $profile_dir"

  # Backup Firefox preferences
  backup_firefox_config "$profile_dir" || { 
    error_exit "❌ [ERROR] Failed to backup Firefox configuration at $profile_dir." 
  }
  debug "🔍 [DEBUG] Firefox configuration backed up at $profile_dir."

  # Ensure user-overrides.js exists in profile
  if [[ ! -f "$profile_dir/user-overrides.js" ]]; then
    echo "// Place your Arkenfox overrides here" > "$profile_dir/user-overrides.js"
    info "ℹ️ [INFO] Created empty user-overrides.js in profile directory."
    debug "🔍 [DEBUG] Created empty user-overrides.js at $profile_dir"
  fi

  # Ensure updater and prefsCleaner.sh are executable
  chmod +x "$ARKENFOX_DIR/updater.sh" "$ARKENFOX_DIR/prefsCleaner.sh"
  debug "🔍 [DEBUG] Ensured updater.sh and prefsCleaner.sh are executable."

  # Run prefsCleaner to strip old or conflicting prefs
  info "🔄 [ACTION] Cleaning old Firefox preferences with prefsCleaner.sh..."
  "$ARKENFOX_DIR/prefsCleaner.sh" "$profile_dir"
  info "ℹ️ [INFO] prefs.js cleaned using prefsCleaner.sh."

  # Run updater to apply user.js + overrides
  info "🔄 [ACTION] Applying Arkenfox user.js with updater.sh..."
  "$ARKENFOX_DIR/updater.sh" "$profile_dir"
  info "ℹ️ [INFO] Arkenfox user.js applied successfully."

  # Install Automator workflow and launchd agents (macOS-specific)
  install_automator || { 
    error_exit "❌ [ERROR] Failed to install Automator workflows." 
  }
  debug "🔍 [DEBUG] Automator workflows installed successfully."

  # Install launchd agent
  install_launchd || { 
    error_exit "❌ [ERROR] Failed to install launchd agents." 
  }
  debug "🔍 [DEBUG] launchd agents installed successfully."

  # Attempt log rotation (failure won’t stop the installation)
  rotate_log || info "⚠️ [WARNING] Log rotation failed, but continuing with installation."

  info "✅ [SUCCESS] Arkenfox installation completed successfully."

  # Final user feedback
  info "ℹ️ [INFO] Please restart Firefox and verify your new privacy settings. You can test using sites like deviceinfo.me."
  debug "🔍 [DEBUG] Installation completed successfully."
}

# Updates Arkenfox by pulling the latest repo changes, cleaning prefs, backing up user.js, and applying new configs to Firefox
update() {
  local DISPLAY_COUNT=3
  readonly DISPLAY_COUNT

  info "🔄 [ACTION] Starting Arkenfox update..."

  # Ensure necessary tools are available (similar to install())
  check_git || error_exit "❌ [ERROR] Git is not installed. Please install Git from https://git-scm.com/downloads."
  check_clt || error_exit "❌ [ERROR] Command Line Tools are missing. Please install Xcode Command Line Tools from https://developer.apple.com/xcode/downloads/."

  [[ "$AUTO_UPDATE_MODE" == "1" ]] && debug "🔍 [DEBUG] Auto-update mode enabled."

  # Check if Firefox is running before proceeding with the update
  if pgrep -x "firefox" > /dev/null; then
    if [[ "$AUTO_UPDATE_MODE" != "1" ]]; then
      wait_for_firefox_to_close "⚠️ [WARNING] Firefox is currently running. To avoid issues, please close Firefox before continuing with the update." 1
    else
      info "⚠️ [WARNING] Firefox is running, but in auto-update mode, continuing without waiting."
    fi
  fi

  # Ensure repository directory exists
  [[ -d "$REPO_DIR/.git" ]] || error_exit "❌ [ERROR] Repository directory is missing or corrupted. Please ensure the Arkenfox repository is correctly cloned in $REPO_DIR."

  cd "$REPO_DIR" || error_exit "❌ [ERROR] Failed to cd into $REPO_DIR."

  # Pull latest repo changes
  if ! git_output=$(git pull 2>&1); then
    error_exit "❌ [ERROR] Git pull failed: $git_output"
  fi
  log "ℹ️ [INFO] Git pull output: $git_output"

  # Locate Firefox profile directory
  local profile_dir
  profile_dir=$(find_profile) || error_exit "❌ [ERROR] Could not find Firefox profile. Launch Firefox at least once before updating."

  # Backup existing user.js if it exists
  local userjs_path="$profile_dir/user.js"
  if [[ -f "$userjs_path" ]]; then
    local backup_path="$profile_dir/user.js.bak.$(date +%s)"
    cp "$userjs_path" "$backup_path"
    info "ℹ️ [INFO] Backed up existing user.js to $backup_path"
  else
    info "⚠️ [WARNING] No existing user.js found to backup."
  fi

  # Run prefsCleaner.sh to clean old prefs
  info "🔄 [ACTION] Running prefsCleaner.sh to clean old prefs..."
  bash "$REPO_DIR/prefsCleaner.sh" "$profile_dir" || error_exit "❌ [ERROR] prefsCleaner.sh failed."

  # Run updater.sh to generate new user.js
  info "🔄 [ACTION] Running updater.sh to generate new user.js..."
  local tmp_new_userjs="$profile_dir/user.js.new"
  bash "$REPO_DIR/updater.sh" "$profile_dir" "$tmp_new_userjs" || error_exit "❌ [ERROR] updater.sh failed."

  # Check if user.js changed
  local userjs_changed="no"
  if [[ -f "$userjs_path" ]] && ! cmp -s "$userjs_path" "$tmp_new_userjs"; then
    userjs_changed="yes"
  fi

  if [[ "$userjs_changed" == "yes" ]]; then
    # Find changed prefs keys
    local changed_keys
    changed_keys=$(diff -u "$userjs_path" "$tmp_new_userjs" | grep -E '^[+-]user_pref' | sed -E 's/^[+-]user_pref\("([^"]+)",.*$/\1/' | sort -u)

    local -a prefs_array=()
    mapfile -t prefs_array <<< "$changed_keys"

    local num_prefs_updated=${#prefs_array[@]}

    # Compose prefs summary string: first DISPLAY_COUNT prefs, then "+N more" if needed
    local prefs_summary
    if (( num_prefs_updated <= DISPLAY_COUNT )); then
      prefs_summary=$(IFS=', '; echo "${prefs_array[*]}")
    else
      local first_prefs=("${prefs_array[@]:0:DISPLAY_COUNT}")
      local remaining=$((num_prefs_updated - DISPLAY_COUNT))
      prefs_summary="$(IFS=', '; echo "${first_prefs[*]}") (+$remaining more)"
    fi

    if [[ "$AUTO_UPDATE_MODE" != "1" ]]; then
      # Interactive mode: show diff and confirm
      info "🔄 [ACTION] Detected changes in your user.js. Displaying the differences for your review..."
      diff -u "$userjs_path" "$tmp_new_userjs" | sed 's/^/    /'

      echo
      read -rp "📝 [COMMAND] Apply these changes to user.js? [y/N]: " confirm
      confirm=$(to_lower "$confirm")   # <-- keep your to_lower function usage here
      if [[ "$confirm" != "y" ]]; then
        info "⚠️ [WARNING] Update aborted by user. No changes applied."
        rm -f "$tmp_new_userjs"
        return
      fi

      mv "$tmp_new_userjs" "$userjs_path"
      info "✅ [SUCCESS] Applied updated user.js to profile."
    else
      # Auto-update mode: apply silently + notify
      mv "$tmp_new_userjs" "$userjs_path"
      local notify_msg="✅ Arkenfox update applied. $num_prefs_updated preferences updated: $prefs_summary. 🔄 Please restart Firefox for the changes to take effect."
      notify "$notify_msg"
    fi
  else
    # No changes detected
    rm -f "$tmp_new_userjs"
    if [[ "$AUTO_UPDATE_MODE" == "1" ]]; then
      notify "ℹ️ Arkenfox update completed. No changes were needed: your Firefox profile is already using the latest settings."
    else
      info "ℹ️ [INFO] No changes detected in user.js. Your Firefox profile is already using the latest Arkenfox settings."
    fi
  fi

  # Attempt log rotation (failure won’t stop the update)
  rotate_log || info "⚠️ [WARNING] Log rotation failed. The update continues, but log management may need attention."

  # Provide final feedback
  info "🔄 [ACTION] Please restart Firefox to apply the latest privacy settings."
  info "✅ [SUCCESS] Arkenfox update completed successfully."
}

# Uninstalls Arkenfox, restores Firefox prefs, removes backups, logs, and cleanup related files
uninstall() {
  # Wait for Firefox to close before proceeding
  while pgrep -x "firefox" >/dev/null; do
    info "⚠️ [WARNING] Firefox is running. Please close it to continue uninstalling..."
    sleep 5
  done

  debug "🔍 [DEBUG] Starting uninstall process..."
  info "🔄 [ACTION] Uninstalling Arkenfox..."

  # Restore Firefox prefs from backup if possible
  restore_firefox_backup

  # Find Firefox profile directory
  local profile_dir
  if ! profile_dir=$(find_profile); then
    info "⚠️ [WARNING] Could not find Firefox profile. Skipping prefs cleanup."
  else
    # Check if any backup exists
    local backup_dir
    backup_dir=$(ls -td "$LOG_DIR/backups/"*/ 2>/dev/null | head -1 || true)

    if [[ -z "$backup_dir" ]]; then
      info "⚠️ [WARNING] No backup found. Deleting prefs.js and other related files..."

      for file in "${FILES_TO_BACKUP[@]}"; do
        if [[ -f "$profile_dir/$file" ]]; then
          if [[ "$file" == "prefs.js" ]]; then
            info "⚠️ [WARNING] prefs.js exists but no backup was found."
            read -rp "📝 [COMMAND] Delete prefs.js anyway? [y/N]: " confirm_delete_prefs
            confirm_delete_prefs=$(to_lower "$confirm_delete_prefs")
            if [[ "$confirm_delete_prefs" != "y" && "$confirm_delete_prefs" != "yes" ]]; then
              info "ℹ️ [INFO] Skipping prefs.js deletion."
              log "ℹ️ [INFO] User declined to delete prefs.js."  
              continue
            fi
          fi
          rm -f "$profile_dir/$file"
          info "✅ [SUCCESS] Removed $file from $profile_dir as no backup existed."
        fi
      done
    else
      info "ℹ️ [INFO] Backup found. No need to remove any files."
    fi
  fi

  # Unload and remove launchd plist
  debug "🔍 [DEBUG] Unloading launchd plist..."
  info "🔄 [ACTION] Unloading and removing launchd plist..."
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  rm -f "$LAUNCHD_PLIST"
  log "✅ [SUCCESS] Unloaded and removed launchd plist."

  # Remove Automator Quick Action workflow
  debug "🔍 [DEBUG] Removing Automator Quick Action workflow..."
  info "🔄 [ACTION] Removing Automator Quick Action workflow..."
  rm -rf "$AUTOMATOR_WORKFLOW"
  log "✅ [SUCCESS] Removed Automator Quick Action workflow."

  # Refresh LaunchServices to update Services menu
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r \
    -domain local \
    -domain system \
    -domain user \
    >/dev/null 2>&1 || true

  # Prompt user to delete backups and logs
  read -rp "📝 [COMMAND] Do you want to delete Arkenfox backups and logs? [y/N]: " confirm_delete
  confirm_delete=$(to_lower "$confirm_delete")

  if [[ "$confirm_delete" == "y" || "$confirm_delete" == "yes" ]]; then
    info "🔄 [ACTION] Deleting backups and logs..."
    rm -rf "$LOG_DIR/backups"
    rm -rf "$LOG_DIR/snapshots"
    log "ℹ️ [INFO] User chose to delete backups and logs."
  else
    info "ℹ️ [INFO] Keeping backups and logs."
  fi

  # Remove main Arkenfox directory last
  rm -rf "$ARKENFOX_DIR"
  log "✅ [SUCCESS] Removed Arkenfox directory."

  # Remove Xcode CLT if installed by this script
  if [[ -f "$GIT_MARKER" ]]; then
    debug "🔍 [DEBUG] Removing Xcode Command Line Tools installed by script..."
    info "🔄 [ACTION] Removing Xcode Command Line Tools..."
    sudo rm -rf /Library/Developer/CommandLineTools
    sudo xcode-select --reset
    rm "$GIT_MARKER"
    info "✅ [SUCCESS] Xcode CLT removed (installed by script)."
  else
    debug "🔍 [DEBUG] No Xcode CLT removal needed."
    info "ℹ️ [INFO] No Xcode CLT removal needed."
  fi

  info "✅ [SUCCESS] Arkenfox has been successfully removed."
}

#########################
## Main Execution
#########################

case "$MODE" in
  install) install ;;
  update) update ;;
  uninstall) uninstall ;;
  *) echo "Unknown mode: $MODE"; exit 1 ;;
esac
