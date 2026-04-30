#!/usr/bin/env bash

# ================= CONFIGURATION =================
HOME_DIR="$HOME/llama-cluster"
LLAMA_SERVER="$HOME_DIR/bin/llama-server"
PRESET_FILE="$HOME_DIR/models.ini"
LOG_DIR="$HOME_DIR/logs"

# Create necessary directories
mkdir -p "$HOME_DIR/bin"
mkdir -p "$HOME_DIR/logs"
mkdir -p "$HOME_DIR/models"

# ================= HELPER FUNCTIONS =================

detect_gpus() {
    # Try to detect GPUs using nvidia-smi
    if command -v nvidia-smi &> /dev/null; then
        local gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ "$gpu_count" =~ ^[0-9]+$ ]]; then
            echo "$gpu_count"
            return
        fi
    fi
    echo "1" # Fallback to 1 GPU if nvidia-smi fails
}

setup_environment() {
    echo "📦 Setting up environment in $HOME_DIR..."
    
    # Copy binary to home directory
    if [[ -f "./build/bin/llama-server" ]]; then
        cp "./build/bin/llama-server" "$HOME_DIR/bin/" 2>/dev/null
        chmod +x "$LLAMA_SERVER"
    else
        echo "⚠️  llama-server not found in ./build/bin/ (You may need to build it first)"
    fi

    # Parse and copy models to home directory NVMe
    > "$PRESET_FILE"
    if [[ -f "./models.ini" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ $line =~ ^[a-zA-Z0-9] && $line == *"="* ]]; then
                local key=$(echo "$line" | cut -d'=' -f1 | tr -d ' ')
                local value=$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//')
                
                if [[ "$key" == "model" || "$key" == "mmproj" ]]; then
                    local filename=$(basename "$value")
                    local dest="$HOME_DIR/models/$filename"
                    if [[ -f "$value" && ! -f "$dest" ]]; then
                        echo "   -> Copying $filename to $HOME_DIR/models/"
                        cp "$value" "$dest"
                    fi
                    # Write the updated path to the preset
                    echo "$key = $dest" >> "$PRESET_FILE"
                else
                    echo "$line" >> "$PRESET_FILE"
                fi
            else
                # Keep section headers and comments
                echo "$line" >> "$PRESET_FILE"
            fi
        done < "./models.ini"
    fi
    echo "✅ Setup complete."
}

stop_cluster() {
    echo "🛑 Stopping all llama-server tmux sessions..."
    # Find and kill all tmux sessions starting with 'llama-server-'
    tmux ls 2>/dev/null | grep "^llama-server-" | cut -d: -f1 | while read -r session; do
        tmux kill-session -t "$session"
    done
    echo "✅ Cluster stopped."
}

launch_cluster() {
    local num_groups=$1
    local total_gpus=$(detect_gpus)
    
    if [ "$num_groups" -gt "$total_gpus" ]; then
        echo "❌ Error: Cannot create more groups ($num_groups) than available GPUs ($total_gpus)."
        exit 1
    fi
    
    local gpus_per_group=$((total_gpus / num_groups))
    echo "🚀 Launching $num_groups sub-clusters ($gpus_per_group GPUs each)..."
    
    # Ensure previous instances are dead
    stop_cluster
    
    local base_port=11435
    local gpu_index=0
    
    for ((i=1; i<=num_groups; i++)); do
        local session_name="llama-server-$i"
        local port=$((base_port + i - 1))
        
        # Build GPU comma-separated list
        local gpu_list=""
        for ((j=0; j<gpus_per_group; j++)); do
            local current_gpu=$((gpu_index + j))
            if [ -z "$gpu_list" ]; then
                gpu_list="$current_gpu"
            else
                gpu_list="$gpu_list,$current_gpu"
            fi
        done
        
        # Build tensor split (e.g., "1,1" for 2 GPUs)
        local tensor_split=$(printf '1 %.0s' $(seq 1 $gpus_per_group) | sed 's/ /,/g' | sed 's/,$//')
        
        echo "   -> Starting $session_name on port $port (GPUs: $gpu_list)"
        
        # Create a detached tmux session
        tmux new-session -d -s "$session_name"
        
        # Construct the launch command and pipe output to log file
        local cmd="CUDA_VISIBLE_DEVICES=$gpu_list \"$LLAMA_SERVER\" --models-preset \"$PRESET_FILE\" --host 0.0.0.0 --port $port --tensor-split \"$tensor_split\" --split-mode layer --cont-batching 2>&1 | tee \"$LOG_DIR/$session_name.log\""
        
        # Send the command to the tmux session and hit Enter
        tmux send-keys -t "$session_name" "$cmd" C-m
        
        gpu_index=$((gpu_index + gpus_per_group))
    done
    
    echo "✅ All servers launched in tmux!"
    echo "   Use 'tmux attach -t llama-server-1' to view the first server's console."
    echo "   Press Ctrl+B, then D to detach from the tmux console."
}

run_tui() {
    clear
    echo "================================================="
    echo "        llama.cpp Cluster Configuration        "
    echo "================================================="
    echo ""
    
    local total_gpus=$(detect_gpus)
    echo "Detected GPUs: $total_gpus"
    echo ""
    
    echo "Select Action:"
    local actions=("Start Cluster" "Stop Cluster" "Setup Environment Only" "Exit")
    PS3="Enter choice [1-${#actions[@]}]: "
    local action=""
    select a in "${actions[@]}"; do
        if [ -n "$a" ]; then
            action="$a"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
    
    case "$action" in
        "Start Cluster")
            echo ""
            read -p "Enter number of sub-clusters to create: " num_groups
            if [[ ! "$num_groups" =~ ^[0-9]+$ ]] || [ "$num_groups" -lt 1 ]; then
                echo "Invalid input. Defaulting to 1."
                num_groups=1
            fi
            echo ""
            setup_environment
            launch_cluster "$num_groups"
            ;;
        "Stop Cluster")
            echo ""
            stop_cluster
            ;;
        "Setup Environment Only")
            echo ""
            setup_environment
            ;;
        "Exit")
            exit 0
            ;;
    esac
}

# ================= MAIN =================

# Enforce tmux dependency
if ! command -v tmux &> /dev/null; then
    echo "❌ Error: tmux is not installed. Please install tmux to use this script."
    exit 1
fi

if [ $# -eq 0 ]; then
    run_tui
else
    # Support for CLI invocation for automation
    case "$1" in
        start)
            setup_environment
            launch_cluster "${2:-1}"
            ;;
        stop)
            stop_cluster
            ;;
        setup)
            setup_environment
            ;;
        *)
            echo "Usage: $0 {start|stop|setup} [num_groups]"
            ;;
    esac
fi
