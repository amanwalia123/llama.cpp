#!/usr/bin/env bash

# ================= CONFIGURATION =================
HOME_DIR="$HOME/llama-cluster"
LLAMA_SERVER="$HOME_DIR/bin/llama-server"
LOG_DIR="$HOME_DIR/logs"

# Create necessary directories
mkdir -p "$HOME_DIR/bin"
mkdir -p "$HOME_DIR/logs"
mkdir -p "$HOME_DIR/models"

# ================= HELPER FUNCTIONS =================

detect_gpus() {
    if command -v nvidia-smi &> /dev/null; then
        local gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ "$gpu_count" =~ ^[0-9]+$ ]]; then
            echo "$gpu_count"
            return
        fi
    fi
    echo "1" # Fallback
}

# TUI File Picker
# Outputs UI to stderr and the selected file path to stdout
file_picker() {
    local prompt="$1"
    local ext="$2"
    local current_dir="${3:-.}"
    
    while true; do
        clear >&2
        echo "=================================================" >&2
        echo " $prompt" >&2
        echo " Filter: *$ext" >&2
        echo " Current Directory: $(cd "$current_dir" && pwd)" >&2
        echo "=================================================" >&2
        
        local items=("../")
        
        # Add directories (hide errors if no matches)
        for d in "$current_dir"/*/; do
            if [ -d "$d" ]; then
                local bname="$(basename "$d")"
                # skip hidden dirs if preferred, or just keep them
                items+=("$bname/")
            fi
        done
        
        # Add files matching extension
        if [ -n "$ext" ]; then
            for f in "$current_dir"/*"$ext"; do
                if [ -f "$f" ]; then
                    items+=("$(basename "$f")")
                fi
            done
        fi
        
        items+=("[Skip/None]")
        
        PS3="Select a directory or file: "
        select item in "${items[@]}"; do
            if [ -n "$item" ]; then
                if [ "$item" = "[Skip/None]" ]; then
                    echo ""
                    return 0
                elif [ "$item" = "../" ]; then
                    # Go up one directory
                    current_dir="$(cd "$current_dir/.." && pwd)"
                    break
                elif [[ "$item" == */ ]]; then
                    # Go into directory
                    current_dir="$current_dir/${item%/}"
                    break
                elif [ -f "$current_dir/$item" ]; then
                    # File selected
                    local full_path="$(cd "$current_dir" && pwd)/$item"
                    echo "$full_path"
                    return 0
                fi
            else
                echo "Invalid selection." >&2
            fi
        done
    done
}

setup_environment() {
    local model_path="$1"
    local mmproj_path="$2"
    
    echo "📦 Setting up environment in $HOME_DIR..."
    
    # Copy binary to home directory
    if [[ -f "./build/bin/llama-server" ]]; then
        cp "./build/bin/llama-server" "$HOME_DIR/bin/" 2>/dev/null
        chmod +x "$LLAMA_SERVER"
    else
        echo "⚠️  llama-server not found in ./build/bin/ (You may need to build it first)"
    fi

    # Copy selected models to NVMe
    if [[ -n "$model_path" && -f "$model_path" ]]; then
        local model_filename=$(basename "$model_path")
        local dest_model="$HOME_DIR/models/$model_filename"
        if [[ ! -f "$dest_model" ]]; then
            echo "   -> Copying $model_filename to $HOME_DIR/models/"
            cp "$model_path" "$dest_model"
        else
            echo "   -> $model_filename already exists in $HOME_DIR/models/"
        fi
        export CLUSTER_MODEL="$dest_model"
    fi

    if [[ -n "$mmproj_path" && -f "$mmproj_path" ]]; then
        local mmproj_filename=$(basename "$mmproj_path")
        local dest_mmproj="$HOME_DIR/models/$mmproj_filename"
        if [[ ! -f "$dest_mmproj" ]]; then
            echo "   -> Copying $mmproj_filename to $HOME_DIR/models/"
            cp "$mmproj_path" "$dest_mmproj"
        else
            echo "   -> $mmproj_filename already exists in $HOME_DIR/models/"
        fi
        export CLUSTER_MMPROJ="$dest_mmproj"
    fi
    
    echo "✅ Setup complete."
}

stop_cluster() {
    echo "🛑 Stopping all llama-server tmux sessions..."
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
    
    if [ -z "$CLUSTER_MODEL" ]; then
        echo "❌ Error: No model file provided or selected."
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
        
        tmux new-session -d -s "$session_name"
        
        # Construct launch command
        local cmd="CUDA_VISIBLE_DEVICES=$gpu_list \"$LLAMA_SERVER\" --model \"$CLUSTER_MODEL\" --host 0.0.0.0 --port $port --tensor-split \"$tensor_split\" --split-mode layer --cont-batching"
        
        if [[ -n "$CLUSTER_MMPROJ" ]]; then
            cmd="$cmd --mmproj \"$CLUSTER_MMPROJ\""
        fi
        
        cmd="$cmd 2>&1 | tee \"$LOG_DIR/$session_name.log\""
        
        # Send command
        tmux send-keys -t "$session_name" "$cmd" C-m
        
        gpu_index=$((gpu_index + gpus_per_group))
    done
    
    echo "✅ All servers launched in tmux!"
    echo "   Use 'tmux attach -t llama-server-1' to view the first server's console."
    echo "   Press Ctrl+B, then D to detach from the tmux console."
}

run_tui() {
    while true; do
        clear
        echo "================================================="
        echo "        llama.cpp Cluster Configuration        "
        echo "================================================="
        echo ""
        
        local total_gpus=$(detect_gpus)
        echo "Detected GPUs: $total_gpus"
        echo ""
        
        echo "Select Action:"
        local actions=("Start Cluster" "Stop Cluster" "Exit")
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
                # Interactive File Selection
                local selected_model=$(file_picker "Select Primary Model (.gguf)" ".gguf")
                if [ -z "$selected_model" ]; then
                    echo "Model selection skipped. Returning to menu."
                    sleep 2
                    continue
                fi
                
                local selected_mmproj=$(file_picker "Select Multi-Modal Projection (Optional, .mmproj)" ".mmproj" "$(dirname "$selected_model")")
                
                clear
                echo "================================================="
                echo "Configuration Summary:"
                echo "Model:   $selected_model"
                echo "MMProj:  ${selected_mmproj:-None}"
                echo "================================================="
                echo ""
                
                read -p "Enter number of sub-clusters to create: " num_groups
                if [[ ! "$num_groups" =~ ^[0-9]+$ ]] || [ "$num_groups" -lt 1 ]; then
                    echo "Invalid input. Defaulting to 1."
                    num_groups=1
                fi
                echo ""
                
                setup_environment "$selected_model" "$selected_mmproj"
                launch_cluster "$num_groups"
                
                echo ""
                read -p "Press Enter to return to menu..."
                ;;
            "Stop Cluster")
                echo ""
                stop_cluster
                echo ""
                read -p "Press Enter to return to menu..."
                ;;
            "Exit")
                clear
                exit 0
                ;;
        esac
    done
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
        stop)
            stop_cluster
            ;;
        *)
            echo "Usage: $0"
            echo "  Run without arguments to launch the interactive cluster TUI."
            echo "  $0 stop   - Stop all running cluster instances."
            ;;
    esac
fi
