#!/bin/bash

# check if the shell is bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script requires bash. Please run it with bash. For example:"
    echo "bash ./proxy.sh"
    exit 1
fi

set -u # Exit on unset variables

readonly TOOL_DEPS=(curl gzip chmod setsid grep kill ps cat mkdir)
readonly UNZIP_DEP_ALTERNATIVES=(unzip 7z bsdtar python3 jar)
UNZIP_DEP="UNSET"
readonly GITHUB_PROXIES=(
    "" # Direct connection
    https://gh-proxy.net/
    https://gh.llkk.cc/
    https://tvv.tw/
    https://github.xxlab.tech/
    https://gh.felicity.ac.cn/
)
readonly GITHUB_SPEEDTEST_URL="https://raw.githubusercontent.com/microsoft/vscode/main/LICENSE.txt"

COLOR_GREEN=""
COLOR_RED=""
COLOR_YELLOW=""
COLOR_NORMAL=""
COLOR_UNDERLINE=""
COLOR_BOLD=""
setup_color_support() {
    # check if the stdout is a terminal
    if [[ ! -t 1 ]]; then
        return 1
    fi
    # check if the terminal supports color
    if ! command -v tput >/dev/null 2>&1; then
        return 1
    fi
    local ncolors
    ncolors=$(tput colors)
    if [[ "$ncolors" -lt 8 ]]; then
        return 1
    fi
    # get color codes
    COLOR_GREEN=$(tput setaf 2)
    COLOR_RED=$(tput setaf 1)
    COLOR_YELLOW=$(tput setaf 3)
    COLOR_NORMAL=$(tput sgr0)
    COLOR_UNDERLINE=$(tput smul)
    COLOR_BOLD=$(tput bold)
    return 0
}

# Log with indent
# Usage: log "level" "message"
LOG_INDENT=0
log() {
    local _log_level="$1"
    local _log_message="$2"
    case "$_log_level" in
    "DEBUG")
        _log_level="${COLOR_GREEN}DEBUG${COLOR_NORMAL}"
        ;;
    "INFO")
        _log_level="${COLOR_GREEN}INFO${COLOR_NORMAL}"
        ;;
    "SUCCESS")
        _log_level="${COLOR_GREEN}SUCCESS${COLOR_NORMAL}"
        ;;
    "WARN")
        _log_level="${COLOR_YELLOW}WARN${COLOR_NORMAL}"
        ;;
    "ERROR")
        _log_level="${COLOR_RED}ERROR${COLOR_NORMAL}"
        ;;
    *)
        _log_level="${COLOR_NORMAL}$_log_level${COLOR_NORMAL}"
        ;;
    esac
    if [[ $LOG_INDENT -eq 0 ]]; then
        printf "[%s] %s\n" "$_log_level" "$_log_message" >&2
    else
        local _log_minus_count=$((LOG_INDENT - 3)) # how many "-"s in " -> "
        printf "[%s] " "$_log_level" >&2
        for (( _log_i = 0; _log_i < _log_minus_count; _log_i++ )); do
            printf "-" >&2
        done
        printf "> %s\n" "$_log_message" >&2
    fi
}
log_sublevel_start() { (( LOG_INDENT += 4 )); }
log_sublevel_end() { (( LOG_INDENT -= 4 )); }

# Check dependencies.
# Usage: check_dep [<dependency command>]
# Returns: 0 if <dependency command> is provided and exists, 1 if it doesn't exist.
# If <dependency command> is not provided, checks all dependencies in TOOL_DEPS and UNZIP_DEP_ALTERNATIVES. Exit directly if any of them is not found.
check_dep() {
    if [[ "$#" -gt 0 ]]; then
        # Check specific dependency
        local dep="$1"
        if ! command -v "$dep" >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi

    for dep in "${TOOL_DEPS[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            log "ERROR" "Tool $dep is not installed. Please install it and try again."
            exit 1
        fi
    done
    for dep in "${UNZIP_DEP_ALTERNATIVES[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            UNZIP_DEP="$dep"
            break
        fi
    done
    if [[ "$UNZIP_DEP" == "UNSET" ]]; then
        log "ERROR" "No unzip tool found. Please install one of the following: ${UNZIP_DEP_ALTERNATIVES[*]}."
        exit 1
    fi
}

smart_unzip() {
    local file="$1"
    local dest="$2"
    case "$UNZIP_DEP" in
    unzip)
        command unzip -o "$file" -d "$dest"
        ;;
    7z)
        command 7z x -y "$file" -o"$dest"
        ;;
    bsdtar)
        # bsdtar requires the dest to be created before extraction
        mkdir -p "$dest" # -p: --parents
        command bsdtar -xf "$file" -C "$dest" # -x: --extract, -f: --file, -C: --directory
        ;;
    python3)
        command python3 -m zipfile --extract "$file" "$dest"
        ;;
    jar)
        command jar xf "$file" -C "$dest" # x: --extract, f: --file
        ;;
    UNSET)
        log "ERROR" "No unzip tool found. Please install one of the following: ${UNZIP_DEP_ALTERNATIVES[*]}."
        exit 1
        ;;
    esac
}

FASTEST_GITHUB_PROXY="UNSET"
github_proxy_select() {
    if [[ "$FASTEST_GITHUB_PROXY" != "UNSET" ]]; then
        # Already selected
        return
    fi

    # Check if persistent selection exists
    if [[ -f "proxy-data/github_proxy_selection" ]]; then
        local selection
        selection=$(<"proxy-data/github_proxy_selection")
        if [[ -n "$selection" ]]; then
            # Use the persistent selection
            if [[ "$selection" =~ ^[0-9]+$ ]]; then
                if [[ $selection -ge 0 && $selection -lt ${#GITHUB_PROXIES[@]} ]]; then
                    FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$selection]}"
                    log "INFO" "Using saved GitHub proxy selection: ${FASTEST_GITHUB_PROXY:-Direct connection}"
                    return
                fi
            else
                log "ERROR" "Invalid saved GitHub proxy selection: $selection. Removing it."
                rm -f "proxy-data/github_proxy_selection" # -f: --force
            fi
        fi
    fi

    log "INFO" "Testing GitHub proxy speeds..."
    log_sublevel_start
    
    local min_time=10.0
    local min_index=0
    local times=()
    local available_proxies=()
    local available_proxy_indices=()

    # Test each proxy
    for i in "${!GITHUB_PROXIES[@]}"; do
        local proxy="${GITHUB_PROXIES[$i]}"
        local curl_time
        local proxy_name="${proxy:-Direct connection}"
        
        if ! curl_time=$(curl --silent --fail --location --output /dev/null --max-time 3 --write-out "%{time_total}" "$proxy$GITHUB_SPEEDTEST_URL"); then
            log "WARN" "Proxy '$proxy_name' is not available"
            times+=("N/A")
            continue
        fi

        log "INFO" "Proxy '$proxy_name' time: $curl_time s"
        times+=("$curl_time")
        available_proxies+=("$proxy")
        available_proxy_indices+=("$i")
        
        if [[ "$(compare_floats "$curl_time" "$min_time")" == "<" ]]; then
            min_time="$curl_time"
            min_index="$i"
        fi
    done
    log_sublevel_end
    
    if [[ ${#available_proxies[@]} -eq 0 ]]; then
        log "ERROR" "No GitHub proxy available"
        exit 1
    fi
    
    # Display options to user
    echo
    log "INFO" "Please select a GitHub proxy:"
    log "INFO" "Available options:"
    for i in "${!available_proxy_indices[@]}"; do
        local idx="${available_proxy_indices[$i]}"
        local proxy="${GITHUB_PROXIES[$idx]}"
        local proxy_name="${proxy:-Direct connection}"
        log "INFO" "  $idx) $proxy_name (${times[$idx]} s)$([ "$idx" -eq "$min_index" ] && echo " (fastest)" || echo "")"
    done
    log "INFO" "Input options:"
    log "INFO" "  <number>   = Select this proxy for current session"
    log "INFO" "  <number>!  = Select this proxy and remember for future sessions"
    log "INFO" "  <empty>    = Use fastest proxy for current session"
    log "INFO" "  !          = Use fastest proxy and remember for future sessions"
    
    # Ask for user selection
    read -p "[QUESTION] Your choice: " -r user_choice
    
    # Process the selection
    local persistent=0
    if [[ "$user_choice" == *"!"* ]]; then
        persistent=1
        user_choice="${user_choice%!}"
    fi
    
    if [[ -z "$user_choice" ]]; then
        # Empty input, use fastest
        FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
        log "SUCCESS" "Selected fastest GitHub proxy: ${FASTEST_GITHUB_PROXY:-Direct connection}"
        if [[ $persistent -eq 1 ]]; then
            mkdir -p "proxy-data/"
            echo "$min_index" > "proxy-data/github_proxy_selection"
            log "INFO" "Note: This selection will be remembered for future sessions. If you want to reset, delete the ${COLOR_UNDERLINE}proxy-data/github_proxy_selection${COLOR_NORMAL} file."
        fi
    elif [[ "$user_choice" =~ ^[0-9]+$ ]]; then
        if [[ $user_choice -ge 0 && $user_choice -lt ${#GITHUB_PROXIES[@]} ]]; then
            FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$user_choice]}"
            log "SUCCESS" "Selected GitHub proxy: ${FASTEST_GITHUB_PROXY:-Direct connection}"
            if [[ $persistent -eq 1 ]]; then
                mkdir -p "proxy-data/"
                echo "$user_choice" > "proxy-data/github_proxy_selection"
                log "INFO" "This selection will be remembered for future sessions"
            fi
        else
            log "ERROR" "Invalid selection. Using fastest proxy."
            FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
        fi
    else
        log "ERROR" "Invalid selection. Using fastest proxy."
        FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
    fi
}

# Download something with Ctrl+C trap.
# If the download is interrupted, it will clean up the partially downloaded file.
# Usage: download_with_cleanup <url> <output_file>
download_with_cleanup() {
    local url="$1"
    local output_file="$2"

    trap 'rm -f "$output_file"; echo; log "ERROR" "Download interrupted. Cleaned up partially downloaded file: $output_file"; exit 1' INT
    curl --fail --location "$url" --output "$output_file"
    local _status="$?"
    # Remove the trap
    trap - INT

    return $_status
}

# Obtain Mihomo-specific OS name to build the download URL
obtain_mihomo_os() {
    local mihomo_os
    case "$MACHTYPE" in
    *darwin*)
        mihomo_os="darwin"
        ;;
    *linux*)
        mihomo_os="linux"
        ;;
    *)
        log "ERROR" "Unsupported OS: $MACHTYPE"
        exit 1
        ;;
    esac
    echo "$mihomo_os"
}

# Obtain Mihomo-specific architecture name to build the download URL
obtain_mihomo_arch() {
    local mihomo_arch
    case "$MACHTYPE" in
    x86_64-* | x86_64 | amd64-* | amd64)
        mihomo_arch="amd64"
        ;;
    aarch64-* | aarch64 | arm64-* | arm64 | armv8*-* | armv8*)
        mihomo_arch="arm64"
        ;;
    armv7*-* | armv7* | armhf*-* | armhf*)
        mihomo_arch="armv7"
        ;;
    riscv64-* | riscv64)
        mihomo_arch="riscv64"
        ;;
    i[3-6]86-* | i[3-6]86)
        mihomo_arch="386"
        ;;
    *)
        log "ERROR" "Unsupported architecture: $MACHTYPE"
        exit 1
        ;;
    esac
    echo "$mihomo_arch"
}

download_mihomo() {
    log "INFO" "Downloading Mihomo..."

    log_sublevel_start

    # 1. Fetch the latest version
    log "INFO" "Fetching the latest release info..."
    log_sublevel_start
    readonly MIHOMO_LATEST_VERSION_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/version.txt"
    local mihomo_latest_version
    if ! mihomo_latest_version=$(curl --silent --fail --location "$FASTEST_GITHUB_PROXY$MIHOMO_LATEST_VERSION_URL"); then
        log "ERROR" "Failed to fetch the latest release info"
        exit 1
    fi
    if [[ -z "$mihomo_latest_version" ]]; then
        log "ERROR" "The latest release info is empty"
        exit 1
    fi
    log "INFO" "Latest version: $mihomo_latest_version"
    log_sublevel_end

    # 2. Download
    log "INFO" "Downloading..."
    log_sublevel_start
    # shellcheck disable=SC2155
    readonly MIHOMO_DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/$mihomo_latest_version/mihomo-$(obtain_mihomo_os)-$(obtain_mihomo_arch)-$mihomo_latest_version.gz"
    log "INFO" "Download from: ${COLOR_UNDERLINE}$MIHOMO_DOWNLOAD_URL${COLOR_NORMAL}"
    if ! download_with_cleanup "$FASTEST_GITHUB_PROXY$MIHOMO_DOWNLOAD_URL" "proxy-data/mihomo.gz"; then
        log "ERROR" "Failed to download Mihomo"
        exit 1
    fi
    log "SUCCESS" "Downloaded to proxy-data/mihomo.gz"
    log_sublevel_end

    # 3. Unzip
    log "INFO" "Unzipping..."
    log_sublevel_start
    if ! gzip -df "proxy-data/mihomo.gz"; then # -d: --decompress, -f: --force
        log "ERROR" "Failed to unzip Mihomo"
        rm "proxy-data/mihomo" # Clean up on failure
        exit 1
    fi
    if ! chmod +x "proxy-data/mihomo"; then
        log "ERROR" "Failed to make mihomo executable"
        rm "proxy-data/mihomo" # Clean up on failure
        exit 1
    fi
    log "SUCCESS" "Unzipped to proxy-data/mihomo"
    log_sublevel_end

    log_sublevel_end
}

mihomo_exist() {
    if [[ -s "proxy-data/mihomo" ]]; then
        # Check if mihomo is executable
        if [[ ! -x "proxy-data/mihomo" ]]; then
            if ! chmod +x "proxy-data/mihomo"; then
                log "ERROR" "Mihomo exists but not executable and we failed to make it executable"
                exit 1
            fi
        fi
        if ./proxy-data/mihomo -v; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

download_metacubexd() {
    readonly METACUBEXD_DOWNLOAD_URL="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
    log "INFO" "Downloading metacubexd..."
    log_sublevel_start

    # 1. Download
    log "INFO" "Downloading..."
    log_sublevel_start
    log "INFO" "Download from: ${COLOR_UNDERLINE}$METACUBEXD_DOWNLOAD_URL${COLOR_NORMAL}"
    if ! download_with_cleanup "$FASTEST_GITHUB_PROXY$METACUBEXD_DOWNLOAD_URL" "proxy-data/metacubexd.zip"; then
        log "ERROR" "Failed to download metacubexd"
        exit 1
    fi
    log "SUCCESS" "Downloaded to proxy-data/metacubexd.zip"
    log_sublevel_end

    # 2. Unzip
    log "INFO" "Unzipping..."
    log_sublevel_start
    rm -rf "proxy-data/metacubexd/" # -r: --recursive, -f: --force
    if ! smart_unzip "proxy-data/metacubexd.zip" "proxy-data/metacubexd/"; then
        log "ERROR" "Failed to unzip metacubexd"
        rm -rf "proxy-data/metacubexd/" # Clean up on failure
        exit 1
    fi
    if [[ ! -d "proxy-data/metacubexd/" ]]; then
        log "ERROR" "Failed to unzip metacubexd"
        rm -rf "proxy-data/metacubexd/" # Clean up on failure
        exit 1
    fi
    log "SUCCESS" "Unzipped to proxy-data/metacubexd"
    # strip the first directory layer
    shopt -s nullglob dotglob
    local unarchived_file_list=("proxy-data/metacubexd/"*)
    if [[ ${#unarchived_file_list[@]} -eq 1 ]] && [[ -d "${unarchived_file_list[0]}" ]]; then
        log "INFO" "Stripping the first directory layer..."
        mv "${unarchived_file_list[0]}"/* "proxy-data/metacubexd/"
        rmdir "${unarchived_file_list[0]}"
    fi
    rm "proxy-data/metacubexd.zip"
    log_sublevel_end

    log_sublevel_end
}

download_geodata_if_necessary() {
    if [[ ! -f "proxy-data/config/geosite.dat" ]]; then
        github_proxy_select
        log "INFO" "Downloading geosite.dat..."
        log_sublevel_start
        readonly MIHOMO_GEOSITE_DOWNLOAD_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
        log "INFO" "Download from: ${COLOR_UNDERLINE}$MIHOMO_GEOSITE_DOWNLOAD_URL${COLOR_NORMAL}"
        if ! download_with_cleanup "$FASTEST_GITHUB_PROXY$MIHOMO_GEOSITE_DOWNLOAD_URL" "proxy-data/config/geosite.dat"; then
            log "WARN" "Failed to download geosite"
        else
            log "SUCCESS" "Downloaded to proxy-data/config/geosite.dat"
        fi
        log_sublevel_end
    fi

    if [[ ! -f "proxy-data/config/geoip.dat" ]]; then
        github_proxy_select
        log "INFO" "Downloading geoip.dat..."
        log_sublevel_start
        readonly MIHOMO_GEOIP_DOWNLOAD_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
        log "INFO" "Download from: ${COLOR_UNDERLINE}$MIHOMO_GEOIP_DOWNLOAD_URL${COLOR_NORMAL}"
        if ! download_with_cleanup "$FASTEST_GITHUB_PROXY$MIHOMO_GEOIP_DOWNLOAD_URL" "proxy-data/config/geoip.dat"; then
            log "WARN" "Failed to download geoip"
        else
            log "SUCCESS" "Downloaded to proxy-data/config/geoip.dat"
        fi
        log_sublevel_end
    fi

    if [[ ! -f "proxy-data/config/geoip.metadb" ]]; then
        github_proxy_select
        log "INFO" "Downloading geoip.metadb..."
        log_sublevel_start
        readonly MIHOMO_GEOIP_METADB_DOWNLOAD_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
        log "INFO" "Download from: ${COLOR_UNDERLINE}$MIHOMO_GEOIP_METADB_DOWNLOAD_URL${COLOR_NORMAL}"
        if ! download_with_cleanup "$FASTEST_GITHUB_PROXY$MIHOMO_GEOIP_METADB_DOWNLOAD_URL" "proxy-data/config/geoip.metadb"; then
            log "WARN" "Failed to download geoip.metadb"
        else
            log "SUCCESS" "Downloaded to proxy-data/config/geoip.metadb"
        fi
        log_sublevel_end
    fi
}

mihomo_status() {
    log "INFO" "Mihomo status:"
    log_sublevel_start

    find_by_tag mihomo
    if [[ "${#TAGGED_PIDS[@]}" -gt 0 ]]; then
        log "INFO" "Mihomo is running with pids: ${TAGGED_PIDS[*]}"
    else
        log "INFO" "Mihomo is not running"
    fi

    log_sublevel_end
}

daemon_run() {
    local tag=$1
    shift
    local output_file=$1
    shift
    local process_name_with_tag="proxy-sh-${tag}"
    # https://stackoverflow.com/questions/3430330/best-way-to-make-a-shell-script-daemon
    (
        umask 0
        # shellcheck disable=SC2016
        # Safety: should use single quotes here because we intend not to expand variables.
        setsid "$BASH" -c 'exec -a "$1" "${@:2}"' _ "$process_name_with_tag" "$@" </dev/null >>"$output_file" 2>&1 &
    ) &
}

TAGGED_PIDS=()
find_by_tag() {
    local tag=$1
    local process_name_with_tag="proxy-sh-${tag}"
    TAGGED_PIDS=()
    while IFS= read -r line; do
        local pid
        # read the first non-whitespace word
        read -r pid _ <<< "$line"
        
        # Skip the table header
        if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
            continue
        fi
        
        if [[ "$line" == *"$process_name_with_tag"* ]]; then
            TAGGED_PIDS+=("$pid")
        fi
    done < <(ps ax -o pid,command)
}

kill_by_tag() {
    local tag=$1
    find_by_tag "$tag"

    if [[ "${#TAGGED_PIDS[@]}" -gt 0 ]]; then
        log "INFO" "Killing pids: ${TAGGED_PIDS[*]}"
        kill -SIGTERM "${TAGGED_PIDS[@]}"
        return 0
    fi
    return 2
}

find_unused_port() {
    local LOW_BOUND=9090
    local RANGE=16384
    for ((i = 0; i < RANGE; i++)); do
        local CANDIDATE=$((LOW_BOUND + i))
        if ! (echo -n >/dev/tcp/127.0.0.1/${CANDIDATE}) >/dev/null 2>&1; then
            echo $CANDIDATE
            return 0
        fi
    done
    log "ERROR" "No available port found in the range $LOW_BOUND-$((LOW_BOUND + RANGE - 1))"
    return 1
}

usage() {
    cat >&2 <<EOF
Usage: $0 [status | stop | tunnel <port> | help | -h | --help | <subscription_url>]

Subcommands:
  help, -h, --help     Show this help message
  status               Show the status of Mihomo
  stop                 Stop Mihomo by killing the process  
  tunnel <port>        Tunnel localhost:<port> through a free service
  <subscription_url>   URL to download subscription config file. Can be "-" (input from stdin) or HTTP(S) URL.

If no argument is provided, the script will download, start Mihomo and Metacubexd, and ask for tunneling.
If subscription_url is provided, it will be downloaded to proxy-data/config/config.yaml.
EOF
}

arg_parse() {
    if [[ "$#" -eq 0 ]]; then
        return 0
    fi

    case $1 in
    help | -h | --help)
        usage
        exit 0
        ;;
    status)
        return 1
        ;;
    stop)
        return 2
        ;;
    tunnel)
        if [[ "$#" -ne 2 ]]; then
            log "ERROR" "Usage: $0 tunnel <port>"
            exit 1
        fi
        return 3
        ;;
    -)
        # Special case: read from stdin
        return 4
        ;;
    *)
        # Check if it's a URL (contains . or /)
        if [[ "$1" == *"."* ]] || [[ "$1" == *"/"* ]]; then
            return 4  # URL provided
        else
            usage
            exit 1
        fi
        ;;
    esac
}

readonly MIHOMO_USER_AGENT="mihomo.proxy.sh/v1.0 (clash.meta)"

download_subscription() {
    local subscription_url="$1"
    
    if [[ "$subscription_url" == "-" ]]; then
        log "INFO" "Reading subscription from stdin..."
        log_sublevel_start
        
        if read_config_from_stdin; then
            log_sublevel_end
            return
        else
            log "ERROR" "No valid content provided from stdin"
            exit 1
        fi
    fi
    
    log "INFO" "Downloading subscription from URL..."
    log_sublevel_start
    
    # Add http:// prefix if not present
    if [[ ! "$subscription_url" =~ ^https?:// ]]; then
        subscription_url="https://$subscription_url"
        log "INFO" "Added https:// prefix to URL"
    fi
    
    log "INFO" "Download from: ${COLOR_UNDERLINE}$subscription_url${COLOR_NORMAL}"
    local temp_config
    if ! temp_config=$(curl --fail --location --user-agent "$MIHOMO_USER_AGENT" "$subscription_url" --output -); then
        log "ERROR" "Failed to download subscription. The original config file will be kept unchanged."
        exit 1
    fi

    # Save to file only if download is successful
    echo "$temp_config" > "proxy-data/config/config.yaml"
    log "SUCCESS" "Downloaded to proxy-data/config/config.yaml"
    
    log_sublevel_end
}

is_config_valid() {
    local config_file="$1"
    if [[ -f "$config_file" ]] && [[ -s "$config_file" ]]; then
        if grep -qE "^(proxies|proxy-groups|rules):" "$config_file" 2>/dev/null; then # -q: --quiet, -E: --extended-regexp
            return 0
        fi
    fi
    return 1
}

read_config_from_stdin() {
    log "INFO" "Please input your config content below (press Ctrl+D on a new line to finish):"
    local temp_config
    temp_config=$(cat)
    # Check if input is not empty (ignore whitespace-only content)
    if [[ -n "${temp_config// }" ]] && [[ -n "${temp_config//$'\n'}" ]]; then
        echo "$temp_config" > "proxy-data/config/config.yaml"
        log "SUCCESS" "Config saved to proxy-data/config/config.yaml"
        return 0
    else
        return 1
    fi
}

handle_subscription_config() {
    local subscription_url="$1"
    
    if [[ -n "$subscription_url" ]]; then
        # URL provided (including "-" for stdin), always process regardless of existing config
        download_subscription "$subscription_url"
    else
        # No URL provided, check if we have a valid config file
        if ! is_config_valid "proxy-data/config/config.yaml"; then
            # No valid config file, ask user
            read -p "[QUESTION] No valid config file found. Do you want to input config content manually? (y/n) " -n 1 -r input_choice
            echo
            if [[ $input_choice == [yY] ]]; then
                if ! read_config_from_stdin; then
                    log "WARN" "No valid content input, keeping existing config file unchanged"
                fi
            else
                log "WARN" "Skipping config input. You may need to put your subscription file at proxy-data/config/config.yaml and restart Mihomo."
            fi
        else
            log "INFO" "Valid config file already exists at proxy-data/config/config.yaml"
        fi
    fi
}

# Parse the `mixed-port`` (or fall back to `port` if not set) in the config file
parse_mixed_port() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    local mixed_port=""
    while IFS= read -r line; do
        # Check for mixed-port: first
        if [[ "$line" == *"mixed-port:"* ]]; then
            mixed_port="${line#*mixed-port:}"
            mixed_port="${mixed_port// /}"
            mixed_port="${mixed_port%%[^0-9]*}"
            break
        fi
        
        # If no mixed-port found, check for port:
        if [[ -z "$mixed_port" && "$line" == *"port:"* ]]; then
            mixed_port="${line#*port:}"
            mixed_port="${mixed_port// /}"
            mixed_port="${mixed_port%%[^0-9]*}"
        fi
    done < "$config_file"
    if [[ -z "$mixed_port" ]]; then
        return 1  # No mixed-port or port found
    fi
    echo "$mixed_port"
    return 0
}

# Write out the environment setup script which can be sourced to set up the proxy, and print usage instructions
write_out_env_setup_script() {
    local mixed_port="$1"

    cat > "proxy-data/on" <<-EOF
#!/bin/bash
# Environment setup script for proxy.sh
export http_proxy="http://127.0.0.1:$mixed_port"
export HTTP_PROXY=\$http_proxy

export https_proxy=\$http_proxy
export HTTPS_PROXY=\$http_proxy

export all_proxy=\$http_proxy
export ALL_PROXY=\$http_proxy
EOF
    
    cat > "proxy-data/off" <<-EOF
#!/bin/bash
# Environment teardown script for proxy.sh
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY
EOF

    chmod +x "proxy-data/on" "proxy-data/off"
    log "SUCCESS" "${COLOR_BOLD}Environment setup script written to proxy-data/on and proxy-data/off${COLOR_NORMAL}"
    log "INFO" "Note: You can ${COLOR_UNDERLINE}source proxy-data/on${COLOR_NORMAL} to set up the proxy environment, and ${COLOR_UNDERLINE}source proxy-data/off${COLOR_NORMAL} to unset it."
}

main() {
    if setup_color_support; then
        log "DEBUG" "Terminal supports color"
    else
        log "DEBUG" "Terminal does not support color"
    fi

    if [[ "$EUID" -eq 0 ]]; then
        if [[ ! -f "proxy-data/do_as_root" ]]; then
            log "WARN" "You are running this script as root. This is usually NOT recommended because of security and permission issues."
            log "WARN" "Please run this script as a normal user if possible."
            read -p "[QUESTION] Do you REALLY want to continue as root? (y/n) " -n 1 -r continue_choice
            echo
            if [[ $continue_choice != [yY] ]]; then
                exit 0
            fi
            # Create the marker file to skip this warning in the future
            mkdir -p "proxy-data"
            echo > "proxy-data/do_as_root"
            log "DEBUG" "Created proxy-data/do_as_root. This warning will not be shown again."
        fi
    fi

    check_dep

    # parse arguments
    arg_parse "$@"
    local arg_parse_result=$?
    local subscription_url=""
    case $arg_parse_result in
    1)
        mihomo_status
        exit 0
        ;;
    2)
        kill_by_tag mihomo
        exit 0
        ;;
    3)
        try_tunnel_service "$2"
        exit 0
        ;;
    4)
        if [[ "$#" -gt 0 ]]; then
            subscription_url="$1"
        fi
        ;;
    esac

    # no arguments or URL provided, start Mihomo
    mkdir -p "proxy-data/"

    if mihomo_version_output=$(mihomo_exist); then
        log "INFO" "Mihomo already exists, skip downloading. Version: "
        echo "$mihomo_version_output"
    else
        github_proxy_select
        download_mihomo
    fi

    if [[ -d "proxy-data/metacubexd/" ]]; then
        log "INFO" "metacubexd already exists, skip downloading."
    else
        github_proxy_select
        download_metacubexd
    fi

    mkdir -p "proxy-data/config"
    download_geodata_if_necessary

    kill_by_tag mihomo
    
    handle_subscription_config "$subscription_url"
    
    if ext_port=$(find_unused_port); then
        log "INFO" "Found unused port: $ext_port"
    else
        log "ERROR" "Failed to find an unused port"
        exit 1
    fi
    daemon_run mihomo ./proxy-data/mihomo.log ./proxy-data/mihomo -d "proxy-data/config" -ext-ctl "0.0.0.0:$ext_port" -ext-ui "$(resolve_existing_dir "proxy-data/metacubexd")"

    log "SUCCESS" "${COLOR_BOLD}Mihomo started in the background!${COLOR_NORMAL}"
    log "INFO" "Note: You can access the web UI at ${COLOR_UNDERLINE}http://<server-ip>:$ext_port/ui${COLOR_NORMAL}. Use ${COLOR_UNDERLINE}http://<server-ip>:$ext_port/${COLOR_NORMAL} as the control server address in the WebUI."
    
    if is_config_valid "proxy-data/config/config.yaml"; then
        log "INFO" "Config file is ready at proxy-data/config/config.yaml"
    else
        log "WARN" "Config file is not found or invalid. You may need to put your subscription file at proxy-data/config/config.yaml and restart Mihomo."
    fi

    local mihomo_mixed_port=""
    if mihomo_mixed_port=$(parse_mixed_port "proxy-data/config/config.yaml"); then
        log "INFO" "Mihomo mixed-port is set to: $mihomo_mixed_port"
        write_out_env_setup_script "$mihomo_mixed_port"
    else
        log "WARN" "Mihomo mixed-port is not set in the config file. You may need to set it manually in proxy-data/config/config.yaml and restart Mihomo."
        log "WARN" "    The environment setup script is not written because mixed-port is unknown."
    fi
    
    me=${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}
    log "INFO" "To stop Mihomo, run: $me stop"

    # ask user whether to tunnel the WebUI through free service
    read -p "[QUESTION] Do you want to tunnel the WebUI through a free service, so that you can access it remotely? (y/n) " -n 1 -r tunnel_choice
    echo
    if [[ $tunnel_choice == [yY] ]]; then
        try_tunnel_service "$ext_port"
    else
        log "INFO" "Skipping tunneling."
    fi
}


# ==== Tunneling the WebUI through a free service ====
try_tunnel_service() {
    tunnel_ask_next_or_exit() {
        local service_name=$1
        shift
        local exit_code=$1
        log "WARN" "Tunneling through $service_name exited with code $exit_code. Because we cannot have any assumptions about the exit code, we don't know if it was successful."
        read -p "[QUESTION] Do you want to try next service? Press n if you want to exit. (y/n)" -n 1 -r next_service_choice
        echo
        if [[ $next_service_choice == [yY] ]]; then
            return 0
        fi
        return 1
    }

    local tunnel_port=$1

    log "INFO" "Tunneling the WebUI through a free service..."
    log_sublevel_start
    # check ssh
    if ! check_dep ssh; then
        log "ERROR" "SSH is not installed. Please install it and try again."
        log_sublevel_end
        return 1
    fi
    
    log "INFO" "${COLOR_BOLD}Quick Guide: How to use the tunneled WebUI:${COLOR_NORMAL}"
    log "INFO" "  1. After the tunnel is established, find a line like ${COLOR_UNDERLINE}Forwarding domain: https://<the-service-random-subdomain>${COLOR_NORMAL} in the output."
    log "INFO" "  2. Use ${COLOR_UNDERLINE}https://<the-service-random-subdomain>/ui${COLOR_NORMAL} to access the WebUI."
    log "INFO" "  3. Input ${COLOR_UNDERLINE}https://<the-service-random-subdomain>/${COLOR_NORMAL} as the control server address in the WebUI."
    readonly SSH_DEFAULT_PARAMS=(
        -o StrictHostKeyChecking=no # skip host key checking
        -o ServerAliveInterval=30   # send keep-alive packets
        -o ConnectTimeout=5         # set connection timeout
    )
    # - tunnel through pinggy.io
    log "INFO" "Try tunneling through pinggy.io..."
    ssh -p 443 "${SSH_DEFAULT_PARAMS[@]}" -t -R0:localhost:"$tunnel_port" a.pinggy.io x:passpreflight
    if ! tunnel_ask_next_or_exit "pinggy.io" $?; then
        log_sublevel_end
        return
    fi

    # - tunnel through localhost.run
    log "INFO" "Try tunneling through localhost.run..."
    ssh "${SSH_DEFAULT_PARAMS[@]}" -R80:localhost:"$tunnel_port" nokey@localhost.run
    if ! tunnel_ask_next_or_exit "localhost.run" $?; then
        log_sublevel_end
        return
    fi

    # - tunnel through tunnl.gg
    log "INFO" "Try tunneling through tunnl.gg..."
    ssh "${SSH_DEFAULT_PARAMS[@]}" -R80:localhost:"$tunnel_port" proxy.tunnl.gg
    if ! tunnel_ask_next_or_exit "tunnl.gg" $?; then
        log_sublevel_end
        return
    fi

    # - tunnel through serveo.net
    log "INFO" "Try tunneling through serveo.net..."
    ssh "${SSH_DEFAULT_PARAMS[@]}" -R80:localhost:"$tunnel_port" serveo.net
    if ! tunnel_ask_next_or_exit "serveo.net" $?; then
        log_sublevel_end
        return
    fi

    log "ERROR" "All tunneling services failed. Please try again later."
    log_sublevel_end
    return 1
}

# ==== General Functions ====

# Compare two floating-point numbers in pure Bash.
# Usage: compare_floats NUM1 NUM2
# Output: '<', '=', or '>' to stdout
# Returns: 0 on success, 1 on invalid input
compare_floats() {
    local num1="$1" num2="$2"
    local float_regex='^-?[0-9]*\.?[0-9]+$|^-?\.[0-9]+$'

    # Validate input
    if ! [[ "$num1" =~ $float_regex && "$num2" =~ $float_regex ]]; then
        echo "Error: Invalid number format" >&2
        return 1
    fi

    # Extract signs
    local sign1="" sign2=""
    [[ "$num1" == -* ]] && sign1="-"
    [[ "$num2" == -* ]] && sign2="-"

    # Quick comparison when signs differ
    if [[ "$sign1" != "$sign2" ]]; then
        [[ "$sign1" == "-" ]] && echo "<" || echo ">"
        return 0
    fi

    # Remove signs for magnitude comparison
    num1="${num1#-}"
    num2="${num2#-}"

    # Split into integer and fractional parts
    local int1="${num1%%.*}" frac1="" int2="${num2%%.*}" frac2=""
    [[ "$num1" == *.* ]] && frac1="${num1#*.}"
    [[ "$num2" == *.* ]] && frac2="${num2#*.}"
    : "${int1:=0}" "${int2:=0}"

    # Pad fractional parts to equal length
    local len1=${#frac1} len2=${#frac2}
    while ((${#frac1} < len2)); do frac1+="0"; done
    while ((${#frac2} < len1)); do frac2+="0"; done

    # Combine and remove leading zeros for integer comparison
    local comp1="${int1}${frac1}" comp2="${int2}${frac2}"
    comp1="${comp1#"${comp1%%[!0]*}"}"
    comp2="${comp2#"${comp2%%[!0]*}"}"
    : "${comp1:=0}" "${comp2:=0}"

    # Compare magnitudes
    local result="="
    ((comp1 < comp2)) && result="<"
    ((comp1 > comp2)) && result=">"

    # Invert result for negative numbers
    if [[ "$sign1" == "-" && "$result" != "=" ]]; then
        [[ "$result" == "<" ]] && result=">" || result="<"
    fi

    echo "$result"
}

resolve_existing_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log "ERROR" "Directory does not exist: $dir"
        return 1
    fi

    (
        cd "$dir" >/dev/null 2>&1 || exit 1
        pwd -P # -P: physical path (resolve symlinks)
    )
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # only execute if this script is run directly
    main "$@"
fi
