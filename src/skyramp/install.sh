#!/usr/bin/env bash
set -u

MAX_USER_WATCHES="${MAX_USER_WATCHES:-524288}"
MAX_USER_INSTANCES="${MAX_USER_INSTANCES:-8192}"

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# CI=true bash -c "$(curl -fsSL https://skyramp-public.s3.us-west-2.amazonaws.com/installer.sh)"

echo "fs.inotify.max_user_watches=${MAX_USER_WATCHES}" |  tee -a /etc/sysctl.conf
echo "fs.inotify.max_user_instances=${MAX_USER_INSTANCES}" | tee -a /etc/sysctl.conf

if ! type docker > /dev/null 2>&1; then
    echo -e '\n(*) Warning: The docker command was not found.\n\nYou can use one of the following scripts to install it:\n\nhttps://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker-in-docker.md\n\nor\n\nhttps://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker.md'
fi

abort() {
  printf "%s\n" "$@"
  exit 1
}

# Fail fast with a concise message when not using bash
# Single brackets are needed here for POSIX compatibility
# shellcheck disable=SC2292

if [ -z "${BASH_VERSION:-}" ]
then
  abort "Bash is required to interpret this script."
fi

# Check if script is run with force-interactive mode in CI
if [[ -n "${CI-}" && -n "${INTERACTIVE-}" ]]
then
  abort "Cannot run force-interactive mode in CI."
fi

# Check if both `INTERACTIVE` and `NONINTERACTIVE` are set
# Always use single-quoted strings with `exp` expressions
# shellcheck disable=SC2016
if [[ -n "${INTERACTIVE-}" && -n "${NONINTERACTIVE-}" ]]
then
  abort 'Both `$INTERACTIVE` and `$NONINTERACTIVE` are set. Please unset at least one variable and try again.'
fi

# string formatters
if [[ -t 1 ]]
then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"
  do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")"
}


NONINTERACTIVE=1

# Print Header and ToC Acceptance
RED=$(tput setaf 1)
NORMAL=$(tput sgr0)
BLUE=$(tput setaf 4)
WHITE=$(tput setaf 7)


printf "

      _
 ___ | | _  _  _  _ ___ ___ _  _ __ ___   _ ___ 
/ __|| |/ /\ \/ /| '__/|___' || '_ ' _ \ | '__ \\
\__ \|   (  \  / | |   / __  || | | | | || |__) |
|___/|_|\_\ _)/  |_|   \___,_||_| |_| |_||  ___/
           |_/                           | | 
                                         |_|

\n"

printf "\nSkyramp is the easy way for cloud native developers to test and solve integration and performance bugs.\nShip code confidently with Skyramp!\n\n"

printf "This script will install Skyramp binaries on your machine.\n\n"

SKYRAMP_ON_LINUX=1

# Set oldest supported OS version
MACOS_OLDEST_SUPPORTED="11.0"
UBUNTU_OLDEST_SUPPORTED="18.04"
CENTOS_OLDEST_SUPPORTED="8.0"
FEDORA_OLDEST_SUPPORTED="36.0"


if [[ -z "${SKYRAMP_ON_LINUX-}" ]]
then
  UNAME_MACHINE="$(/usr/bin/uname -m)"
  STAT_PRINTF=("stat" "-f")
  PERMISSION_FORMAT="%A"
  CHOWN=("/usr/sbin/chown")
  CHGRP=("/usr/bin/chgrp")
  GROUP="admin"
  TOUCH=("/usr/bin/touch")
else
  UNAME_MACHINE="$(uname -m)"
  STAT_PRINTF=("stat" "--printf")
  PERMISSION_FORMAT="%a"
  CHOWN=("/bin/chown")
  CHGRP=("/bin/chgrp")
  GROUP="$(id -gn)"
  TOUCH=("/bin/touch")
fi
CHMOD=("/bin/chmod")
MKDIR=("/bin/mkdir" "-p")
SKYRAMP_PREFIX="/usr/local/bin"

REQUIRED_DOCKER_VERSION=20.10.0
REQUIRED_CURL_VERSION=7.58.0
REQUIRED_GIT_VERSION=2.20.5

unset HAVE_SUDO_ACCESS # unset this from the environment

have_sudo_access() {
  if [[ ! -x "/usr/bin/sudo" ]]
  then
    return 1
  fi

  local -a SUDO=("/usr/bin/sudo")
  if [[ -n "${SUDO_ASKPASS-}" ]]
  then
    SUDO+=("-A")
  elif [[ -n "${NONINTERACTIVE-}" ]]
  then
    SUDO+=("-n")
  fi

  if [[ -z "${HAVE_SUDO_ACCESS-}" ]]
  then
    "${SUDO[@]}" -l mkdir &>/dev/null
    HAVE_SUDO_ACCESS="$?"
  fi

  if [[ -z "${SKYRAMP_ON_LINUX-}" ]] && [[ "${HAVE_SUDO_ACCESS}" -ne 0 ]]
  then
    abort "Need sudo access on macOS (e.g. the user ${USER} needs to be an Administrator)!"
  fi

  return "${HAVE_SUDO_ACCESS}"
}

execute() {
  if ! "$@"
  then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}

execute_sudo() {
  local -a args=("$@")
  if have_sudo_access
  then
    if [[ -n "${SUDO_ASKPASS-}" ]]
    then
      args=("-A" "${args[@]}")
    fi
    ohai "/usr/bin/sudo" "${args[@]}"
    execute "/usr/bin/sudo" "${args[@]}"
  else
    ohai "${args[@]}"
    execute "${args[@]}"
  fi
}

getc() {
  local save_state
  save_state="$(/bin/stty -g)"
  /bin/stty raw -echo
  IFS='' read -r -n 1 -d '' "$@"
  /bin/stty "${save_state}"
}

ring_bell() {
  # Use the shell's audible bell.
  if [[ -t 1 ]]
  then
    printf "\a"
  fi
}

wait_for_user() {
  local c
  echo
  echo "Press ${tty_bold}RETURN${tty_reset} to continue or any other key to abort:"
  getc c
  if ! [[ "${c}" == $'\r' || "${c}" == $'\n' ]]
  then
    exit 1
  fi
}

major_minor() {
  echo "${1%%.*}.$(
    x="${1#*.}"
    echo "${x%%.*}"
  )"
}

version_gt() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -gt "${2#*.}" ]]
}
version_ge() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -ge "${2#*.}" ]]
}
version_lt() {
  [[ "${1%.*}" -lt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -lt "${2#*.}" ]]
}

get_permission() {
  "${STAT_PRINTF[@]}" "${PERMISSION_FORMAT}" "$1"
}

user_only_chmod() {
  [[ -d "$1" ]] && [[ "$(get_permission "$1")" != 75[0145] ]]
}

exists_but_not_writable() {
  [[ -e "$1" ]] && ! [[ -r "$1" && -w "$1" && -x "$1" ]]
}

get_owner() {
  "${STAT_PRINTF[@]}" "%u" "$1"
}

file_not_owned() {
  [[ "$(get_owner "$1")" != "$(id -u)" ]]
}

get_group() {
  "${STAT_PRINTF[@]}" "%g" "$1"
}

file_not_grpowned() {
  [[ " $(id -G "${USER}") " != *" $(get_group "$1") "* ]]
}

test_curl() {
  if [[ ! -x "$1" ]]
  then
    return 1
  fi

  local curl_version_output curl_name_and_version
  curl_version_output="$("$1" --version 2>/dev/null)"
  curl_name_and_version="${curl_version_output%% (*}"
  version_ge "$(major_minor "${curl_name_and_version##* }")" "$(major_minor "${REQUIRED_CURL_VERSION}")"
}

test_docker() {
  if [[ ! -x "$1" ]]
  then
    return 1
  fi
  local docker_version_output docker_version_without_build
  docker_version_output="$("$1" --version 2>/dev/null)"
  docker_version_without_build=${docker_version_output%,*}
  version_ge "$(major_minor "${docker_version_without_build##* }")" "$(major_minor "${REQUIRED_DOCKER_VERSION}")"
}

test_git() {
  if [[ ! -x "$1" ]]
  then
    return 1
  fi

  local git_version_output
  git_version_output="$("$1" --version 2>/dev/null)"
  version_ge "$(major_minor "${git_version_output##* }")" "$(major_minor "${REQUIRED_GIT_VERSION}")"
}

skyramp_version_check() {
  if [[ ! -x "$1" ]]
  then
    return 1
  fi

  local existing_skyramp_version
  local download_skyramp_version
  existing_skyramp_version="$("${SKYRAMP_PREFIX}"/skyramp version 2>/dev/null)"
  download_skyramp_version="$("${HOME}"/.skyramp/skyramp version 2>/dev/null)"
  version_ge "$(major_minor "${${download_skyramp_version%% *}#v}")" "$(major_minor "${${existing_skyramp_version%% *}#v}")"
}

which() {
  # Alias to Bash built-in command `type -P`
  type -P "$@"
}

# Search PATH for the specified program that satisfies Skyramp requirements
# function which is set above
# shellcheck disable=SC2230
find_tool() {
  if [[ $# -ne 1 ]]
  then
    return 1
  fi

  local executable
  while read -r executable
  do
    if "test_$1" "${executable}"
    then
      echo "${executable}"
      break
    fi
  done < <(which -a "$1")
}

skyramp_url_check() {
  if [[ $(execute "curl" "-I" "-s" "-o" "/dev/null" "-w" "%{http_code}" "$1") != 200 ]]
  then
    abort "Download error"
  else
    return 1
  fi
}

skyramp_file_download() {
  if [[ -z $(skyramp_url_check $1) ]]
  then
    execute_sudo "curl" "$1" "--output" "$2" >/dev/null
  else
    abort "Download error - please email support@skyramp.co with the URL $1"
  fi
}

skyramp_os_arch_download() {
  if [[ -z "${SKYRAMP_ON_LINUX-}" ]]
  then
    if [[ "${UNAME_MACHINE}" == "x86_64" ]]
    then
      skyramp_file_download "https://skyramp-public.s3.us-west-2.amazonaws.com/darwin-amd64/skyramp" "${HOME}/.skyramp/skyramp"
    elif [[  "${UNAME_MACHINE}" == "arm64" ]]
    then
      skyramp_file_download "https://skyramp-public.s3.us-west-2.amazonaws.com/darwin-arm64/skyramp" "${HOME}/.skyramp/skyramp"
    fi
  else
    if [[ "${UNAME_MACHINE}" == "x86_64" ]]
    then
      skyramp_file_download "https://skyramp-public.s3.us-west-2.amazonaws.com/linux-386/skyramp" "${HOME}/.skyramp/skyramp"
    elif [[ "${UNAME_MACHINE}" == "amd64" ]]
    then
      skyramp_file_download "https://skyramp-public.s3.us-west-2.amazonaws.com/linux-amd64/skyramp" "${HOME}/.skyramp/skyramp"
    fi
  fi
}

# USER isn't always set so provide a fall back for the installer and subprocesses.
if [[ -z "${USER-}" ]]
then
  USER="$(chomp "$(id -un)")"
  export USER
fi

# Invalidate sudo timestamp before exiting (if it wasn't active before).
if [[ -x /usr/bin/sudo ]] && ! /usr/bin/sudo -n -v 2>/dev/null
then
  trap '/usr/bin/sudo -k' EXIT
fi

if ! command -v git >/dev/null
then
  warn "You don't have Git installed. You will need Git to fully leverage Skyramp for testing."
elif [[ -n "${SKYRAMP_ON_LINUX-}" ]]
then
  USABLE_GIT="$(find_tool git)"
  if [[ -z "${USABLE_GIT}" ]]
  then
    warn "The version of Git that was found does not satisfy requirements for Skyramp."
    warn "Please install Git ${REQUIRED_GIT_VERSION} or newer and add it to your PATH."
  elif [[ "${USABLE_GIT}" != /usr/bin/git ]]
  then
    export SKYRAMP_GIT_PATH="${USABLE_GIT}"
    ohai "Found Git: ${SKYRAMP_GIT_PATH}"
  fi
fi

if ! command -v curl >/dev/null
then
  abort "$(
    cat <<EOABORT
You must install cURL before installing Skyramp.
EOABORT
  )"
elif [[ -n "${SKYRAMP_ON_LINUX-}" ]]
then
  USABLE_CURL="$(find_tool curl)"
  if [[ -z "${USABLE_CURL}" ]]
  then
    abort "$(
      cat <<EOABORT
The version of cURL that was found does not satisfy requirements for Skyramp.
Please install cURL ${REQUIRED_CURL_VERSION} or newer and add it to your PATH.
EOABORT
    )"
  elif [[ "${USABLE_CURL}" != /usr/bin/curl ]]
  then
    export SKYRAMP_CURL_PATH="${USABLE_CURL}"
    ohai "Found cURL: ${SKYRAMP_CURL_PATH}"
  fi
fi

if ! command -v docker >/dev/null
then
  warn "You must install a container run time before starting skyramp. Skyramp has been tested with Docker and Podman."
elif [[ -n "${SKYRAMP_ON_LINUX-}" ]]
then
  USABLE_DOCKER="$(find_tool docker)"
  if [[ -z "${USABLE_DOCKER}" ]]
  then
    warn "The version of Docker that was found does not satisfy requirements for Skyramp."
    warn "Please install Docker ${REQUIRED_DOCKER_VERSION} or newer and add it to your PATH."
    warn "See: ${tty_underline}https://docs.docker.com/get-docker/${tty_reset}"
  elif [[ "${USABLE_DOCKER}" != /usr/bin/docker ]]
  then
    export SKYRAMP_DOCKER_PATH="${USABLE_DOCKER}"
    ohai "Found Docker: ${SKYRAMP_DOCKER_PATH}"
  fi
fi

ohai 'Checking for `sudo` access (which may request your password)...'
have_sudo_access

if [[ -z "${SKYRAMP_ON_LINUX-}" ]]
then
  # On macOS, support 64-bit AMD and ARM
  if [[ "${UNAME_MACHINE}" != "arm64" ]] && [[ "${UNAME_MACHINE}" != "x86_64" ]]
  then
    abort "Skyramp is only supported on 64 bit Intel and ARM processors!"
  fi
else
  # On Linux, support 64-bit Intel and AMD
  if [[ "${UNAME_MACHINE}" != "x86_64" ]] && [[ "${UNAME_MACHINE}" != "amd64" ]]
  then
    abort "$(
      cat <<EOABORT
Skyramp on Linux is only supported on 64 bit Intel and AMD processors!
EOABORT
    )"
  fi
fi

if [[ -z "${SKYRAMP_ON_LINUX-}" ]]
then
  macos_version="$(major_minor "$(/usr/bin/sw_vers -productVersion)")"
  if version_lt "${macos_version}" "${MACOS_OLDEST_SUPPORTED}"
  then
    warn "You are using macOS ${macos_version}."
    warn "Skyramp does not provide support for this version and may not work correctly."
    ohai "Please upgrade to macOS ${MACOS_OLDEST_SUPPORTED} if possible!"
  fi
else
  ohai "Skyramp has been tested with Ubuntu ${UBUNTU_OLDEST_SUPPORTED}+, CentOS ${CENTOS_OLDEST_SUPPORTED}+ and Fedora ${FEDORA_OLDEST_SUPPORTED}+"
  ohai "If you are using an older version of the above Linux distributions or a different distribution, Skyramp may not work correctly."
fi

mkdir=""
if ! [[ -d "${HOME}/.skyramp" ]]
then
  mkdir=("${HOME}/.skyramp")
fi

if [[ -n "${mkdir}" ]]
then
  ohai "Creating directory:"
  printf "%s\n" "${mkdir}"
fi

if [[ -n "${mkdir}" ]]
then
  execute "${MKDIR}" "${mkdir}"
fi

ohai "Checking for Skyramp..."

if [[ -e "${SKYRAMP_PREFIX}/skyramp" ]]
then
  
  ohai "Looks like you already have Skyramp!"
  ohai "Continue to upgrade to latest..."

  if [[ -z "${NONINTERACTIVE-}" ]]
  then
    ring_bell
    wait_for_user
  fi

  skyramp_os_arch_download
  #Snippet to check for version can go here
  if [[ skyramp_version_check ]]
  then
    ohai "Updating the binary to the latest version..."
    execute_sudo "mv" "${HOME}/.skyramp/skyramp" "${SKYRAMP_PREFIX}" >/dev/null
  else
    ohai "Latest version of Skyramp is already installed!"
    execute_sudo "rm" "${HOME}/.skyramp/skyramp" >/dev/null
  fi

else
  
  ohai "This script will install: ${SKYRAMP_PREFIX}/skyramp"
  
  if [[ -z "${NONINTERACTIVE-}" ]]
  then
    ring_bell
    wait_for_user
  fi

  ohai "Downloading Skyramp..."
  skyramp_os_arch_download
  execute_sudo "mv" "${HOME}/.skyramp/skyramp" "${SKYRAMP_PREFIX}" >/dev/null

fi

if [[ -x "${SKYRAMP_PREFIX}/skyramp" ]]
then
  echo "Skyramp already executable"
else
  ohai "Installing..."
  execute_sudo "${CHMOD}" "+x" "${SKYRAMP_PREFIX}/skyramp" >/dev/null
fi

ohai "Creating resources file..."

if [[ -e "${HOME}/.skyramp/resources.yaml" ]]
then
  warn "Resources file already exists."
else
  skyramp_file_download "https://skyramp-public.s3.us-west-2.amazonaws.com/resources.yaml" "${HOME}/.skyramp/resources.yaml"
fi

execute_sudo "${CHMOD}" "-R" "ugo+rw" "${HOME}/.skyramp" >/dev/null

ohai "Installation complete!"
execute "skyramp" "version"

oi
