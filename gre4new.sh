#!/bin/bash

# Script to configure or remove /etc/rc.local for Iran or Kharej server and apply immediately
# Now lets user choose the tunnel subnet prefix (first 3 octets)

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Function to validate IPv4 address
validate_ipv4() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ $octet -gt 255 ]]; then
                echo "Invalid IPv4 address: $ip"
                return 1
            fi
        done
        return 0
    else
        echo "Invalid IPv4 address: $ip"
        return 1
    fi
}

# Function to validate tunnel prefix (first 3 octets: 1.2.3)
validate_prefix() {
    local prefix=$1
    if [[ $prefix =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$prefix"
        for octet in "${octets[@]}"; do
            if [[ $octet -gt 255 ]] || [[ $octet -lt 0 ]]; then
                echo "Invalid prefix: each octet must be 0-255"
                return 1
            fi
        done
        return 0
    else
        echo "Invalid prefix format. Use three octets like 10.10.10 or 192.168.77"
        return 1
    fi
}

# Function to create and execute /etc/rc.local for Iran Server
create_rc_local_iran() {
    local iran_ipv4=$1
    local kharej_ipv4=$2
    local tunnel_prefix=$3
    local iran_tunnel_ip="${tunnel_prefix}.1"
    local kharej_tunnel_ip="${tunnel_prefix}.2"

    echo "Creating /etc/rc.local for Iran Server..."
    cat > /etc/rc.local << EOF
#!/bin/bash

# Enable IPv4 forwarding
sysctl -w net.ipv4.conf.all.forwarding=1

# Configure GRE tunnel
ip tunnel add GRE mode gre remote $kharej_ipv4 local $iran_ipv4
ip addr add ${iran_tunnel_ip}/30 dev GRE
ip link set GRE mtu 1420
ip link set GRE up

# Configure iptables NAT rules
iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination ${iran_tunnel_ip}
iptables -t nat -A PREROUTING -p tcp --dport 1:65535 -j DNAT --to-destination ${kharej_tunnel_ip}:1-65535
iptables -t nat -A PREROUTING -p udp --dport 1:65535 -j DNAT --to-destination ${kharej_tunnel_ip}:1-65535
iptables -t nat -A POSTROUTING -j MASQUERADE

exit 0
EOF
    chmod +x /etc/rc.local
    echo "/etc/rc.local created and made executable."
    echo "Executing /etc/rc.local to apply changes immediately..."
    if bash /etc/rc.local; then
        echo "Changes applied successfully."
    else
        echo "Error: Failed to execute /etc/rc.local. Check the configuration."
        exit 1
    fi
}

# Function to create and execute /etc/rc.local for Kharej Server
create_rc_local_kharej() {
    local kharej_ipv4=$1
    local iran_ipv4=$2
    local tunnel_prefix=$3
    local kharej_tunnel_ip="${tunnel_prefix}.2"
    local iran_tunnel_ip="${tunnel_prefix}.1"

    echo "Creating /etc/rc.local for Kharej Server..."
    cat > /etc/rc.local << EOF
#!/bin/bash

# Enable IPv4 forwarding
sysctl -w net.ipv4.conf.all.forwarding=1

# Configure GRE tunnel
ip tunnel add GRE mode gre local $kharej_ipv4 remote $iran_ipv4
ip addr add ${kharej_tunnel_ip}/30 dev GRE
ip link set GRE mtu 1420
ip link set GRE up

exit 0
EOF
    chmod +x /etc/rc.local
    echo "/etc/rc.local created and made executable."
    echo "Executing /etc/rc.local to apply changes immediately..."
    if bash /etc/rc.local; then
        echo "Changes applied successfully."
    else
        echo "Error: Failed to execute /etc/rc.local. Check the configuration."
        exit 1
    fi
}

# Function to remove GRE tunnel and NAT rules
remove_tunnel() {
    echo "Removing GRE tunnel and NAT rules..."

    # Remove GRE tunnel
    ip tunnel del GRE 2>/dev/null || echo "No GRE tunnel found or already removed."

    # Best-effort delete known old hardcoded rules
    iptables -t nat -D PREROUTING -p tcp --dport 22 -j DNAT --to-destination 172.16.1.1 2>/dev/null || true
    iptables -t nat -D PREROUTING -p tcp --dport 1:65535 -j DNAT --to-destination 172.16.1.2:1-65535 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport 1:65535 -j DNAT --to-destination 172.16.1.2:1-65535 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true

    # Smarter: flush the chains where we added rules (very effective for this use-case)
    echo "Flushing nat PREROUTING and POSTROUTING chains..."
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING

    # Optional: also flush FORWARD if you ever add rules there later
    # iptables -F FORWARD

    # Remove /etc/rc.local
    if [[ -f /etc/rc.local ]]; then
        echo "Removing /etc/rc.local..."
        rm -f /etc/rc.local
        echo "/etc/rc.local removed."
    else
        echo "/etc/rc.local does not exist."
    fi

    echo "Cleanup completed."
}

# Prompt for option
echo "Select an option:"
echo "1) Configure Iran Server"
echo "2) Configure Kharej Server"
echo "3) Remove Tunnel"
read -p "Enter choice (1, 2, or 3): " choice

case "$choice" in
    1)
        # Iran Server configuration
        echo "Configuring Iran Server..."
        read -p "Enter Iran Server Public IPv4 address: " iran_ipv4
        if ! validate_ipv4 "$iran_ipv4"; then exit 1; fi

        read -p "Enter Kharej Server Public IPv4 address: " kharej_ipv4
        if ! validate_ipv4 "$kharej_ipv4"; then exit 1; fi

        read -p "Enter tunnel subnet prefix (first 3 octets, e.g. 10.10.10 or 192.168.77): " tunnel_prefix
        if ! validate_prefix "$tunnel_prefix"; then exit 1; fi

        create_rc_local_iran "$iran_ipv4" "$kharej_ipv4" "$tunnel_prefix"
        ;;
    2)
        # Kharej Server configuration
        echo "Configuring Kharej Server..."
        read -p "Enter Kharej Server Public IPv4 address: " kharej_ipv4
        if ! validate_ipv4 "$kharej_ipv4"; then exit 1; fi

        read -p "Enter Iran Server Public IPv4 address: " iran_ipv4
        if ! validate_ipv4 "$iran_ipv4"; then exit 1; fi

        read -p "Enter tunnel subnet prefix (first 3 octets, e.g. 10.10.10 or 192.168.77): " tunnel_prefix
        if ! validate_prefix "$tunnel_prefix"; then exit 1; fi

        create_rc_local_kharej "$kharej_ipv4" "$iran_ipv4" "$tunnel_prefix"
        ;;
    3)
        remove_tunnel
        ;;
    *)
        echo "Invalid choice. Please select 1, 2, or 3."
        exit 1
        ;;
esac

exit 0