#!/bin/bash

set -euo pipefail

sudo -v
(while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done) &
SUDO_KEEPALIVE_PID=$!

BUILD_DIR=""
LOG_FILE="/tmp/mochigome-setup_$(date +%s).log"
: > "$LOG_FILE"

cleanup() {
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    [ -n "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
    reset_screen 2>/dev/null || true
}
trap cleanup EXIT

PACKAGES_FILE="packages.txt"

if [ ! -f "$PACKAGES_FILE" ]; then
    echo "Error: $PACKAGES_FILE not found."
    exit 1
fi

# ============================================================
# Progress Indicator
# ============================================================
TOTAL_STEPS=12
CURRENT_STEP=0
BAR_WIDTH=20
SPIN='_oO'
LOG_LAST_LINE=0
SCREEN_INITIALIZED=false

render_bar() {
    local percent="$1"
    local filled=$(( percent * BAR_WIDTH / 100 ))
    local empty=$(( BAR_WIDTH - filled ))
    printf '%s%s' "$(printf '#%.0s' $(seq 1 "$filled") 2>/dev/null)" "$(printf -- '-%.0s' $(seq 1 "$empty") 2>/dev/null)"
}

init_screen() {
    TERM_LINES=$(tput lines 2>/dev/null || echo 24)
    BOX_HEIGHT=3
    REGION_BOTTOM=$((TERM_LINES - BOX_HEIGHT - 1))
    BOX_TOP=$((REGION_BOTTOM + 2))

    clear
    printf '\033[1;%dr' "$REGION_BOTTOM"
    tput cup 0 0
    SCREEN_INITIALIZED=true
}

reset_screen() {
    $SCREEN_INITIALIZED || return 0
    printf '\033[r'
    tput cup $((TERM_LINES - 1)) 0
    echo ""
    SCREEN_INITIALIZED=false
}

append_history() {
    tput cup $((REGION_BOTTOM - 1)) 0
    printf '%s\033[K\n' "$1"
}

flush_new_log_lines() {
    local total_lines
    total_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$total_lines" -gt "$LOG_LAST_LINE" ]; then
        while IFS= read -r line; do
            append_history "$line"
        done < <(sed -n "$((LOG_LAST_LINE + 1)),${total_lines}p" "$LOG_FILE")
        LOG_LAST_LINE=$total_lines
    fi
}

draw_box() {
    local msg="$1" spin_char="$2" percent="$3" bar="$4"
    local box_text=" [$CURRENT_STEP/$TOTAL_STEPS] [$bar] ${percent}% $spin_char $msg "
    local box_len=${#box_text}
    local border
    border=$(printf '─%.0s' $(seq 1 "$box_len"))

    tput cup $((BOX_TOP - 1)) 0; printf '┌%s┐\033[K' "$border"
    tput cup $((BOX_TOP))     0; printf '│%s│\033[K' "$box_text"
    tput cup $((BOX_TOP + 1)) 0; printf '└%s┘\033[K' "$border"
}

run_step() {
    local msg="$1"
    shift
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local bar
    bar=$(render_bar "$percent")

    {
        echo ""
        echo "===== [$CURRENT_STEP/$TOTAL_STEPS] $msg ====="
    } >> "$LOG_FILE"

    ( "$@" >> "$LOG_FILE" 2>&1 ) &
    local pid=$!
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#SPIN} ))
        flush_new_log_lines
        draw_box "$msg" "${SPIN:$i:1}" "$percent" "$bar"
        sleep 0.1
    done

    wait "$pid"
    local status=$?
    flush_new_log_lines

    if [ $status -eq 0 ]; then
        append_history "✔ [$CURRENT_STEP/$TOTAL_STEPS] $msg"
        draw_box "$msg" "✔" "$percent" "$bar"
    else
        append_history "✘ [$CURRENT_STEP/$TOTAL_STEPS] $msg"
        draw_box "$msg" "✘" "$percent" "$bar"
        reset_screen
        echo ""
        echo "An error has occurred. Please check the log below for details:"
        echo "  $LOG_FILE"
        echo ""
        echo "----- Recent Logs -----"
        tail -n 30 "$LOG_FILE"
        exit $status
    fi
}

# ============================================================
# Packages.txt Parser
# ============================================================

# Arrays to hold parsed data
declare -a GROUP_NAMES=()
declare -a GROUP_PACKAGES=()
declare -a GROUP_COMMANDS=()
declare -a GROUP_SELECTED=()

parse_packages_file() {
    local current_name=""
    local current_packages=""
    local current_commands=""

    flush_group() {
        if [ -n "$current_name" ]; then
            GROUP_NAMES+=("$current_name")
            GROUP_PACKAGES+=("$current_packages")
            GROUP_COMMANDS+=("$current_commands")
            GROUP_SELECTED+=(0)  # 0 = not yet selected
        fi
        current_name=""
        current_packages=""
        current_commands=""
    }

    while IFS= read -r line || [ -n "$line" ]; do
        # Remove trailing whitespace/CR
        line="${line%%$'\r'}"
        line="$(echo "$line" | sed 's/[[:space:]]*$//')"

        # Skip empty lines
        [ -z "$line" ] && continue

        # Check for Name header
        if [[ "$line" =~ ^#\ Name:\ *(.+)$ ]]; then
            flush_group
            current_name="${BASH_REMATCH[1]}"
            continue
        fi

        # Check for Commands header
        if [[ "$line" =~ ^#\ Commands:\ *(.+)$ ]]; then
            if [ -n "$current_commands" ]; then
                current_commands+="; ${BASH_REMATCH[1]}"
            else
                current_commands="${BASH_REMATCH[1]}"
            fi
            continue
        fi

        # Skip other comments
        if [[ "$line" =~ ^# ]]; then
            continue
        fi

        # Regular package line
        if [ -n "$current_packages" ]; then
            current_packages+=$'\n'"$line"
        else
            current_packages="$line"
        fi
    done < "$PACKAGES_FILE"

    flush_group
}

# ============================================================
# Interactive Group Selection
# ============================================================

select_groups() {
    echo ""
    echo "========================================"
    echo "  Package Group Selection"
    echo "========================================"
    echo ""

    # Check if dialog is available
    if command -v dialog &> /dev/null; then
        select_groups_tui
    else
        select_groups_tui_fallback
    fi
}

select_groups_tui() {
    # Build items for dialog: "item_1 label_1 status_1" ...
    local items=()
    for i in "${!GROUP_NAMES[@]}"; do
        items+=("$i" "${GROUP_NAMES[$i]}" "off")
    done

    # Show checklist dialog
    local selected
    selected=$(dialog --title "Package Selection" \
        --checklist "Select groups to install:" \
        20 60 11 \
        "${items[@]}" \
        3>&1 1>&2 2>&3)

    local dialog_exit=$?

    # Dialog was cancelled
    if [ $dialog_exit -ne 0 ]; then
        echo "Cancelled."
        exit 1
    fi

    # Mark selected groups
    for i in "${!GROUP_SELECTED[@]}"; do
        GROUP_SELECTED[$i]=0
    done
    for idx in $selected; do
        GROUP_SELECTED[$idx]=1
    done

    echo ""
    echo "Selection complete. Starting installation..."
    echo ""
    sleep 1
}

select_groups_tui_fallback() {
    echo "dialog not found. Using simple selection..."
    echo ""
    echo "Choose whether to install each group (Y/N):"
    echo ""

    local i=1
    for name in "${GROUP_NAMES[@]}"; do
        printf "  [%d] %s : " "$i" "$name"
        read -r choice
        choice="${choice^^}"
        if [ "$choice" = "Y" ] || [ "$choice" = "YES" ]; then
            GROUP_SELECTED[$((i - 1))]=1
            echo "        -> Will install"
        else
            GROUP_SELECTED[$((i - 1))]=0
            echo "        -> Skipped"
        fi
        i=$((i + 1))
    done

    echo ""
    echo "Selection complete. Starting installation..."
    echo ""
    sleep 1
}

# ============================================================
# Step Functions
# ============================================================

step_system_update() {
    sudo pacman -Syu --noconfirm
}

step_install_paru() {
    if command -v paru &> /dev/null; then
        echo "paru is already installed."
    elif pacman -Si paru &>/dev/null; then
        sudo pacman -S --needed --noconfirm paru
    else
        sudo pacman -S --needed --noconfirm base-devel git rust
        BUILD_DIR=$(mktemp -d)
        git clone https://aur.archlinux.org/paru.git "$BUILD_DIR/paru"
        (
            cd "$BUILD_DIR/paru"
            makepkg -si --noconfirm
        )
    fi
}

install_group_packages() {
    local group_index="$1"
    local packages="${GROUP_PACKAGES[$group_index]}"

    if [ -z "$packages" ]; then
        return 0
    fi

    echo "$packages" | xargs -r sudo paru -S --needed --noconfirm
}

run_group_commands() {
    local commands="${GROUP_COMMANDS[$1]}"

    if [ -z "$commands" ]; then
        return 0
    fi

    # Split by semicolon and execute each command
    IFS=';' read -ra cmd_array <<< "$commands"
    for cmd in "${cmd_array[@]}"; do
        cmd="$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$cmd" ] && continue
        bash -c "$cmd"
    done
}

step_link_dotfiles() {
    local DOTFILES_DIR="$1"

    link() {
        local src="$1"
        local dst="$2"
        mkdir -p "$(dirname "$dst")"
        if [ -d "$dst" ] && [ ! -L "$dst" ]; then
            local backup="${dst}.bak.$(date +%s)"
            echo "Backing up existing directory: $dst -> $backup"
            mv "$dst" "$backup"
        fi

        ln -sfnT "$src" "$dst"
    }

    link "$DOTFILES_DIR/home/.mochigome.zsh"    "$HOME/.mochigome.zsh"
    grep -Fxq 'source $HOME/.mochigome.zsh' "$HOME/.zshrc" || echo 'source $HOME/.mochigome.zsh' >> "$HOME/.zshrc"
    link "$DOTFILES_DIR/home/.p10k.zsh" "$HOME/.p10k.zsh"

    shopt -s nullglob dotglob
    for item in "$DOTFILES_DIR/home"/.config/*; do
        name="$(basename "$item")"
        link "$DOTFILES_DIR/home/.config/$name" "$HOME/.config/$name"
    done
    shopt -u nullglob dotglob

    mkdir -p "$HOME/.config/qt6ct"
    sed "s|\$HOME|$HOME|g" "$DOTFILES_DIR/home/.config/qt6ct/qt6ct.conf.template" > "$HOME/.config/qt6ct/qt6ct.conf"

    link "$DOTFILES_DIR/home/.local/share/PrismLauncher" "$HOME/.local/share/PrismLauncher"

    LANG=C xdg-user-dirs-update --force
    gsettings set org.cinnamon.desktop.default-applications.terminal exec 'kitty'
}

step_system_symlinks() {
    local DOTFILES_DIR="$1"
    sudo ln -sfn "$DOTFILES_DIR/system/etc/keyd/default.conf"                    /etc/keyd/default.conf
    sudo ln -sfn "$DOTFILES_DIR/system/etc/pam.d/greetd"                         /etc/pam.d/greetd
    sudo ln -sfn "$DOTFILES_DIR/system/etc/greetd/config.toml"                   /etc/greetd/config.toml
    sudo cp "$DOTFILES_DIR/system/etc/systemd/system/automount-all.service"      /etc/systemd/system/

    sudo mkdir -p /usr/local/bin
    sed "s/__USERNAME__/${USER}/g" "$DOTFILES_DIR/system/usr/local/bin/automount-all.sh.template" | sudo tee /usr/local/bin/automount-all.sh > /dev/null
    sudo chmod +x /usr/local/bin/automount-all.sh
}

step_sudo_feedback() {
    echo "Defaults pwfeedback" | sudo tee /etc/sudoers.d/pwfeedback
}

step_enable_services() {
    sudo systemctl enable bluetooth
    sudo systemctl enable keyd
    sudo systemctl enable greetd
    sudo systemctl enable automount-all
    systemctl --user enable hypridle
}

step_post_setup_nopasswd() {
    local SUDOERS_FILE="/etc/sudoers.d/post-setup-tmp"
    sudo tee "$SUDOERS_FILE" > /dev/null <<EOF
$USER ALL=(ALL) NOPASSWD: ALL
EOF
    sudo chmod 0440 "$SUDOERS_FILE"
    sudo visudo -c -f "$SUDOERS_FILE"
}

step_firewall_setup() {
    sudo ufw allow steam
    sudo ufw allow 47984,47989,47990,48010/tcp
    sudo ufw allow 47998,47999,48000,48002,48010,5353/udp
    sudo ufw allow 25565/tcp
    sudo ufw allow 19132/udp
}

step_theme_and_groups() {
    sudo usermod -aG input "$USER"
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    gsettings set org.gnome.desktop.interface gtk-theme "Adwaita-dark"
}

step_env_var() {
    local DOTFILES_DIR="$1"
    mkdir -p ~/.config/environment.d/
    touch ~/.config/environment.d/mochigome.conf
    sed -i '/^DOTFILES_DIR=/d' "$HOME/.config/environment.d/mochigome.conf"
    echo "DOTFILES_DIR=$DOTFILES_DIR" | tee -a "$HOME/.config/environment.d/mochigome.conf" > /dev/null
}

# ============================================================
# Main Execution
# ============================================================

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse packages.txt
parse_packages_file

# Show groups and get selection
select_groups

init_screen

# Step 1: System update
run_step "Updating the system"                   step_system_update

# Step 2: Install paru
run_step "Installing paru"                       step_install_paru

# Steps 3~N: Install selected package groups
GROUP_STEP_START=3
for i in "${!GROUP_NAMES[@]}"; do
    if [ "${GROUP_SELECTED[$i]}" -eq 1 ]; then
        CURRENT_STEP=$((GROUP_STEP_START + i - 1))
        local_percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
        local_bar=$(render_bar "$local_percent")

        {
            echo ""
            echo "===== Installing group: ${GROUP_NAMES[$i]} ====="
        } >> "$LOG_FILE"

        # Install packages for this group
        ( install_group_packages "$i" >> "$LOG_FILE" 2>&1 ) &
        pid=$!
        j=0
        while kill -0 "$pid" 2>/dev/null; do
            j=$(( (j + 1) % ${#SPIN} ))
            flush_new_log_lines
            draw_box "Installing: ${GROUP_NAMES[$i]}" "${SPIN:$j:1}" "$local_percent" "$local_bar"
            sleep 0.1
        done
        wait "$pid"

        # Run post-install commands if any
        if [ -n "${GROUP_COMMANDS[$i]}" ]; then
            {
                echo ""
                echo "===== Running post-install commands for: ${GROUP_NAMES[$i]} ====="
            } >> "$LOG_FILE"
            ( run_group_commands "$i" >> "$LOG_FILE" 2>&1 ) &
            pid2=$!
            j=0
            while kill -0 "$pid2" 2>/dev/null; do
                j=$(( (j + 1) % ${#SPIN} ))
                flush_new_log_lines
                draw_box "Running commands: ${GROUP_NAMES[$i]}" "${SPIN:$j:1}" "$local_percent" "$local_bar"
                sleep 0.1
            done
            wait "$pid2"
        fi

        CURRENT_STEP=$((CURRENT_STEP + 1))
        append_history "✔ Installed: ${GROUP_NAMES[$i]}"
    fi
done

# Re-calculate step numbers for remaining steps
LAST_GROUP_STEP=$((GROUP_STEP_START + ${#GROUP_NAMES[@]} - 1))
REMAINING_STEPS=(
    "Linking dotfiles:step_link_dotfiles"
    "Linking the system configuration file:step_system_symlinks"
    "Configuring sudo feedback display:step_sudo_feedback"
    "Enabling various services:step_enable_services"
    "Initial setup is in progress:step_post_setup_nopasswd"
    "Setting up the firewall:step_firewall_setup"
    "Setting up the theme and user group:step_theme_and_groups"
    "Setting environment variables:step_env_var"
)

for entry in "${REMAINING_STEPS[@]}"; do
    IFS=':' read -r msg func_name <<< "$entry"
    step_name="$func_name \$DOTFILES_DIR"
    # Handle steps that need arguments
    case "$func_name" in
        step_link_dotfiles) run_step "$msg" "$func_name" "$DOTFILES_DIR" ;;
        step_system_symlinks) run_step "$msg" "$func_name" "$DOTFILES_DIR" ;;
        step_env_var) run_step "$msg" "$func_name" "$DOTFILES_DIR" ;;
        *) run_step "$msg" "$func_name" ;;
    esac
done

reset_screen

echo "The log is stored in $LOG_FILE."
echo "Installation complete!"
printf "Welcome to \e[1;33mmochigome\e[0m!\n"
echo "The system will reboot in 10 seconds."
echo "Press Ctrl+C to cancel."

for ((i=10; i>=1; i--))
do
    printf "\rRebooting in %d seconds..." "$i"
    sleep 1
done

sudo reboot
