

# Library of common, shared utility functions.  This file is intended
# to be sourced by other scripts, not called directly.

# Global details persist here
source /etc/environment  # not always loaded under all circumstances

# Under some contexts these values are not set, make sure they are.
USER="$(whoami)"
export HOME="$(getent passwd $USER | cut -d : -f 6)"
[[ -n "$UID" ]] || UID=$(getent passwd $USER | cut -d : -f 3)
GID=$(getent passwd $USER | cut -d : -f 4)

# Essential default paths, many are overridden when executing under Cirrus-CI
# others are duplicated here, to assist in debugging.
export GOPATH="${GOPATH:-/var/tmp/go}"
if type -P go &> /dev/null
then
    # required for go 1.12+
    export GOCACHE="${GOCACHE:-$HOME/.cache/go-build}"
    eval "$(go env)"
    # required by make and other tools
    export $(go env | cut -d '=' -f 1)

    # Ensure compiled tooling is reachable
    export PATH="$PATH:$GOPATH/bin"
fi
CIRRUS_WORKING_DIR="${CIRRUS_WORKING_DIR:-$GOPATH/src/github.com/containers/storage}"
export GOSRC="${GOSRC:-$CIRRUS_WORKING_DIR}"
export PATH="$HOME/bin:$GOPATH/bin:/usr/local/bin:$PATH"
SCRIPT_BASE=${GOSRC}/contrib/cirrus

cd $GOSRC
if type -P git &> /dev/null
then
    CIRRUS_CHANGE_IN_REPO=${CIRRUS_CHANGE_IN_REPO:-$(git show-ref --hash=8 HEAD || date +%s)}
else # pick something unique and obviously not from Cirrus
    CIRRUS_CHANGE_IN_REPO=${CIRRUS_CHANGE_IN_REPO:-no_git_$(date +%s)}
fi

export CI="${CI:-false}"
CIRRUS_CI="${CIRRUS_CI:-false}"
CONTINUOUS_INTEGRATION="${CONTINUOUS_INTEGRATION:-false}"
CIRRUS_REPO_NAME=${CIRRUS_REPO_NAME:-storage}
CIRRUS_BASE_SHA=${CIRRUS_BASE_SHA:-unknown$(date +%s)}  # difficult to reliably discover
CIRRUS_BUILD_ID=${CIRRUS_BUILD_ID:-$RANDOM$(date +%s)}  # must be short and unique

# Unsafe env. vars for display
SECRET_ENV_RE='(IRCID)|(ACCOUNT)|(^GC[EP]..+)|(SSH)'

# GCE image-name compatible string representation of distribution name
OS_RELEASE_ID="$(source /etc/os-release; echo $ID)"
# GCE image-name compatible string representation of distribution _major_ version
OS_RELEASE_VER="$(source /etc/os-release; echo $VERSION_ID | cut -d '.' -f 1)"
# Combined to ease soe usage
OS_REL_VER="${OS_RELEASE_ID}-${OS_RELEASE_VER}"

# Working with dnf + timeout/retry
export SHORT_DNFY='timeout_attempt_delay_command 120s 5 30s dnf -y'
export LONG_DNFY='timeout_attempt_delay_command 300s 5 60s dnf -y'
# Working with apt under Debian/Ubuntu automation is a PITA, make it easy
# Avoid some ways of getting stuck waiting for user input
export DEBIAN_FRONTEND=noninteractive
# Short-cut for frequently used base command
export SUDOAPTGET='sudo -E apt-get -q --yes'
# Short list of packages or quick-running command
SHORT_APTGET="timeout_attempt_delay_command 120s 5 60s $SUDOAPTGET"
# Long list / long-running command
LONG_APTGET="timeout_attempt_delay_command 300s 5 60s $SUDOAPTGET"

# Packaging adjustments needed to:
# https://github.com/containers/libpod/blob/master/contrib/cirrus/packer/fedora_setup.sh
RPMS_REQUIRED="autoconf automake parallel"
RPMS_CONFLICTING="gcc-go"
# https://github.com/containers/libpod/blob/master/contrib/cirrus/packer/ubuntu_setup.sh
DEBS_REQUIRED="parallel"
DEBS_CONFLICTING=""

# For devicemapper testing, device names need to be passed down for use in tests
if [[ "$TEST_DRIVER" == "devicemapper" ]]; then
    DM_LVM_VG_NAME="test_vg"
    DM_REF_FILEPATH="/root/volume_group_ready"
else
    unset DM_LVM_VG_NAME DM_REF_FILEPATH
fi

# Pass in a list of one or more envariable names; exit non-zero with
# helpful error message if any value is empty
req_env_var() {
    # Provide context. If invoked from function use its name; else script name
    local caller=${FUNCNAME[1]}
    if [[ -n "$caller" ]]; then
        # Indicate that it's a function name
        caller="$caller()"
    else
        # Not called from a function: use script name
        caller=$(basename $0)
    fi

    # Usage check
    [[ -n "$1" ]] || die 1 "FATAL: req_env_var: invoked without arguments"

    # Each input arg is an envariable name, e.g. HOME PATH etc. Expand each.
    # If any is empty, bail out and explain why.
    for i; do
        if [[ -z "${!i}" ]]; then
            die 9 "FATAL: $caller requires \$$i to be non-empty"
        fi
    done
}

show_env_vars() {
    echo "Showing selection of environment variable definitions:"
    _ENV_VAR_NAMES=$(awk 'BEGIN{for(v in ENVIRON) print v}' | \
        egrep -v "(^PATH$)|(^BASH_FUNC)|(^[[:punct:][:space:]]+)|$SECRET_ENV_RE" | \
        sort -u)
    for _env_var_name in $_ENV_VAR_NAMES
    do
        # Supports older BASH versions
        printf "    ${_env_var_name}=%q\n" "$(printenv $_env_var_name)"
    done
}

die() {
    echo "************************************************"
    echo ">>>>> ${2:-FATAL ERROR (but no message given!) in ${FUNCNAME[1]}()}"
    echo "************************************************"
    exit ${1:-1}
}

bad_os_id_ver() {
    echo "Unknown/Unsupported distro. $OS_RELEASE_ID and/or version $OS_RELEASE_VER for $(basename $0)"
    exit 42
}

timeout_attempt_delay_command() {
    TIMEOUT=$1
    ATTEMPTS=$2
    DELAY=$3
    shift 3
    CMD=$(echo "$@" | tr --squeeze-repeats '\r\n\v\t' ' ')
    STDOUTERR=$(mktemp -p '' $(basename $0)_XXXXX)
    req_env_var ATTEMPTS DELAY
    echo "Retrying $ATTEMPTS times with a $DELAY delay, and $TIMEOUT timeout for command: $CMD"
    for (( COUNT=1 ; COUNT <= $ATTEMPTS ; COUNT++ ))
    do
        echo "##### (attempt #$COUNT)" &>> "$STDOUTERR"
        if timeout --foreground $TIMEOUT $CMD &>> "$STDOUTERR"
        then
            echo "##### (success after #$COUNT attempts)" &>> "$STDOUTERR"
            break
        else
            echo "##### (failed with exit: $?)" &>> "$STDOUTERR"
            sleep $DELAY
        fi
    done
    cat "$STDOUTERR"
    rm -f "$STDOUTERR"
    if (( COUNT > $ATTEMPTS ))
    then
        echo "##### (exceeded $ATTEMPTS attempts)"
        exit 125
    fi
}

# Helper/wrapper script to only show stderr/stdout on non-zero exit
install_ooe() {
    req_env_var SCRIPT_BASE
    echo "Installing script to mask stdout/stderr unless non-zero exit."
    sudo install -D -m 755 "$SCRIPT_BASE/ooe.sh" /usr/local/bin/ooe.sh
}

install_fuse_overlayfs_from_git(){
    wd=$(pwd)
    DEST="$GOPATH/src/github.com/containers/fuse-overlayfs"
    rm -rf "$DEST"
    ooe.sh git clone https://github.com/containers/fuse-overlayfs.git "$DEST"
    cd "$DEST"
    ooe.sh git fetch origin --tags
    ooe.sh ./autogen.sh
    ooe.sh ./configure
    ooe.sh make
    sudo make install prefix=/usr
    cd $wd
}

install_bats_from_git(){
    git clone https://github.com/bats-core/bats-core --depth=1
    sudo ./bats-core/install.sh /usr
    rm -rf bats-core
    mkdir -p ~/.parallel
    touch ~/.parallel/will-cite
}

showrun() {
    if [[ "$1" == "--background" ]]
    then
        shift
        # Properly escape any nested spaces, so command can be copy-pasted
        echo '+ '$(printf " %q" "$@")' &' > /dev/stderr
        "$@" &
        echo -e "${RED}<backgrounded>${NOR}"
    else
        echo '--------------------------------------------------'
        echo '+ '$(printf " %q" "$@") > /dev/stderr
        "$@"
    fi
}

devicemapper_setup() {
    req_env_var TEST_DRIVER DM_LVM_VG_NAME DM_REF_FILEPATH
    # Requires add_second_partition.sh to have already run successfully
    if [[ -r "/root/second_partition_ready" ]]
    then
        device=$(< /root/second_partition_ready)
        if [[ -n "$device" ]] # LVM setup should only ever happen once
        then
            echo "Setting up LVM PV on $device to validate it's functional"
            showrun pvcreate --force --yes "$device"
            echo "Wiping LVM signatures from $device to prepare it for testing use"
            showrun pvremove --force --yes "$device"
            # Block setup from happening ever again
            truncate --size=0 /root/second_partition_ready  # mark completion|in-use
            echo "$device" > "$DM_REF_FILEPATH"
        fi
        echo "Test device $(cat $DM_REF_FILEPATH) is ready to go."
    else
        echo "WARNING: Can't read /root/second_partition_ready, created by $(dirname $0)/add_second_partition.sh"
    fi
}
