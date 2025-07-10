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
  local msg="\$1"
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"\$msg\" with title \"Arkenfox Updater\""
  fi
  # Log the message with timestamp
  echo "\$(date '+%Y-%m-%d %H:%M:%S') \$msg" >> "\$LOG_FILE"
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
  
  # Debug message about starting the snapshot
  debug "🔍 [DEBUG] Taking system snapshot: $snapshot_label"

  # Create snapshots directory
  mkdir -p "$LOG_DIR/snapshots" || { log "❌ [ERROR] Failed to create snapshots dir."; exit 1; }

  # Log the start of the snapshot process
  log "🔄 [ACTION] === $snapshot_label system snapshot at $(date) ==="

  # Save the system snapshot details
  {
    sw_vers
    echo "Disk Usage:"
    df -h /
    echo "Memory:"
    vm_stat || echo "vm_stat failed"
    echo "Processes:"
    ps aux | head -20
    echo
  } >> "$LOG_DIR/snapshots/$snapshot_label.txt" || { log "❌ [ERROR] Failed to write snapshot."; exit 1; }

  # Log the successful completion of the snapshot
  log "✅ [SUCCESS] System snapshot '$snapshot_label' completed and saved."
}

# Check if Xcode Command Line Tools are installed
check_clt() {
  debug "🔍 [DEBUG] Checking Xcode Command Line Tools..."

  if ! pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; then
    echo "🔄 [ACTION] Installing Xcode Command Line Tools..."
    debug "🔍 [DEBUG] Xcode Command Line Tools not found, installing..."

    set +e
    xcode-select --install 2>/dev/null || true
    set -e

    trap 'echo; error_exit "🚨 [CRITICAL] Installation interrupted by user"' SIGINT

    local tries=0
    local max_tries=20  # Default value if not provided via environment variable
    local wait_sec=15   # Default value if not provided via environment variable

    # Override with environment variables if they are set
    max_tries="${MAX_TRIES:-$max_tries}"
    wait_sec="${WAIT_SEC:-$wait_sec}"

    echo -n "🔄 [ACTION] Waiting for Command Line Tools installation"

    while ! pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; do
      (( tries++ ))

      if (( tries >= max_tries )); then
        echo
        error_exit "❌ [ERROR] Timed out waiting for Xcode Command Line Tools installation. Please install manually and rerun."
      fi

      if (( tries == 4 )); then
        echo
        echo "⚠️ [WARNING] Reminder: If you see a popup asking to install Command Line Tools, please confirm it."
        echo "⚠️ [WARNING] Please confirm the Command Line Tools installer popup to continue installation."
        echo -n "🔄 [ACTION] Waiting for Command Line Tools installation"
      fi

      echo -n ". (${tries}/${max_tries}, ~ $((tries * wait_sec))s elapsed)"
      sleep "$wait_sec"
    done

    # Final completion message
    echo "✅ [SUCCESS] Command Line Tools installation complete."

    sudo xcode-select --switch /Library/Developer/CommandLineTools

    touch "$GIT_MARKER"
    debug "🔍 [DEBUG] Xcode Command Line Tools installed successfully."
  else
    debug "🔍 [DEBUG] Xcode Command Line Tools already installed."
  fi

  # Reset the trap after installation
  trap - SIGINT
}

# Check if Git is installed
check_git() {
  debug "🔍 [DEBUG] Checking for git command..."
  if ! command -v git &>/dev/null; then
    error_exit "❌ [ERROR] Git is not installed. Please install Git via Homebrew (brew install git) or from https://git-scm.com"
  else
    debug "🔍 [DEBUG] Git found."
  fi
}

# Find the Firefox default profile directory
find_profile() {
  debug "🔍 [DEBUG] Searching for Firefox default-release profile..."

  local firefox_profile_dir
  firefox_profile_dir=$(find "$HOME/Library/Application Support/Firefox/Profiles" -type d -name "*.default-release" 2>/dev/null | head -n 1)

  if [[ -z "$firefox_profile_dir" ]]; then
    echo "❌ [ERROR] Could not find Firefox default-release profile. Launch Firefox at least once." >&2
    return 1
  fi

  echo "ℹ️ [INFO] Firefox profile directory: $firefox_profile_dir"
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
  echo "# Firefox backup created on $(date)" > "$backup_manifest_file"
  echo "# Profile: $user_profile_dir" >> "$backup_manifest_file"
  echo "" >> "$backup_manifest_file"  # Blank line for readability

  for file in "${FILES_TO_BACKUP[@]}"; do
    if [[ -f "$user_profile_dir/$file" ]]; then
      cp "$user_profile_dir/$file" "$backup_directory/"
      echo "$file" >> "$backup_manifest_file"
      echo "✅ [SUCCESS] Successfully backed up $file from $user_profile_dir."
      log "✅ [SUCCESS] Successfully backed up $file from $user_profile_dir."
    else
      debug "🔍 [DEBUG] The file $file does not exist. Skipping backup."
    fi
  done

  echo "ℹ️ [INFO] Backup directory created: $backup_directory" > "$ARKENFOX_DIR/.last-backup"
}

# Restore Firefox backup if possible
restore_firefox_backup() {
  if pgrep -x "firefox" >/dev/null; then
    echo "⚠️ [WARNING] Firefox is currently running. Please close it before restoring the backup."
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
    debug "🔍 [DEBUG] No backup directory found. Skipping restore."
    return
  fi

  local backup_manifest_file="$backup_directory/manifest.txt"

  if [[ ! -f "$backup_manifest_file" ]]; then
    debug "🔍 [DEBUG] No manifest file found in backup. Skipping restore."
    return
  fi

  # Iterate over the files listed in the manifest file
  while IFS= read -r file; do
    [[ "$file" =~ ^#.*$ || -z "$file" ]] && continue  # Skip comment or empty lines

    if [[ -f "$backup_directory/$file" ]]; then
      if [[ "$file" == "prefs.js" ]]; then
        echo "⚠️ [WARNING] prefs.js is about to be restored from backup."
        read -rp "📝 [COMMAND] Restore prefs.js from backup? [y/N]: " user_confirmation_restore
        user_confirmation_restore=$(to_lower "$user_confirmation_restore")
        if [[ "$user_confirmation_restore" != "y" && "$user_confirmation_restore" != "yes" ]]; then
          echo "ℹ️ [INFO] User declined to restore prefs.js. Skipping restoration."
          continue
        fi
      fi
      cp "$backup_directory/$file" "$user_profile_dir/$file"
      echo "✅ [SUCCESS] Restored $file from backup."
    else
      debug "🔍 [DEBUG] $file listed in manifest but not found in backup."
    fi
  done < "$backup_manifest_file"

  # Remove any files from the profile that weren't backed up
  for file in "${FILES_TO_BACKUP[@]}"; do
    if ! grep -qx "$file" "$backup_manifest_file" && [[ -f "$user_profile_dir/$file" ]]; then
      rm -f "$user_profile_dir/$file"
      echo "⚠️ [WARNING] Removed $file as it was not backed up."
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
  log "ℹ️ [INFO] Merging Arkenfox user.js with overrides..."

  # Clear any existing merge logs or conflict files
  rm -f "$LOG_DIR"/{overrides.txt,conflicts.txt,"$merge_conflicts_file"}

  # Extract preferences from the base user.js and sort them
  grep '^user_pref' "$REPO_DIR/user.js" | sed -E 's/user_pref\("([^"]+)",.*/\1/' | sort > "$LOG_DIR/base.txt"

  # If an overrides file exists, process it
  if [[ -f "$USER_OVERRIDES" ]]; then
    # Extract preferences from the user overrides and sort them
    grep '^user_pref' "$USER_OVERRIDES" | sed -E 's/user_pref\("([^"]+)",.*/\1/' | sort > "$LOG_DIR/overrides.txt"

    # Find common preferences between base and overrides (conflicts)
    comm -12 "$LOG_DIR/base.txt" "$LOG_DIR/overrides.txt" > "$LOG_DIR/conflicts.txt"

    # If conflicts exist, notify the user and log the conflicts
    if [[ -s "$LOG_DIR/conflicts.txt" ]]; then
      echo "⚠️ [WARNING] Conflict(s) detected in user-overrides.js. Please review the conflicts."
      cp "$LOG_DIR/conflicts.txt" "$merge_conflicts_file"
      log "⚠️ [WARNING] Overridden preferences written to $merge_conflicts_file."
    else
      log "ℹ️ [INFO] No conflicts detected between user.js and user-overrides.js."
    fi

    # Merge the base user.js and user-overrides.js into the temporary merge file
    cat "$REPO_DIR/user.js" "$USER_OVERRIDES" > "$temp_merge_file"
  else
    log "ℹ️ [INFO] No user-overrides.js found. Using base user.js only."
    cat "$REPO_DIR/user.js" > "$temp_merge_file"
  fi

  # Return the path to the merged file
  echo "$temp_merge_file"
}

# Show differences between current and merged user.js, asking for confirmation to apply changes
show_diff_and_confirm() {
  local profile_user_js_path="$1/user.js"  
  local merged_user_js_path="$2"              
  local user_confirmation  
  
  # Check if diff command is available
  if ! command -v diff >/dev/null 2>&1; then
    echo "⚠️ [WARNING] Diff command not found. Skipping diff display."
    return 0
  fi

  # If no profile.js, inform and exit
  if [[ ! -f "$profile_user_js_path" ]]; then
    echo "ℹ️ [INFO] No existing user.js found. This will be added."
    return 0
  fi

  # Check for differences between the profile and merged files
  if cmp -s "$profile_user_js_path" "$merged_user_js_path"; then
    debug "ℹ️ [INFO] No differences detected between current and merged user.js."
    return 0
  fi

  # Show the differences
  echo "ℹ️ [INFO] Showing differences between current and updated user.js:"
  echo "--------------------------------------------------"
  diff -u "$profile_user_js_path" "$merged_user_js_path" | less -R || true
  echo "--------------------------------------------------"
  echo

  # Ask user for confirmation
  read -rp "📝 [COMMAND] Apply these changes to user.js? [y/N]: " user_confirmation
  user_confirmation=$(to_lower "$user_confirmation")

  # Apply changes based on user confirmation
  if [[ "$user_confirmation" == "y" || "$user_confirmation" == "yes" ]]; then
    echo "ℹ️ [INFO] Changes applied to user.js."
    return 0
  else
    echo "ℹ️ [INFO] Changes not applied to user.js."
    return 1
  fi
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

# Installs Arkenfox, waits for Firefox to close, creates necessary files, and installs launch agents and Automator workflows
install() {
  local merge_wrote_changes="no"  # Initialize to avoid unbound variable error

  info "🔄 [ACTION] Starting installation..."

  # Wait for Firefox to close before proceeding
  while pgrep -x "firefox" >/dev/null; do
    info "⚠️ [WARNING] Firefox is running. Please close it to continue the installation."
    sleep 5
  done

  info "ℹ️ [INFO] Firefox is now closed. Continuing with the installation..."

  debug "🔍 [DEBUG] Starting installation..."

  # Check for required tools (CLT, Git)
  check_clt
  check_git

  # Create necessary directories for Arkenfox installation and logs
  mkdir -p "$ARKENFOX_DIR"
  mkdir -p "$LOG_DIR"

  # Create the updater script
  create_updater_script

  # Find the Firefox profile directory
  local profile_dir
  if ! profile_dir=$(find_profile); then
    error_exit "❌ [ERROR] Could not find Firefox default-release profile. Launch Firefox at least once before installing."
  fi

  # Backup the Firefox configuration files
  backup_firefox_config "$profile_dir"

  # Create empty user-overrides.js if it does not exist
  if [[ ! -f "$ARKENFOX_DIR/user-overrides.js" ]]; then
    echo "// User overrides here" > "$ARKENFOX_DIR/user-overrides.js"
    debug "🔍 [DEBUG] Created empty user-overrides.js."
  fi

  # Merge user.js and user-overrides.js
  local merged_file
  merged_file=$(merge_userjs "$profile_dir")

  # Show diff and ask for confirmation
  if show_diff_and_confirm "$profile_dir" "$merged_file"; then
    cp "$merged_file" "$profile_dir/user.js"
    log "ℹ️ [INFO] user.js updated in profile."
    merge_wrote_changes="yes"
  else
    merge_wrote_changes="no"
  fi

  # Clean up merged file after use
  rm -f "$merged_file"

  # Install Automator and launchd configurations
  install_automator
  install_launchd

  # Rotate logs for the installation
  rotate_log

  info "✅ [SUCCESS] Arkenfox installed successfully"
  debug "🔍 [DEBUG] Installation complete."
}

# Updates Arkenfox by pulling the latest repo changes, merging configs, and updating Firefox user.js
update() {
  local DISPLAY_COUNT=3
  readonly DISPLAY_COUNT

  local merge_wrote_changes="no"
  local base_changed="no"
  local changed_prefs=""
  local count=0
  local summary=""

  info "🔄 [ACTION] Starting update..."

  check_clt
  check_git

  [[ "$DEBUG_MODE" == "1" ]] && debug "🔍 [DEBUG] Debug mode enabled."
  [[ "$AUTO_UPDATE_MODE" == "1" ]] && debug "🔁 [DEBUG] Auto-update mode enabled."

  if [[ -d "$REPO_DIR/.git" ]]; then
    cd "$REPO_DIR" || error_exit "❌ [ERROR] Failed to cd into $REPO_DIR."

    # Compare Git hash to detect upstream changes
    local old_hash new_hash
    old_hash=$(shasum -a 256 user.js | awk '{print $1}')
    git_output=$(git pull 2>&1) || error_exit "❌ [ERROR] Git pull failed: $git_output"
    log "ℹ️ [INFO] Git pull output: $git_output"
    new_hash=$(shasum -a 256 user.js | awk '{print $1}')
    [[ "$old_hash" != "$new_hash" ]] && base_changed="yes"

    # Locate Firefox profile
    local profile_dir
    profile_dir=$(find_profile) || error_exit "❌ [ERROR] Could not find Firefox profile. Launch Firefox at least once before updating."

    # Define working files
    local old_userjs="$profile_dir/user.js"
    local tmp_old_userjs="$profile_dir/user.js.old.$(date +%s)"
    local tmp_new_userjs="$profile_dir/user.js.new.$(date +%s)"

    # Backup existing user.js if it exists
    [[ -f "$old_userjs" ]] && cp "$old_userjs" "$tmp_old_userjs"

    # Merge Arkenfox base with overrides
    cat "$REPO_DIR/user.js" "$ARKENFOX_DIR/user-overrides.js" > "$tmp_new_userjs" || {
      [[ "$AUTO_UPDATE_MODE" == "1" ]] && notify "❌ Failed to merge user.js. Update failed."
      error_exit "❌ [ERROR] Failed to merge user.js and overrides."
    }

    # No changes detected
    if cmp -s "$tmp_new_userjs" "$old_userjs"; then
      if [[ "$base_changed" == "yes" ]]; then
        info "✅ [SUCCESS] Downloaded latest Arkenfox user.js. Firefox profile user.js already up to date."
        [[ "$AUTO_UPDATE_MODE" == "1" ]] && notify "✅ Arkenfox update applied. No changes to Firefox profile needed."
      else
        info "ℹ️ [INFO] Arkenfox is already up to date. No repo or override changes."
        [[ "$AUTO_UPDATE_MODE" == "1" ]] && notify "ℹ️ Arkenfox is already up-to-date. No updates or preferences were applied."
      fi
    else
      # New user.js is different; apply changes
      mv "$tmp_new_userjs" "$old_userjs"
      merge_wrote_changes="yes"

      # Calculate and log differences
      local diff_output=""
      if [[ -f "$tmp_old_userjs" ]]; then
        diff_output=$(diff -u "$tmp_old_userjs" "$old_userjs" || true)
      else
        diff_output="No previous user.js found. New preferences applied."
      fi

      # Always log the full diff (for debugging / auditing)
      {
        echo "=== Arkenfox update diff at $(date) ==="
        echo "$diff_output"
        echo "========================================"
      } >> "$LOG_FILE"

      # Summarize changed prefs, if any
      if [[ -f "$tmp_old_userjs" ]]; then
        changed_prefs=$(echo "$diff_output" | grep '^+user_pref' | grep -v '^+++')
        count=$(echo "$changed_prefs" | wc -l | tr -d ' ')
        summary=$(echo "$changed_prefs" | head -n "$DISPLAY_COUNT" | sed -E 's/^\+user_pref\("([^"]+)".*/\1/' | paste -sd ', ' -)
        rm -f "$tmp_old_userjs"

        info "✅ [SUCCESS] $count prefs updated: $summary"

        if [[ "$AUTO_UPDATE_MODE" == "1" ]]; then
          if [[ "$count" -le "$DISPLAY_COUNT" ]]; then
            notify "✅ Arkenfox update applied. $count preferences updated: $summary. 🔄 Please restart Firefox for the changes to take effect."
          else
            local more_count=$((count - DISPLAY_COUNT))
            notify "✅ Arkenfox update applied. $count preferences updated: $summary… (+$more_count more). 🔄 Please restart Firefox for the changes to take effect."
          fi
        fi
      else
        info "⚙️ [CONFIG] Applied new settings from user-overrides.js to Firefox profile."
        [[ "$AUTO_UPDATE_MODE" == "1" ]] && notify "✅ Arkenfox update applied. No preferences changed."
      fi

      # Post-update context message
      if [[ "$base_changed" == "yes" ]]; then
        if pgrep -x "firefox" >/dev/null; then
          info "✅ [SUCCESS] Downloaded latest Arkenfox user.js and applied updates to Firefox profile. Please restart Firefox for the changes to take effect."
        else
          info "✅ [SUCCESS] Downloaded latest Arkenfox user.js and applied updates to Firefox profile."
        fi
      else
        if pgrep -x "firefox" >/dev/null; then
          info "⚙️ [CONFIG] Applied new settings from user-overrides.js to Firefox profile. Please restart Firefox for the changes to take effect."
        else
          info "⚙️ [CONFIG] Applied new settings from user-overrides.js to Firefox profile."
        fi
      fi
    fi

    rm -f "$tmp_new_userjs"
  else
    error_exit "❌ [ERROR] Repository directory missing or corrupted: $REPO_DIR"
  fi

  rotate_log
  debug "🔍 [DEBUG] Update complete."
  info "✅ [SUCCESS] Update complete."
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
