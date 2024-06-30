#!/bin/bash
# Steps: 
# 1) Distribute a hostfile of all workers to head nodes
# 2) Install parallel-ssh on head nodes
# 3) Parallelized installation of dependencies on worker nodes
# 4) Prepare dataset on the shared storage
# 5) Build train_gpt2cu on the shared storage

# -----------------------------------------------------
# 1) Distribute a hostfile of all workers to head nodes
# -----------------------------------------------------

# Check if CONFIG_PATH is set and if the file exists
if [ -z "${CONFIG_PATH}" ]; then
    echo "CONFIG_PATH hasn't been set or found."
    exit 1
fi

if [ ! -f "${CONFIG_PATH}" ]; then
    echo "File specified by CONFIG_PATH (${CONFIG_PATH}) doesn't exist."
    exit 1
fi

# Extract worker nodes and their IPs, count GPUs
worker_hosts=$(awk '/^Host / && $2 !~ /head/ {print $2}' "${CONFIG_PATH}")

# Create hostfiles
hostfile=~/hostfile_1cc_worker
hostfile_mpirun=~/hostfile_1cc_worker_mpirun

# Clear hostfile if it already exists
> "${hostfile}"
> "${hostfile_mpirun}"

# Loop through worker nodes to populate hostfile
for worker_host in ${worker_hosts}; do
    echo $worker_host
    hostname=$(awk -v host="${worker_host}" '$1 == "Host" && $2 == host {found=1} found && $1 == "HostName" {print $2; exit}' "${CONFIG_PATH}")
    echo $hostname
    gpu_count=$(ssh -F "$CONFIG_PATH" "${worker_host}" 'nvidia-smi --query-gpu=count --format=csv,noheader' | awk '{print $1; exit}')
    echo $gpu_count
    echo "${hostname}" >> "${hostfile}"
    echo "${hostname} slots=${gpu_count}" >> "${hostfile_mpirun}"
done

# Distribute hostfiles to all head nodes
head_hosts=$(awk '/^Host head/ {print $2}' "${CONFIG_PATH}")
for head_host in ${head_hosts}; do
    scp -F "$CONFIG_PATH" "${hostfile}" "${head_host}:~/"
    scp -F "$CONFIG_PATH" "${hostfile_mpirun}" "${head_host}:~/"
    echo "Copied hostfile to ${head_host}"
done
echo "Created hostfile at ${hostfile} and distributed to all head nodes."

# -----------------------------------------------------
# 2) Install parallel-ssh on head nodes
# -----------------------------------------------------

# Install parallel-ssh on head nodes
for head_host in ${head_hosts}; do
    echo "Installing pssh on ${head_host}..."
    ssh -F "$CONFIG_PATH" "${head_host}" 'sudo apt update && sudo apt install -y pssh'
    ssh -F "$CONFIG_PATH" "${head_host}" 'which parallel-ssh'
    echo "parallel-ssh installed on ${head_host}"
done
echo "parallel-ssh installation complete on all head nodes."


# -----------------------------------------------------
# 3) Parallelized installation of dependencies on worker nodes
# -----------------------------------------------------
# Follow the instruction here: https://github.com/karpathy/llm.c/discussions/481
head1=$(echo "${head_hosts}" | head -n 1)
echo $head1
echo "Installing dependencies all workers ..."
cmd_dependencies=""
cmd_dependencies+="wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && "
cmd_dependencies+="sudo dpkg -i cuda-keyring_1.1-1_all.deb && "
cmd_dependencies+="sudo apt-get update && "
cmd_dependencies+="sudo apt-get -y install libcudnn9-dev-cuda-12 && "
cmd_dependencies+="[ -d cudnn-frontend ] || git clone https://github.com/NVIDIA/cudnn-frontend.git && "
cmd_dependencies+="sudo apt-get install -y libucx0 && "
cmd_dependencies+="sudo apt-get install -y openmpi-bin openmpi-doc libopenmpi-dev"
ssh -F "$CONFIG_PATH" "${head1}" "parallel-ssh -h ~/hostfile_1cc_worker -i '${cmd_dependencies}'"

echo "Installing dependencies on the first head ..."
cmd_dependencies_head=""
cmd_dependencies_head+="sudo apt-get update && "
cmd_dependencies_head+="sudo apt-get install -y libucx0 && "
cmd_dependencies_head+="sudo apt-get install -y openmpi-bin openmpi-doc libopenmpi-dev"
ssh -F "$CONFIG_PATH" "${head1}" ${cmd_dependencies_head}

# -----------------------------------------------------
# 4) Prepare dataset on the shared storage
# -----------------------------------------------------
worker1=$(echo "${worker_hosts}" | head -n 1)

# Check if STORAGE_PATH is set
if [ -z "${STORAGE_PATH}" ]; then
    echo "STORAGE_PATH is not set."
    exit 1
fi

# Check if STORAGE_PATH exists on worker1
ssh -F "${CONFIG_PATH}" "${worker1}" "[ -d '${STORAGE_PATH}' ]"
if [ $? -ne 0 ]; then
    echo "STORAGE_PATH '${STORAGE_PATH}' does not exist on ${worker1}."
    exit 1
fi

cmd_dataset=""
cmd_dataset+="yes | pip install tqdm tiktoken requests datasets && "
cmd_dataset+="cd ${STORAGE_PATH} && "
cmd_dataset+="[ -d llm.c ] || git clone https://github.com/karpathy/llm.c.git && "
cmd_dataset+="cd llm.c && "
cmd_dataset+="python dev/data/fineweb.py --version 10B"
ssh -F "$CONFIG_PATH" "${worker1}" ${cmd_dataset}

# -----------------------------------------------------
# 5) Build train_gpt2cu on the shared storage
# -----------------------------------------------------
cmd_build_train=""
cmd_build_train+="cd ${STORAGE_PATH}/llm.c && "
cmd_build_train+="make train_gpt2cu USE_CUDNN=1"
ssh -F "$CONFIG_PATH" "${worker1}" ${cmd_build_train}

echo "Setup completed. Time to train your own llm.c model! 😀🌟"
