#!/bin/bash

# Configuration variables
mt5file='/config/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe'
WINEPREFIX='/config/.wine'
WINEDEBUG='-all'
wine_executable="wine"
metatrader_version="5.0.36"
mt5server_port="8001"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"
mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
python_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
mt5setup_url="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

# Function to display a graphical message
show_message() {
    echo $1
}

# Function to check if a dependency is installed
check_dependency() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 is not installed. Please install it to continue."
        exit 1
    fi
}

# Function to check if a Python package is installed
is_python_package_installed() {
    python3 -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
    return $?
}

# Function to check if a Python package is installed in Wine
is_wine_python_package_installed() {
    $wine_executable python -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
    return $?
}

# Check an installed package version without resolving its dependencies.
# The Linux mt5linux package is installed with --no-deps, so
# pkg_resources.require() would report a false negative on every start.
is_python_package_version_installed() {
    python3 -c "import importlib.metadata as m, sys; sys.exit(m.version('$1') != '$2')" 2>/dev/null
    return $?
}

# Same version-only check for the Python inside the Wine prefix.
is_wine_python_package_version_installed() {
    $wine_executable python -c "import importlib.metadata as m, sys; sys.exit(m.version('$1') != '$2')" 2>/dev/null
    return $?
}

# Check for necessary dependencies
check_dependency "curl"
check_dependency "$wine_executable"

# Wine registers its own debugger under AeDebug, which MetaTrader mistakes for
# an attached debugger ("A debugger has been found running in your system").
disable_wine_debugger() {
    $wine_executable reg delete "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /v Debugger /f >/dev/null 2>&1 || true
}

# Wine reports 96 DPI (100% scaling) by default, so MT5 keeps its normal 8-9 pt
# Windows UI. The browser only streams those pixels and does not apply display
# scaling, which makes the terminal tiny on large or high-resolution screens.
# Write the Windows scaling value into the prefix before MT5 starts.
# 96 = 100%, 120 = 125%, 144 = 150%, 168 = 175%. Override with MT5_DPI.
configure_dpi_scaling() {
    local dpi="${MT5_DPI:-144}"

    if ! [[ "$dpi" =~ ^[0-9]+$ ]] || [ "$dpi" -lt 96 ] || [ "$dpi" -gt 480 ]; then
        show_message "Invalid MT5_DPI '$dpi', using 144."
        dpi=144
    fi

    show_message "Setting Wine display scaling to ${dpi} DPI ($((dpi * 100 / 96))%)."
    $wine_executable reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null
    $wine_executable reg query "HKCU\\Control Panel\\Desktop" /v LogPixels
}

# Make sure the Wine prefix exists before writing into it. On a fresh /config
# volume drive_c does not exist yet, so downloads into it would fail.
if [ ! -d "/config/.wine/drive_c" ]; then
    show_message "Initializing Wine prefix..."
    $wine_executable wineboot --init >/dev/null 2>&1 || true
    $wine_executable wineserver -w >/dev/null 2>&1 || true
    mkdir -p "/config/.wine/drive_c"
fi
disable_wine_debugger
configure_dpi_scaling

# Install Mono if not present
if [ ! -e "/config/.wine/drive_c/windows/mono" ]; then
    show_message "[1/7] Downloading and installing Mono..."
    curl -fL -o /config/.wine/drive_c/mono.msi $mono_url
    WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i /config/.wine/drive_c/mono.msi /qn
    rm -f /config/.wine/drive_c/mono.msi
    show_message "[1/7] Mono installed."
else
    show_message "[1/7] Mono is already installed."
fi

# Check if MetaTrader 5 is already installed
if [ -e "$mt5file" ]; then
    show_message "[2/7] File $mt5file already exists."
else
    show_message "[2/7] File $mt5file is not installed. Installing..."

    # Set Windows 10 mode in Wine and download and install MT5
    $wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
    disable_wine_debugger
    show_message "[3/7] Downloading MT5 installer..."
    curl -o /config/.wine/drive_c/mt5setup.exe $mt5setup_url
    show_message "[3/7] Installing MetaTrader 5..."
    $wine_executable "/config/.wine/drive_c/mt5setup.exe" "/auto" &
    wait
    rm -f /config/.wine/drive_c/mt5setup.exe
fi

# Recheck if MetaTrader 5 is installed
if [ -e "$mt5file" ]; then
    show_message "[4/7] File $mt5file is installed. Running MT5..."
    disable_wine_debugger

    # Optional auto-login from environment variables. Only applied when no
    # explicit /config: option was provided via MT5_CMD_OPTIONS.
    if [ -n "${MT5_LOGIN:-}" ]; then
        case " $MT5_CMD_OPTIONS " in
            *" /config:"*) ;;
            *)
                mt5_ini="/config/.wine/drive_c/mt5-auto.ini"
                {
                    echo "[Common]"
                    echo "Login=${MT5_LOGIN}"
                    [ -n "${MT5_SERVER:-}" ] && echo "Server=${MT5_SERVER}"
                    [ -n "${MT5_PASSWORD:-}" ] && echo "Password=${MT5_PASSWORD}"
                    echo "KeepPrivate=1"
                } > "$mt5_ini"
                MT5_CMD_OPTIONS="$MT5_CMD_OPTIONS /config:C:\\mt5-auto.ini"
                show_message "[4/7] MT5 auto-login enabled for account ${MT5_LOGIN} (${MT5_SERVER:-default server})."
                ;;
        esac
    fi

    $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
    show_message "[4/7] File $mt5file is not installed. MT5 cannot be run."
fi


# Install Python in Wine if not present
if ! $wine_executable python --version 2>/dev/null; then
    show_message "[5/7] Installing Python in Wine..."
    curl -L $python_url -o /tmp/python-installer.exe
    $wine_executable /tmp/python-installer.exe /quiet InstallAllUsers=1 PrependPath=1
    rm /tmp/python-installer.exe
    show_message "[5/7] Python installed in Wine."
else
    show_message "[5/7] Python is already installed in Wine."
fi

# Upgrade pip and install required packages
show_message "[6/7] Installing Python libraries"
$wine_executable python -m pip install --upgrade --no-cache-dir pip
# Install MetaTrader5 library in Windows if not installed
show_message "[6/7] Installing MetaTrader5 library in Windows"
if ! is_wine_python_package_installed "MetaTrader5==$metatrader_version"; then
    $wine_executable python -m pip install --no-cache-dir MetaTrader5==$metatrader_version
fi
# Install mt5linux library in Windows if not installed
show_message "[6/7] Checking and installing mt5linux library in Windows if necessary"
if ! is_wine_python_package_version_installed "mt5linux" "0.1.9"; then
    # 0.1.9 is the last release that provides the server launcher used below.
    # 1.x needs Python 3.12+ and replaced the CLI, so an unpinned install breaks
    # on both the image's Python 3.11 and Wine's Python 3.9.
    $wine_executable python -m pip install --no-cache-dir "mt5linux==0.1.9"
fi

# Install python-dateutil if needed (datetime is built-in, but dateutil adds features)
if ! is_wine_python_package_installed "python-dateutil"; then
    show_message "[6/7] Installing python-dateutil library in Windows"
    $wine_executable python -m pip install --no-cache-dir python-dateutil
fi

# Install mt5linux library in Linux if not installed
show_message "[6/7] Checking and installing mt5linux library in Linux if necessary"
if ! is_python_package_version_installed "mt5linux" "0.1.9"; then
    # Pin 0.1.9: 1.x uses Python 3.12-only syntax and no longer supports the
    # `--host ... -p ... -w wine python.exe` launcher used below. Debian
    # bookworm ships Python 3.11, so an unpinned install crashes on startup.
    pip install --break-system-packages --no-cache-dir --no-deps "mt5linux==0.1.9" && \
    pip install --break-system-packages --no-cache-dir rpyc plumbum numpy
fi

# Install pyxdg library in Linux if not installed
show_message "[6/7] Checking and installing pyxdg library in Linux if necessary"
if ! is_python_package_installed "pyxdg"; then
    pip install --break-system-packages --no-cache-dir pyxdg
fi

# Start the MT5 server on Linux
show_message "[7/7] Starting the mt5linux server..."
python3 -m mt5linux --host 0.0.0.0 -p $mt5server_port -w $wine_executable python.exe &
mt5_server_pid=$!

# The RPyC server can bind well after 5 seconds, especially while Wine is
# still warming up. Poll for the port and stop early if the process dies.
mt5_server_timeout=30
mt5_server_waited=0
while [ "$mt5_server_waited" -lt "$mt5_server_timeout" ]; do
    if ! kill -0 "$mt5_server_pid" 2>/dev/null; then
        break
    fi
    if ss -tuln | grep -q ":$mt5server_port "; then
        break
    fi
    sleep 1
    mt5_server_waited=$((mt5_server_waited + 1))
done

if ss -tuln | grep -q ":$mt5server_port "; then
    show_message "[7/7] The mt5linux server is running on port $mt5server_port."
elif ! kill -0 "$mt5_server_pid" 2>/dev/null; then
    show_message "[7/7] The mt5linux server exited before opening port $mt5server_port. Check the log above for errors."
else
    show_message "[7/7] The mt5linux server did not open port $mt5server_port within ${mt5_server_timeout}s. Check the log above for errors."
fi
