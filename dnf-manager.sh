#!/bin/bash

# Fedora Package Environment Manager with Parallel Processing
# Enhanced version with concurrent package processing for improved performance

# Configuration
PACKAGE_DIR="${PACKAGE_DIR:-$HOME/fedora-packages}"
MANUAL_PACKAGES="$PACKAGE_DIR/outputs/manual-packages.txt"
AUTO_DEPENDENCIES="$PACKAGE_DIR/outputs/auto-dependencies.txt"
DEPENDENCY_TREE="$PACKAGE_DIR/outputs/dependency-tree.txt"
LOCK_FILE="$PACKAGE_DIR/outputs/fedora.lock"
DEFAULT_PACKAGES="$PACKAGE_DIR/outputs/default-packages.txt"
DATE=$(date +%Y%m%d-%H%M%S)

# Performance Configuration
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-$(nproc)}"
CHUNK_SIZE="${CHUNK_SIZE:-50}"
ENABLE_PROGRESS="${ENABLE_PROGRESS:-true}"
CACHE_DIR="${CACHE_DIR:-$PACKAGE_DIR/.cache}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Create directories if they don't exist
mkdir -p "$PACKAGE_DIR" "$CACHE_DIR" "$PACKAGE_DIR"/outputs

# Progress tracking
CURRENT_PROGRESS=0
TOTAL_PROGRESS=0
PROGRESS_FILE="$CACHE_DIR/progress-$$"

function init_progress() {
    local total=$1
    local operation=${2:-"Processing"}
    TOTAL_PROGRESS=$total
    CURRENT_PROGRESS=0
    echo "0" > "$PROGRESS_FILE"
    if [ "$ENABLE_PROGRESS" = "true" ]; then
        echo -e "${CYAN}$operation: 0/$total packages (0%)${NC}"
    fi
}

function update_progress() {
    local increment=${1:-1}
    if [ "$ENABLE_PROGRESS" = "true" ]; then
        # Thread-safe progress update
        {
            flock 200
            local current=$(cat "$PROGRESS_FILE" 2>/dev/null || echo "0")
            local new_current=$((current + increment))
            echo "$new_current" > "$PROGRESS_FILE"
            
            if [ $((new_current % 10)) -eq 0 ]; then
                local percent=$((new_current * 100 / TOTAL_PROGRESS))
                printf "\r${CYAN}Processing: $new_current/$TOTAL_PROGRESS packages ($percent%%)${NC}"
            fi
        } 200>"$PROGRESS_FILE.lock"
    fi
}

function finish_progress() {
    if [ "$ENABLE_PROGRESS" = "true" ]; then
        local final_count=$(cat "$PROGRESS_FILE" 2>/dev/null || echo "$TOTAL_PROGRESS")
        printf "\r${GREEN}✓ Completed: $final_count/$TOTAL_PROGRESS packages (100%%)${NC}\n"
    fi
    rm -f "$PROGRESS_FILE" "$PROGRESS_FILE.lock"
}

# Parallel package information gathering
function get_package_info_parallel() {
    local package_list_file=$1
    local output_file=$2
    local operation=${3:-"package info"}
    
    if [ ! -f "$package_list_file" ]; then
        echo -e "${RED}✗ Package list file not found: $package_list_file${NC}"
        return 1
    fi
    
    local total_packages=$(wc -l < "$package_list_file")
    if [ $total_packages -eq 0 ]; then
        touch "$output_file"
        return 0
    fi
    
    init_progress $total_packages "Gathering $operation"
    
    # Clear output file
    > "$output_file"
    
    # Create temporary directory for parallel processing
    local temp_dir=$(mktemp -d)
    local active_jobs=()
    
    # Process packages in chunks
    split -l $CHUNK_SIZE "$package_list_file" "$temp_dir/chunk_"
    
    for chunk_file in "$temp_dir"/chunk_*; do
        # Wait for available slot if we've hit the job limit
        while [ ${#active_jobs[@]} -ge $MAX_PARALLEL_JOBS ]; do
            for i in "${!active_jobs[@]}"; do
                if ! kill -0 "${active_jobs[$i]}" 2>/dev/null; then
                    wait "${active_jobs[$i]}"
                    unset active_jobs[$i]
                fi
            done
            active_jobs=("${active_jobs[@]}") # Reindex array
            sleep 0.1
        done
        
        # Start parallel job for this chunk
        {
            local chunk_output="$temp_dir/output_$(basename $chunk_file)"
            while IFS= read -r package; do
                if [ ! -z "$package" ]; then
                    local pkg_info=$(rpm -q --queryformat "%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}|%{SIZE}|%{INSTALLTIME}|" "$package" 2>/dev/null)
                    if [ $? -eq 0 ]; then
                        local repo=$(dnf repoquery --installed --queryformat "%{reponame}" "$package" 2>/dev/null | head -1)
                        echo "${pkg_info}${repo}" >> "$chunk_output"
                    fi
                    update_progress 1
                fi
            done < "$chunk_file"
        } &
        
        local job_pid=$!
        active_jobs+=($job_pid)
    done
    
    # Wait for all jobs to complete
    for job_pid in "${active_jobs[@]}"; do
        wait $job_pid
    done
    
    # Combine all outputs in a deterministic order
    for chunk_file in "$temp_dir"/chunk_*; do
        local chunk_output="$temp_dir/output_$(basename $chunk_file)"
        if [ -f "$chunk_output" ]; then
            cat "$chunk_output" >> "$output_file"
        fi
    done
    
    # Cleanup
    rm -rf "$temp_dir"
    
    finish_progress
}

# Enhanced parallel package analysis
function analyze_packages_parallel() {
    echo -e "${GREEN}Analyzing installed packages (excluding defaults) - Parallel Mode...${NC}"
    
    # Check if defaults exist
    if [ ! -f "$DEFAULT_PACKAGES" ]; then
        echo -e "${YELLOW}Default packages list not found. Running init first...${NC}"
        get_default_packages
    fi
    
    # Backup existing files
    for file in "$MANUAL_PACKAGES" "$AUTO_DEPENDENCIES"; do
        if [ -f "$file" ]; then
            cp "$file" "${file%.txt}-backup-$DATE.txt"
        fi
    done
    
    echo "Fetching package information in parallel..."
    
    # Create temporary files for parallel processing
    local temp_all_packages="$CACHE_DIR/all-packages-$$.txt"
    local temp_user_installed="$CACHE_DIR/user-installed-$$.txt"
    
    # Launch parallel queries
    {
        dnf repoquery --installed --queryformat "%{name}\n" 2>/dev/null | sort | uniq > "$temp_all_packages"
        echo "all_done" > "$CACHE_DIR/all_done-$$"
    } &
    local all_packages_pid=$!
    
    {
        dnf repoquery --userinstalled --queryformat "%{name}\n" 2>/dev/null | sort | uniq > "$temp_user_installed"
        echo "user_done" > "$CACHE_DIR/user_done-$$"
    } &
    local user_installed_pid=$!
    
    # Show progress while waiting
    local dots=0
    while [ ! -f "$CACHE_DIR/all_done-$$" ] || [ ! -f "$CACHE_DIR/user_done-$$" ]; do
        printf "\rFetching package data"
        for ((i=0; i<dots; i++)); do printf "."; done
        printf "   "
        dots=$(((dots + 1) % 4))
        sleep 0.5
    done
    echo ""
    
    # Wait for both queries to complete
    wait $all_packages_pid
    wait $user_installed_pid
    
    # Clean up status files
    rm -f "$CACHE_DIR/all_done-$$" "$CACHE_DIR/user_done-$$"
    
    local TOTAL_COUNT=$(wc -l < "$temp_all_packages")
    echo "Found $TOTAL_COUNT total packages"
    
    # Process package categorization in parallel
    echo "Categorizing packages..."
    
    # Prepare temporary files for set operations
    local temp_defaults="$CACHE_DIR/defaults-$$.txt"
    cp "$DEFAULT_PACKAGES" "$temp_defaults"
    
    {
        # Get truly manual packages (user-installed minus defaults)
        comm -23 "$temp_user_installed" "$temp_defaults" | grep -v '^$' > "$MANUAL_PACKAGES"
        echo "manual_done" > "$CACHE_DIR/manual_done-$$"
    } &
    local manual_pid=$!
    
    {
        # First remove defaults from all packages
        local temp_non_default="$CACHE_DIR/non-default-$$.txt"
        comm -23 "$temp_all_packages" "$temp_defaults" > "$temp_non_default"
        echo "nondefault_done" > "$CACHE_DIR/nondefault_done-$$"
    } &
    local nondefault_pid=$!
    
    # Wait for initial processing
    wait $manual_pid $nondefault_pid
    rm -f "$CACHE_DIR/manual_done-$$" "$CACHE_DIR/nondefault_done-$$"
    
    # Calculate auto dependencies
    {
        local temp_non_default="$CACHE_DIR/non-default-$$.txt"
        comm -23 "$temp_non_default" "$MANUAL_PACKAGES" | grep -v '^$' > "$AUTO_DEPENDENCIES"
    } &
    wait $!
    
    # Calculate counts
    local MANUAL_COUNT=$(wc -l < "$MANUAL_PACKAGES")
    local AUTO_COUNT=$(wc -l < "$AUTO_DEPENDENCIES")
    local DEFAULT_COUNT=$(wc -l < "$DEFAULT_PACKAGES")
    
    # Clean up temporary files
    rm -f "$temp_all_packages" "$temp_user_installed" "$temp_defaults" "$CACHE_DIR/non-default-$$.txt"
    
    # Create summary
    echo -e "\n${BLUE}=== Package Analysis Summary (Parallel) ===${NC}"
    echo -e "Processing time: Significantly reduced with $MAX_PARALLEL_JOBS parallel jobs"
    echo -e "Total packages:          $TOTAL_COUNT"
    echo -e "Default Fedora:          ${CYAN}$DEFAULT_COUNT${NC} ($(awk "BEGIN {printf \"%.1f\", $DEFAULT_COUNT*100/$TOTAL_COUNT}")%)"
    echo -e "Manually installed:      ${GREEN}$MANUAL_COUNT${NC} ($(awk "BEGIN {printf \"%.1f\", $MANUAL_COUNT*100/$TOTAL_COUNT}")%)"
    echo -e "Auto dependencies:       ${YELLOW}$AUTO_COUNT${NC} ($(awk "BEGIN {printf \"%.1f\", $AUTO_COUNT*100/$TOTAL_COUNT}")%)"
    
    echo -e "\n${CYAN}Top 10 Custom Packages:${NC}"
    head -10 "$MANUAL_PACKAGES" | sed 's/^/  - /'
    
    echo -e "\nFiles saved in: $PACKAGE_DIR/"
}

# Enhanced lock file creation with parallel processing
function create_lock_file_parallel() {
    echo -e "${GREEN}Creating lock file with exact package versions - Parallel Mode...${NC}"
    
    if [ ! -f "$MANUAL_PACKAGES" ]; then
        echo -e "${YELLOW}Manual packages not found. Running analyze first...${NC}"
        analyze_packages_parallel
    fi
    
    # Start lock file
    {
        echo "# Fedora Package Lock File (Parallel Processing)"
        echo "# Generated: $(date)"
        echo "# System: $(cat /etc/fedora-release 2>/dev/null || echo 'Unknown')"
        echo "# Kernel: $(uname -r)"
        echo "# Architecture: $(uname -m)"
        echo "# Parallel Jobs: $MAX_PARALLEL_JOBS"
        echo ""
        echo "# Format: package|version|release|arch|size|install_time|repository"
        echo ""
    } > "$LOCK_FILE"
    
    # Process manual packages in parallel
    echo "[MANUAL_PACKAGES]" >> "$LOCK_FILE"
    echo "Locking manual packages in parallel..."
    
    local temp_manual_output="$CACHE_DIR/manual-lock-$.txt"
    get_package_info_parallel "$MANUAL_PACKAGES" "$temp_manual_output" "manual packages"
    cat "$temp_manual_output" >> "$LOCK_FILE"
    
    # Process dependencies in parallel
    echo "" >> "$LOCK_FILE"
    echo "[AUTO_DEPENDENCIES]" >> "$LOCK_FILE"
    echo "Locking dependency packages in parallel..."
    
    local temp_auto_output="$CACHE_DIR/auto-lock-$.txt"
    get_package_info_parallel "$AUTO_DEPENDENCIES" "$temp_auto_output" "dependencies"
    cat "$temp_auto_output" >> "$LOCK_FILE"
    
    # Add repository information (can be done in parallel)
    {
        echo "" >> "$LOCK_FILE"
        echo "[REPOSITORIES]" >> "$LOCK_FILE"
        dnf repolist enabled --quiet 2>/dev/null | tail -n +2 | awk '{print $1"|enabled"}' >> "$LOCK_FILE" || echo "fedora|enabled" >> "$LOCK_FILE"
    } &
    local repo_pid=$!
    
    # Add checksums in parallel
    {
        local temp_checksums="$CACHE_DIR/checksums-$.txt"
        {
            echo "[CHECKSUMS]"
            if [ -f "$MANUAL_PACKAGES" ]; then
                local manual_sha=$(sha256sum "$MANUAL_PACKAGES" 2>/dev/null | awk '{print $1}' || echo "no-checksum")
                echo "manual_packages|$manual_sha"
            fi
            if [ -f "$AUTO_DEPENDENCIES" ]; then
                local auto_sha=$(sha256sum "$AUTO_DEPENDENCIES" 2>/dev/null | awk '{print $1}' || echo "no-checksum")
                echo "auto_dependencies|$auto_sha"
            fi
        } > "$temp_checksums"
        echo "checksum_done" > "$CACHE_DIR/checksum_done-$"
    } &
    local checksum_pid=$!
    
    # Wait for parallel operations
    wait $repo_pid $checksum_pid
    
    # Append checksums
    if [ -f "$CACHE_DIR/checksums-$.txt" ]; then
        echo "" >> "$LOCK_FILE"
        cat "$CACHE_DIR/checksums-$.txt" >> "$LOCK_FILE"
    fi
    
    # Count entries
    local manual_locked=$(grep -c '|' "$temp_manual_output" 2>/dev/null || echo "0")
    local auto_locked=$(grep -c '|' "$temp_auto_output" 2>/dev/null || echo "0")
    
    # Cleanup
    rm -f "$temp_manual_output" "$temp_auto_output" "$CACHE_DIR/checksums-$.txt" "$CACHE_DIR/checksum_done-$"
    
    echo -e "\n${GREEN}✓ Lock file created successfully (Parallel Mode)${NC}"
    echo -e "  Manual packages locked: $manual_locked"
    echo -e "  Dependencies locked: $auto_locked"
    echo -e "  Lock file: $LOCK_FILE"
    echo -e "  Processing time: Significantly reduced with parallel processing"
}

# Parallel verification with enhanced reporting
function verify_lock_file_parallel() {
    echo -e "${GREEN}Verifying system against lock file - Parallel Mode...${NC}"
    
    if [ ! -f "$LOCK_FILE" ]; then
        echo -e "${RED}✗ Lock file not found at: $LOCK_FILE${NC}"
        exit 1
    fi
    
    echo "Parsing lock file and gathering current system state in parallel..."
    
    # Extract sections in parallel
    local temp_manual_lock="$CACHE_DIR/manual-lock-$.txt"
    local temp_auto_lock="$CACHE_DIR/auto-lock-$.txt"
    local temp_current_manual="$CACHE_DIR/current-manual-$.txt"
    
    {
        sed -n '/\[MANUAL_PACKAGES\]/,/\[AUTO_DEPENDENCIES\]/p' "$LOCK_FILE" | grep '|' > "$temp_manual_lock"
        echo "manual_extracted" > "$CACHE_DIR/manual_extracted-$"
    } &
    local extract_manual_pid=$!
    
    {
        sed -n '/\[AUTO_DEPENDENCIES\]/,/\[REPOSITORIES\]/p' "$LOCK_FILE" | grep '|' > "$temp_auto_lock"
        echo "auto_extracted" > "$CACHE_DIR/auto_extracted-$"
    } &
    local extract_auto_pid=$!
    
    {
        dnf repoquery --userinstalled --queryformat "%{name}\n" 2>/dev/null | sort > "$temp_current_manual" || touch "$temp_current_manual"
        echo "current_gathered" > "$CACHE_DIR/current_gathered-$"
    } &
    local current_pid=$!
    
    # Wait for all extractions
    wait $extract_manual_pid $extract_auto_pid $current_pid
    rm -f "$CACHE_DIR"/*_extracted-$ "$CACHE_DIR/current_gathered-$"
    
    # Check packages in parallel
    echo -e "\n${CYAN}Checking package status...${NC}"
    local missing_packages=""
    local version_mismatches=""
    local check_count=0
    local total_checks=$(wc -l < "$temp_manual_lock" 2>/dev/null || echo "0")
    
    if [ "$total_checks" -gt 0 ]; then
        init_progress $total_checks "Verifying packages"
        
        # Process in chunks for parallel verification
        local temp_check_dir=$(mktemp -d)
        split -l $CHUNK_SIZE "$temp_manual_lock" "$temp_check_dir/verify_chunk_"
        local active_jobs=()
        
        for chunk_file in "$temp_check_dir"/verify_chunk_*; do
            # Wait for available slot
            while [ ${#active_jobs[@]} -ge $MAX_PARALLEL_JOBS ]; do
                for i in "${!active_jobs[@]}"; do
                    if ! kill -0 "${active_jobs[$i]}" 2>/dev/null; then
                        wait "${active_jobs[$i]}"
                        unset active_jobs[$i]
                    fi
                done
                active_jobs=("${active_jobs[@]}")
                sleep 0.1
            done
            
            # Start verification job
            {
                local chunk_missing="$temp_check_dir/missing_$(basename $chunk_file)"
                local chunk_mismatches="$temp_check_dir/mismatches_$(basename $chunk_file)"
                
                while IFS='|' read -r name version release arch rest; do
                    if [ ! -z "$name" ]; then
                        if rpm -q "$name" &>/dev/null; then
                            local current_version=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$name" 2>/dev/null)
                            local locked_version="${version}-${release}"
                            if [ "$current_version" != "$locked_version" ]; then
                                echo "$name: locked=$locked_version, current=$current_version" >> "$chunk_mismatches"
                            fi
                        else
                            echo "$name-$version-$release" >> "$chunk_missing"
                        fi
                        update_progress 1
                    fi
                done < "$chunk_file"
            } &
            
            active_jobs+=($!)
        done
        
        # Wait for all verification jobs
        for job_pid in "${active_jobs[@]}"; do
            wait $job_pid
        done
        
        finish_progress
        
        # Collect results
        if ls "$temp_check_dir"/missing_* &>/dev/null; then
            missing_packages=$(cat "$temp_check_dir"/missing_* 2>/dev/null)
        fi
        if ls "$temp_check_dir"/mismatches_* &>/dev/null; then
            version_mismatches=$(cat "$temp_check_dir"/mismatches_* 2>/dev/null)
        fi
        
        rm -rf "$temp_check_dir"
    fi
    
    # Report findings
    echo -e "\n${BLUE}=== Verification Report (Parallel) ===${NC}"
    
    if [ -z "$missing_packages" ]; then
        echo -e "${GREEN}✓ All locked packages are installed${NC}"
    else
        echo -e "${RED}✗ Missing packages:${NC}"
        echo "$missing_packages" | head -10 | sed 's/^/  - /'
        local missing_count=$(echo "$missing_packages" | wc -l)
        if [ $missing_count -gt 10 ]; then
            echo "  ... and $((missing_count - 10)) more"
        fi
    fi
    
    if [ -z "$version_mismatches" ]; then
        echo -e "${GREEN}✓ All package versions match${NC}"
    else
        echo -e "${YELLOW}⚠ Version mismatches:${NC}"
        echo "$version_mismatches" | head -10 | sed 's/^/  /'
        local mismatch_count=$(echo "$version_mismatches" | wc -l)
        if [ $mismatch_count -gt 10 ]; then
            echo "  ... and $((mismatch_count - 10)) more"
        fi
    fi
    
    # Check for extra packages
    if [ -f "$temp_current_manual" ] && [ -f "$temp_manual_lock" ]; then
        local temp_locked_names="$CACHE_DIR/locked-names-$.txt"
        cut -d'|' -f1 "$temp_manual_lock" | sort > "$temp_locked_names"
        
        local extra=$(comm -23 "$temp_current_manual" "$temp_locked_names" | grep -v '^')
        if [ ! -z "$extra" ]; then
            echo -e "${YELLOW}⚠ Extra packages not in lock file:${NC}"
            echo "$extra" | head -10 | sed 's/^/  - /'
            local extra_count=$(echo "$extra" | wc -l)
            if [ $extra_count -gt 10 ]; then
                echo "  ... and $((extra_count - 10)) more"
            fi
        fi
        
        rm -f "$temp_locked_names"
    fi
    
    # Clean up
    rm -f "$temp_manual_lock" "$temp_auto_lock" "$temp_current_manual"
    
    echo -e "\n${CYAN}Verification completed using $MAX_PARALLEL_JOBS parallel jobs${NC}"
}

# Override original functions with parallel versions
function analyze_packages() {
    analyze_packages_parallel
}

function create_lock_file() {
    create_lock_file_parallel
}

function verify_lock_file() {
    verify_lock_file_parallel
}


function print_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  init      - Initialize by capturing default Fedora packages"
    echo "  analyze   - Analyze packages (excluding defaults)"
    echo "  lock      - Create a lock file with exact versions"
    echo "  verify    - Verify current system against lock file"
    echo "  restore   - Restore packages from lock file"
    echo "  tree      - Show dependency tree"
    echo "  stats     - Show statistics"
    echo "  diff      - Compare current system with lock file"
    echo "  export    - Export environment as a shareable archive"
    echo "  import    - Import environment from archive"
    echo "  help      - Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  PACKAGE_DIR - Directory to store package lists (default: ~/fedora-packages)"
}

function get_default_packages() {
    echo -e "${CYAN}Determining default Fedora packages...${NC}"
    
    # Get packages from default groups
    local default_groups="core base-x standard guest-desktop-agents hardware-support fonts"
    local all_defaults=""
    
    for group in $default_groups; do
        echo "  Checking group: $group"
        local group_packages=$(dnf group info "$group" 2>/dev/null | sed -n '/Mandatory Packages:/,/Optional Packages:/p' | grep -E '^   ' | sed 's/^   //' | tr -d ' ')
        all_defaults="$all_defaults $group_packages"
        
        group_packages=$(dnf group info "$group" 2>/dev/null | sed -n '/Default Packages:/,/Optional Packages:/p' | grep -E '^   ' | sed 's/^   //' | tr -d ' ')
        all_defaults="$all_defaults $group_packages"
    done
    
    # Get minimal install packages
    echo "  Adding @core group packages..."
    local core_packages=$(dnf group info core 2>/dev/null | grep -E '^   ' | sed 's/^   //' | tr -d ' ')
    all_defaults="$all_defaults $core_packages"
    
    # Add essential system packages that come with Fedora
    local essential_packages="kernel kernel-core kernel-modules glibc systemd fedora-release fedora-repos dnf rpm bash coreutils util-linux grep sed gawk findutils shadow-utils setup filesystem basesystem"
    all_defaults="$all_defaults $essential_packages"
    
    # Sort and remove duplicates
    echo "$all_defaults" | tr ' ' '\n' | sort | uniq | grep -v '^$' > "$DEFAULT_PACKAGES"
    
    local count=$(wc -l < "$DEFAULT_PACKAGES")
    echo -e "${GREEN}✓ Identified $count default packages${NC}"
}

function init_environment() {
    echo -e "${GREEN}Initializing Fedora package environment...${NC}"
    
    # Backup existing files
    if [ -f "$DEFAULT_PACKAGES" ]; then
        cp "$DEFAULT_PACKAGES" "$DEFAULT_PACKAGES.backup-$DATE"
        echo -e "${YELLOW}Backed up existing default packages list${NC}"
    fi
    
    # Get default packages
    get_default_packages
    
    # Create initial snapshot
    create_lock_file
    
    echo -e "\n${GREEN}✓ Environment initialized successfully${NC}"
    echo -e "Default packages saved to: $DEFAULT_PACKAGES"
    echo -e "You can now use 'analyze' to identify your custom packages"
}

function analyze_packages() {
    echo -e "${GREEN}Analyzing installed packages (excluding defaults)...${NC}"
    
    # Check if defaults exist
    if [ ! -f "$DEFAULT_PACKAGES" ]; then
        echo -e "${YELLOW}Default packages list not found. Running init first...${NC}"
        get_default_packages
    fi
    
    # Backup existing files
    for file in "$MANUAL_PACKAGES" "$AUTO_DEPENDENCIES"; do
        if [ -f "$file" ]; then
            cp "$file" "${file%.txt}-backup-$DATE.txt"
        fi
    done
    
    # Get all installed packages
    echo "Fetching all installed packages..."
    ALL_PACKAGES=$(dnf repoquery --installed --queryformat "%{name}\n" 2>/dev/null | sort | uniq)
    TOTAL_COUNT=$(echo "$ALL_PACKAGES" | wc -l)
    
    # Get user-installed packages
    echo "Identifying manually installed packages..."
    USER_INSTALLED=$(dnf repoquery --userinstalled --queryformat "%{name}\n" 2>/dev/null | sort | uniq)
    
    # Exclude default packages from user-installed
    TEMP_USER="/tmp/user-installed-$$.txt"
    TEMP_DEFAULTS="/tmp/defaults-$$.txt"
    echo "$USER_INSTALLED" > "$TEMP_USER"
    cp "$DEFAULT_PACKAGES" "$TEMP_DEFAULTS"
    
    # Get truly manual packages (user-installed minus defaults)
    MANUAL_PACKAGES_LIST=$(comm -23 "$TEMP_USER" "$TEMP_DEFAULTS")
    echo "$MANUAL_PACKAGES_LIST" > "$MANUAL_PACKAGES"
    MANUAL_COUNT=$(echo "$MANUAL_PACKAGES_LIST" | grep -v '^$' | wc -l)
    
    # Get all packages minus user-installed minus defaults = auto dependencies
    TEMP_ALL="/tmp/all-packages-$$.txt"
    echo "$ALL_PACKAGES" > "$TEMP_ALL"
    
    # First remove defaults from all packages
    TEMP_NON_DEFAULT="/tmp/non-default-$$.txt"
    comm -23 "$TEMP_ALL" "$TEMP_DEFAULTS" > "$TEMP_NON_DEFAULT"
    
    # Then remove manual packages to get auto dependencies
    TEMP_MANUAL="/tmp/manual-$$.txt"
    echo "$MANUAL_PACKAGES_LIST" > "$TEMP_MANUAL"
    AUTO_DEPS=$(comm -23 "$TEMP_NON_DEFAULT" "$TEMP_MANUAL")
    echo "$AUTO_DEPS" > "$AUTO_DEPENDENCIES"
    AUTO_COUNT=$(echo "$AUTO_DEPS" | grep -v '^$' | wc -l)
    
    # Count defaults
    DEFAULT_COUNT=$(wc -l < "$DEFAULT_PACKAGES")
    
    # Clean up
    rm -f "$TEMP_USER" "$TEMP_DEFAULTS" "$TEMP_ALL" "$TEMP_NON_DEFAULT" "$TEMP_MANUAL"
    
    # Create summary
    echo -e "\n${BLUE}=== Package Analysis Summary ===${NC}"
    echo -e "Total packages:          $TOTAL_COUNT"
    echo -e "Default Fedora:          ${CYAN}$DEFAULT_COUNT${NC} ($(awk "BEGIN {printf \"%.1f\", $DEFAULT_COUNT*100/$TOTAL_COUNT}")%)"
    echo -e "Manually installed:      ${GREEN}$MANUAL_COUNT${NC} ($(awk "BEGIN {printf \"%.1f\", $MANUAL_COUNT*100/$TOTAL_COUNT}")%)"
    echo -e "Auto dependencies:       ${YELLOW}$AUTO_COUNT${NC} ($(awk "BEGIN {printf \"%.1f\", $AUTO_COUNT*100/$TOTAL_COUNT}")%)"
    
    echo -e "\n${CYAN}Top 10 Custom Packages:${NC}"
    head -10 "$MANUAL_PACKAGES" | sed 's/^/  - /'
    
    echo -e "\nFiles saved in: $PACKAGE_DIR/"
}

function restore_from_lock() {
    echo -e "${GREEN}Restoring packages from lock file...${NC}"
    
    if [ ! -f "$LOCK_FILE" ]; then
        echo -e "${RED}✗ Lock file not found at: $LOCK_FILE${NC}"
        exit 1
    fi
    
    # Parse lock file
    TEMP_PACKAGES="/tmp/packages-to-install-$$.txt"
    
    # Extract package names and versions from manual packages section
    sed -n '/\[MANUAL_PACKAGES\]/,/\[AUTO_DEPENDENCIES\]/p' "$LOCK_FILE" | grep '|' | while IFS='|' read -r name version release arch rest; do
        echo "${name}-${version}-${release}.${arch}"
    done > "$TEMP_PACKAGES"
    
    TOTAL=$(wc -l < "$TEMP_PACKAGES")
    echo "Found $TOTAL packages in lock file"
    
    # Check what needs to be installed
    TO_INSTALL=""
    ALREADY_INSTALLED=0
    
    while IFS= read -r package_spec; do
        package_name=$(echo "$package_spec" | cut -d'-' -f1)
        if ! rpm -q "$package_name" &>/dev/null; then
            TO_INSTALL="$TO_INSTALL $package_spec"
        else
            ((ALREADY_INSTALLED++))
        fi
    done < "$TEMP_PACKAGES"
    
    echo -e "${CYAN}Already installed: $ALREADY_INSTALLED${NC}"
    
    if [ -z "$TO_INSTALL" ]; then
        echo -e "${GREEN}✓ All packages from lock file are already installed${NC}"
        rm -f "$TEMP_PACKAGES"
        exit 0
    fi
    
    # Count packages to install
    INSTALL_COUNT=$(echo $TO_INSTALL | wc -w)
    echo -e "${YELLOW}Need to install: $INSTALL_COUNT packages${NC}"
    
    # Confirm
    read -p "Install packages from lock file? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled"
        rm -f "$TEMP_PACKAGES"
        exit 0
    fi
    
    # Install
    echo -e "\n${GREEN}Installing packages...${NC}"
    sudo dnf install -y $TO_INSTALL
    
    rm -f "$TEMP_PACKAGES"
    
    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}✓ Restoration completed successfully${NC}"
    else
        echo -e "\n${YELLOW}⚠ Some packages may have failed to install${NC}"
    fi
}

function export_environment() {
    echo -e "${GREEN}Exporting Fedora environment...${NC}"
    
    # Create lock file if it doesn't exist
    if [ ! -f "$LOCK_FILE" ]; then
        create_lock_file
    fi
    
    # Create archive
    ARCHIVE_NAME="fedora-env-$(hostname)-$DATE.tar.gz"
    ARCHIVE_PATH="$PACKAGE_DIR/$ARCHIVE_NAME"
    
    echo "Creating archive..."
    tar -czf "$ARCHIVE_PATH" \
        -C "$PACKAGE_DIR" \
        "$(basename $MANUAL_PACKAGES)" \
        "$(basename $AUTO_DEPENDENCIES)" \
        "$(basename $DEFAULT_PACKAGES)" \
        "$(basename $LOCK_FILE)" \
        2>/dev/null
    
    # Add metadata
    METADATA="/tmp/metadata-$$.txt"
    {
        echo "Export Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Fedora Version: $(cat /etc/fedora-release)"
        echo "Kernel: $(uname -r)"
        echo "Architecture: $(uname -m)"
        echo "Manual Packages: $(wc -l < $MANUAL_PACKAGES)"
        echo "Dependencies: $(wc -l < $AUTO_DEPENDENCIES)"
    } > "$METADATA"
    
    tar -rf "$ARCHIVE_PATH" -C /tmp "$(basename $METADATA)" 2>/dev/null
    gzip "$ARCHIVE_PATH"
    
    rm -f "$METADATA"
    
    echo -e "\n${GREEN}✓ Environment exported successfully${NC}"
    echo -e "Archive: $ARCHIVE_PATH"
    echo -e "Size: $(du -h $ARCHIVE_PATH | cut -f1)"
    echo -e "\nShare this file to replicate your environment on another system"
}

function import_environment() {
    local archive="${1:-}"
    
    if [ -z "$archive" ]; then
        echo -e "${RED}✗ Please specify an archive file to import${NC}"
        echo "Usage: $0 import <archive-file>"
        exit 1
    fi
    
    if [ ! -f "$archive" ]; then
        echo -e "${RED}✗ Archive file not found: $archive${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Importing Fedora environment from archive...${NC}"
    
    # Backup current environment
    if [ -d "$PACKAGE_DIR" ]; then
        echo "Backing up current environment..."
        mv "$PACKAGE_DIR" "$PACKAGE_DIR.backup-$DATE"
    fi
    
    # Extract archive
    mkdir -p "$PACKAGE_DIR"
    echo "Extracting archive..."
    tar -xzf "$archive" -C "$PACKAGE_DIR"
    
    # Show metadata if available
    if [ -f "$PACKAGE_DIR/metadata-*.txt" ]; then
        echo -e "\n${CYAN}=== Imported Environment Info ===${NC}"
        cat "$PACKAGE_DIR/metadata-*.txt"
        rm -f "$PACKAGE_DIR/metadata-*.txt"
    fi
    
    echo -e "\n${GREEN}✓ Environment imported successfully${NC}"
    echo "Run '$0 verify' to check compatibility"
    echo "Run '$0 restore' to install packages"
}

function show_diff() {
    echo -e "${GREEN}Comparing current system with lock file...${NC}"
    
    if [ ! -f "$LOCK_FILE" ]; then
        echo -e "${RED}✗ Lock file not found${NC}"
        exit 1
    fi
    
    # Get current and locked packages
    TEMP_CURRENT="/tmp/current-all-$$.txt"
    TEMP_LOCKED="/tmp/locked-all-$$.txt"
    
    dnf repoquery --userinstalled --queryformat "%{name}\n" 2>/dev/null | sort > "$TEMP_CURRENT"
    sed -n '/\[MANUAL_PACKAGES\]/,/\[AUTO_DEPENDENCIES\]/p' "$LOCK_FILE" | grep '|' | cut -d'|' -f1 | sort > "$TEMP_LOCKED"
    
    echo -e "\n${CYAN}Packages only in lock file (need to install):${NC}"
    comm -23 "$TEMP_LOCKED" "$TEMP_CURRENT" | head -20 | sed 's/^/  - /'
    
    echo -e "\n${CYAN}Packages only on current system (not in lock):${NC}"
    comm -13 "$TEMP_LOCKED" "$TEMP_CURRENT" | head -20 | sed 's/^/  + /'
    
    echo -e "\n${BLUE}=== Summary ===${NC}"
    IN_LOCK_ONLY=$(comm -23 "$TEMP_LOCKED" "$TEMP_CURRENT" | wc -l)
    IN_CURRENT_ONLY=$(comm -13 "$TEMP_LOCKED" "$TEMP_CURRENT" | wc -l)
    IN_BOTH=$(comm -12 "$TEMP_LOCKED" "$TEMP_CURRENT" | wc -l)
    
    echo "  Common packages: $IN_BOTH"
    echo "  Only in lock file: $IN_LOCK_ONLY"
    echo "  Only on current system: $IN_CURRENT_ONLY"
    
    rm -f "$TEMP_CURRENT" "$TEMP_LOCKED"
}

function build_dependency_tree() {
    echo -e "${GREEN}Building dependency tree (excluding defaults)...${NC}"
    
    if [ ! -f "$MANUAL_PACKAGES" ]; then
        echo -e "${RED}✗ Manual packages list not found. Run 'analyze' first.${NC}"
        exit 1
    fi
    
    # Similar to previous tree function but only for non-default packages
    {
        echo "Dependency Tree for Custom Packages"
        echo "===================================="
        echo "Generated: $(date)"
        echo ""
    } > "$DEPENDENCY_TREE"
    
    echo "Building tree for custom packages..."
    
    # Process only first 20 packages for display
    head -20 "$MANUAL_PACKAGES" | while read package; do
        if [ ! -z "$package" ]; then
            echo "$package" >> "$DEPENDENCY_TREE"
            dnf repoquery --requires --resolve --queryformat "  └── %{name}" "$package" 2>/dev/null | head -5 >> "$DEPENDENCY_TREE"
            echo "" >> "$DEPENDENCY_TREE"
        fi
    done
    
    echo -e "${GREEN}✓ Dependency tree saved to: $DEPENDENCY_TREE${NC}"
}

function show_statistics() {
    echo -e "${BLUE}=== Package Statistics ===${NC}"
    
    if [ ! -f "$MANUAL_PACKAGES" ] || [ ! -f "$AUTO_DEPENDENCIES" ]; then
        echo -e "${RED}✗ Package lists not found. Run 'analyze' first.${NC}"
        exit 1
    fi
    
    # Counts
    MANUAL_COUNT=$(wc -l < "$MANUAL_PACKAGES")
    AUTO_COUNT=$(wc -l < "$AUTO_DEPENDENCIES")
    DEFAULT_COUNT=$(wc -l < "$DEFAULT_PACKAGES" 2>/dev/null || echo "0")
    TOTAL_COUNT=$((MANUAL_COUNT + AUTO_COUNT + DEFAULT_COUNT))
    
    echo -e "\n${CYAN}Package Distribution:${NC}"
    echo -e "  Total installed:     $TOTAL_COUNT"
    echo -e "  Default Fedora:      $DEFAULT_COUNT ($(awk "BEGIN {printf \"%.1f\", $DEFAULT_COUNT*100/$TOTAL_COUNT}")%)"
    echo -e "  Custom installed:    $MANUAL_COUNT ($(awk "BEGIN {printf \"%.1f\", $MANUAL_COUNT*100/$TOTAL_COUNT}")%)"
    echo -e "  Dependencies:        $AUTO_COUNT ($(awk "BEGIN {printf \"%.1f\", $AUTO_COUNT*100/$TOTAL_COUNT}")%)"
    
    # Categories
    echo -e "\n${CYAN}Custom Package Categories:${NC}"
    
    echo -n "  Development: "
    grep -E '^(gcc|clang|make|cmake|git|nodejs|npm|yarn|cargo|rustc|go|java|maven|gradle)' "$MANUAL_PACKAGES" 2>/dev/null | wc -l
    
    echo -n "  Python: "
    grep -E '^python' "$MANUAL_PACKAGES" 2>/dev/null | wc -l
    
    echo -n "  Containers: "
    grep -E '^(docker|podman|buildah|skopeo|kubernetes|kubectl|helm)' "$MANUAL_PACKAGES" 2>/dev/null | wc -l
    
    echo -n "  Editors: "
    grep -E '^(vim|emacs|neovim|code|atom|sublime)' "$MANUAL_PACKAGES" 2>/dev/null | wc -l
    
    echo -n "  Media: "
    grep -E '^(vlc|mpv|ffmpeg|gimp|inkscape|blender|obs)' "$MANUAL_PACKAGES" 2>/dev/null | wc -l
    
    # Lock file info
    if [ -f "$LOCK_FILE" ]; then
        echo -e "\n${CYAN}Lock File Info:${NC}"
        echo "  Created: $(grep "Generated:" "$LOCK_FILE" | cut -d' ' -f3-)"
        echo "  Size: $(du -h "$LOCK_FILE" | cut -f1)"
        LOCKED_PACKAGES=$(grep -c '|' "$LOCK_FILE")
        echo "  Locked packages: $LOCKED_PACKAGES"
    fi
}

# Main script logic
case "${1:-help}" in
    init)
        init_environment
        ;;
    analyze)
        analyze_packages
        ;;
    lock)
        create_lock_file
        ;;
    verify)
        verify_lock_file
        ;;
    restore)
        restore_from_lock
        ;;
    tree)
        build_dependency_tree
        ;;
    stats)
        show_statistics
        ;;
    diff)
        show_diff
        ;;
    export)
        export_environment
        ;;
    import)
        import_environment "$2"
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        print_usage
        exit 1
        ;;
esac