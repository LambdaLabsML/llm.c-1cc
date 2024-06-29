#!/bin/bash
# Description: Distribute ssh-keys to multiple machines, and give each access to each other.

# Define ssh keys for user
KEY_NAME="1cc"
PRIVATE_KEY="$HOME/.ssh/${KEY_NAME}"
PUBLIC_KEY="${PRIVATE_KEY}.pub"
USER_NAME="ubuntu"

# Check if CONFIG_PATH is set
if [ -z "${CONFIG_PATH}" ]; then
    echo "CONFIG_PATH hasn't been set or found."
    exit 1
fi

# Check if the file at CONFIG_PATH exists
if [ ! -f "${CONFIG_PATH}" ]; then
    echo "File specified by CONFIG_PATH (${CONFIG_PATH}) doesn't exist."
    exit 1
fi

echo "CONFIG_PATH is set to: ${CONFIG_PATH}"

# Extract and print all Host entries
hosts=$(awk '/^Host / {print $2}' "${CONFIG_PATH}")

main() {
    while true; do
        echo "Distribute keys to "${hosts}" ?"
        read -p " (y/n): " yn
        case $yn in
            [Yy]* ) break;;
            [Nn]* ) echo "Exiting script."; exit 1;;
            * ) echo -e "${YELLOW}Please answer yes or no.${NC}";;
        esac
    done

    # Step 1: Generate the SSH key if it does not exist
    if [ ! -f "$PRIVATE_KEY" ]; then
        echo "Generating SSH key $KEY_NAME ..."
        ssh-keygen -t rsa -b 2048 -f "$PRIVATE_KEY" -N "" -C "compute_node"
    else
        echo "Key already exists."
    fi

    # Step 2: Distribute the public key to each machine
    for machine in ${hosts}; do
        echo "Copying key to $machine..."
        ssh-copy-id -F "$CONFIG_PATH" -i "$PUBLIC_KEY" -f "$USER_NAME"@"$machine"

        echo "Appending SSH config to $machine..."
        ssh -F "$CONFIG_PATH" "$USER_NAME"@"$machine" "echo -e 'Host *\n  User ubuntu\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR' >> ~/.ssh/config"

        echo "Copying private key to $machine with a unique name..."
        scp -F "$CONFIG_PATH" "$PRIVATE_KEY" "$USER_NAME"@"$machine":~/.ssh/
        scp -F "$CONFIG_PATH" "$PUBLIC_KEY" "$USER_NAME"@"$machine":~/.ssh/

        echo "Informing $machine of new private key name for future SSH operations..."
        ssh -F "$CONFIG_PATH" "$USER_NAME"@"$machine" "echo '  IdentityFile ~/.ssh/${KEY_NAME}' >> ~/.ssh/config"

    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi