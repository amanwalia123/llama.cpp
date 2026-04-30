#!/bin/bash

# ================= CONFIGURATION =================
# Use paths in home directory for NVME storage
HOME_DIR="$HOME/llama-cluster"
LLAMA_SERVER="$HOME_DIR/bin/llama-server"
PRESET_FILE="$HOME_DIR/models.ini"
LOG_DIR="$HOME_DIR/logs"

# Default configuration
DEFAULT_GROUPS=2

# Create necessary directories
mkdir -p "$HOME_DIR/bin"
mkdir -p "$HOME_DIR/logs"
mkdir -p "$HOME_DIR/models"

# =================================================
# HELPER FUNCTION: detect_gpus
# Automatically detect available GPUs
# =================================================
detect_gpus() {
    # Try to detect GPUs using nvidia-smi
    if command -v nvidia-smi &> /dev/null; then
        local gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ "$gpu_count" =~ ^[0-9]+$ ]]; then
            echo "$gpu_count"
            return
        fi
    fi
    
    # Fallback: try to detect from llama-server itself
    local gpu_info=$("$LLAMA_SERVER" --help 2>&1 | grep -c "Device.*V100\|Device.*A100\|Device.*H100" || true)
    if [ "$gpu_info" -gt 0 ]; then
        echo "$gpu_info"
        return
    fi
    
    # Final fallback: assume 8 GPUs (original V100 setup)
    echo "8"
}

# =================================================
# HELPER FUNCTION: copy_model_files
# Copy model files to home directory for NVME storage
# =================================================
copy_model_files() {
    echo "🔄 Copying model files to $HOME_DIR for NVME storage..."
    
    # Read current models.ini and copy model files
    if [[ -f "./models.ini" ]]; then
        # Parse models.ini and copy files
        while IFS= read -r line; do
            if [[ $line =~ ^[a-zA-Z0-9] && $line == *"="* ]]; then
                key=$(echo "$line" | cut -d'=' -f1 | tr -d ' ')
                value=$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//')
                
                if [[ "$key" == "model" || "$key" == "mmproj" ]]; then
                    if [[ -f "$value" ]]; then
                        filename=$(basename "$value")
                        destination="$HOME_DIR/models/$filename"
                        
                        if [[ ! -f "$destination" ]]; then
                            echo "📦 Copying $filename to $HOME_DIR/models/..."
                            cp "$value" "$destination" 2>/dev/null || echo "⚠️  Failed to copy $filename"
                        else
                            echo "✅ $filename already exists in $HOME_DIR/models/"
                        fi
                    fi
                fi
            fi
        done < <(grep -E "^(model|mmproj)\s*=" ./models.ini)
    fi
}

# =================================================
# HELPER FUNCTION: create_temp_models_ini
# Create temporary models.ini with updated paths
# =================================================
create_temp_models_ini() {
    echo "📝 Creating temporary models.ini with updated paths..."
    
    if [[ -f "./models.ini" ]]; then
        # Create new models.ini with updated paths
        > "$PRESET_FILE"  # Clear file
        
        local in_section=false
        local current_section=""
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ $line =~ ^\[(.*)\] ]]; then
                # Section header
                current_section="${BASH_REMATCH[1]}"
                echo "$line" >> "$PRESET_FILE"
                in_section=true
            elif [[ $line =~ ^[a-zA-Z0-9] && $line == *"="* ]]; then
                # Key-value pair
                key=$(echo "$line" | cut -d'=' -f1 | tr -d ' ')
                value=$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//')
                
                if [[ "$key" == "model" || "$key" == "mmproj" ]]; then
                    filename=$(basename "$value")
                    new_path="$HOME_DIR/models/$filename"
                    echo "$key = $new_path" >> "$PRESET_FILE"
                else
                    echo "$line" >> "$PRESET_FILE"
                fi
            else
                # Comment or blank line
                echo "$line" >> "$PRESET_FILE"
            fi
        done < "./models.ini"
        
        echo "✅ Temporary models.ini created at $PRESET_FILE"
    else
        echo "❌ Error: Original models.ini not found"
        exit 1
    fi
}

# =================================================
# HELPER FUNCTION: copy_llama_bin
# Copy llama binary to home directory
# =================================================
copy_llama_bin() {
    echo "🚚 Copying llama-server binary to $HOME_DIR/bin/..."
    
    if [[ -f "./build/bin/llama-server" ]]; then
        if [[ ! -f "$LLAMA_SERVER" ]] || [[ "./build/bin/llama-server" -nt "$LLAMA_SERVER" ]]; then
            cp "./build/bin/llama-server" "$HOME_DIR/bin/" 2>/dev/null && echo "✅ llama-server copied to $HOME_DIR/bin/" || echo "❌ Failed to copy llama-server"
            chmod +x "$LLAMA_SERVER" 2>/dev/null
        else
            echo "✅ llama-server already exists and is up to date"
        fi
    else
        echo "❌ Error: llama-server binary not found in ./build/bin/"
        exit 1
    fi
}

# =================================================
# HELPER FUNCTION: setup_cluster
# Setup all files for cluster operation
# =================================================
setup_cluster() {
    echo "🚀 Setting up cluster environment..."
    copy_llama_bin
    copy_model_files
    create_temp_models_ini
    echo "✅ Cluster environment setup complete"
}

# =================================================
# HELPER FUNCTION: launch_router
# Arguments: instance_name, gpus, port
# =================================================
launch_router() {
    local NAME=$1
    local GPUS=$2
    local PORT=$3

    # Calculate tensor-split based on GPU count
    # Example: "0,1" results in GPU_COUNT=2, TENSOR_SPLIT="1,1"
    local GPU_COUNT=$(echo "$GPUS" | tr -cd ',' | wc -c)
    GPU_COUNT=$((GPU_COUNT + 1))
    local TENSOR_SPLIT=$(printf '1 %.0s' $(seq 1 $GPU_COUNT) | sed 's/ /,/g' | sed 's/,$//')

    echo "🚀 Launching Server [$NAME] on GPUs [$GPUS] at Port $PORT..."

    # Run llama-server in background
    # CUDA_VISIBLE_DEVICES isolates the GPUs so this instance only uses its subset
    CUDA_VISIBLE_DEVICES=$GPUS "$LLAMA_SERVER" \
        --models-preset "$PRESET_FILE" \
        --host 0.0.0.0 \
        --port "$PORT" \
        --tensor-split "$TENSOR_SPLIT" \
        --split-mode layer \
        --cont-batching \
        > "$LOG_DIR/$NAME.log" 2>&1 &
    
    local PID=$!
    sleep 1
    
    # Check if process is still running
    if kill -0 $PID 2>/dev/null; then
        echo "✅ Server [$NAME] started successfully (PID: $PID)"
    else
        echo "❌ Failed to start server [$NAME]"
        return 1
    fi
}

# =================================================
# HELPER FUNCTION: stop_all_servers
# =================================================
stop_all_servers() {
    echo "🛑 Stopping all llama-server instances..."
    pkill -f "llama-server" 2>/dev/null
    sleep 2
    echo "✅ All servers stopped"
}

# =================================================
# HELPER FUNCTION: launch_cluster
# Arguments: number_of_groups
# =================================================
launch_cluster() {
    local num_groups=${1:-$DEFAULT_GROUPS}
    local total_gpus=$(detect_gpus)
    
    # Calculate GPUs per group to distribute evenly
    local gpus_per_group=$((total_gpus / num_groups))
    local remaining_gpus=$((total_gpus % num_groups))
    
    echo "🚀 Starting cluster with $num_groups groups ($gpus_per_group GPUs per group) on $total_gpus total GPUs..."
    
    # Stop any existing servers first
    stop_all_servers
    
    # Validate GPU distribution
    if [ $gpus_per_group -eq 0 ]; then
        echo "❌ Error: Too many groups requested. Maximum supported: $total_gpus groups (1 GPU each)"
        exit 1
    fi
    
    # Launch servers dynamically
    local base_port=11435
    local gpu_index=0
    
    for ((i=1; i<=num_groups; i++)); do
        local server_name="server-$i"
        local port=$((base_port + i - 1))
        
        # Build GPU list for this group
        local gpu_list=""
        for ((j=0; j<gpus_per_group; j++)); do
            local current_gpu=$((gpu_index + j))
            if [ -z "$gpu_list" ]; then
                gpu_list="$current_gpu"
            else
                gpu_list="$gpu_list,$current_gpu"
            fi
        done
        
        launch_router "$server_name" "$gpu_list" "$port"
        gpu_index=$((gpu_index + gpus_per_group))
    done
}

# Handle script arguments
case "${1:-start}" in
    start)
        setup_cluster
        # Check if number of groups is provided as argument
        if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ]; then
            launch_cluster "$2"
        else
            launch_cluster
        fi
        ;;
    setup)
        setup_cluster
        ;;
    stop)
        stop_all_servers
        exit 0
        ;;
    restart)
        setup_cluster
        stop_all_servers
        sleep 2
        # Check if number of groups is provided as argument
        if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ]; then
            launch_cluster "$2"
        else
            launch_cluster
        fi
        ;;
    *)
        echo "Usage: $0 {start|setup|stop|restart} [number_of_groups]"
        echo "  number_of_groups: Number of GPU groups (default: $DEFAULT_GROUPS)"
        echo "  Detected GPUs: $(detect_gpus)"
        echo "  Examples:"
        echo "    $0 start        # Launch with $DEFAULT_GROUPS groups"
        echo "    $0 start 1      # Launch with 1 group (all $(detect_gpus) GPUs)"
        echo "    $0 start 2      # Launch with 2 groups ($(( $(detect_gpus) / 2 )) GPUs each)"
        echo "    $0 start 4      # Launch with 4 groups ($(( $(detect_gpus) / 4 )) GPUs each)"
        echo "    $0 start $(detect_gpus)      # Launch with $(detect_gpus) groups (1 GPU each)"
        echo "    $0 setup        # Setup files only (copy models and binaries)"
        exit 1
        ;;
esac

# =================================================

echo "------------------------------------------------------------------"
echo "✅ Cluster deployment initiated on detected GPUs."
echo "Using NVME storage: $HOME_DIR"
echo "Router mode active: Dynamic switching enabled via $PRESET_FILE"
echo "Logs: $LOG_DIR"
echo "Management: $0 {start|setup|stop|restart} [number_of_groups]"
echo "------------------------------------------------------------------"

# Show running processes
echo "📋 Running llama-server processes:"
ps aux | grep "[l]lama-server" | grep -v grep || echo "No llama-server processes found"
