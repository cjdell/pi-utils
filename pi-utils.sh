#!/bin/bash

# Author: Chris Dell (cjdell@gmail.com) @cjdell

# Usage (just this shell): source pi-utils.sh"
# Usage (permanent)      : ./pi-utils.sh install"

# All functions are prefixed with "util_" prefix (Use bash completion/tabbing to display them all)

utils_script_path=$BASH_SOURCE

# Qualify the script path if necessary to make it absolute
if [ ${utils_script_path:0:1} != "/" ]; then    
    utils_script_path=$(pwd)/$utils_script_path
fi

# Get the directory of the script as well
utils_script_dir=$(dirname $utils_script_path)

echo "pi-utils script path: $utils_script_path"

# Check if we're running from the shell
if [ -z $BASH_SOURCE ] || [ $0 == $BASH_SOURCE ]; then
    
    # Install script...
    if [ "$1" == "install" ]; then
        echo "source $(readlink -f $0)" >> ~/.bashrc
        echo "Util scripts will now be permanently available"
        exit
    else
        # Otherwise print usage
        echo "Usage (just this shell): source pi-utils.sh"
        echo "Usage (permanent)      : ./pi-utils.sh install"
        exit
    fi    
    
fi

# This is the address this Pi will assume when acting as a DHCP server
dhcp_server_ip=192.168.0.10

# This is the prefix MAC address for all Raspberry Pi's
mac_address_prefix=B8:27:EB

# To have these functions available globally and on boot please run this:
utils_install_utils() {
    echo "source $utils_script_path" >> ~/.bashrc
    echo "Util scripts will now be permanently available"
}

# Install needed dependencies via APT
utils_install_dependencies() {
    sudo apt-get update
    sudo apt-get install geany nmap dhcpd pv secure-delete
}

# Install BitTorrent Sync. Useful for keeping projects distributed across many Pi's in sync
utils_install_btsync() {
    # Download and extract the binary
    mkdir -p ~/Downloads && pushd ~/Downloads
    wget -O btsync_arm.tar.gz http://download-lb.utorrent.com/endpoint/btsync/os/linux-arm/track/stable
    tar -zxvf btsync_arm.tar.gz
    popd

    # Create the autostart shortcut
    read -r -d '' shortcut << 'EOF'
[Desktop Entry]
Type=Application
Exec=/home/pi/Downloads/btsync
EOF

    mkdir -p ~/.config/autostart
    echo "$shortcut" > ~/.config/autostart/btsync.desktop

    # Start the background process
    ~/Downloads/btsync

    echo "BitTorrent sync is now started and will run on boot"
    echo "Go to http://$(utils_get_local_ip):8888/ in your browser to setup a sync folder"
}

# Will allow this pi to talk to clones of this images via SSH
utils_setup_ssh_keys() {
    echo "Press enter 3 times (once for each prompt)"
    mkdir -p ~/.ssh
    ssh-keygen -t dsa
    chmod 700 ~/.ssh

    # Give me access to myself (for when this image is cloned)
    cat ~/.ssh/id_dsa.pub >> ~/.ssh/authorized_keys
}

# This will allow remote control of another Raspberry Pi
utils_setup_ssh_remote_control() {
    if [ ! -f ~/.ssh/id_dsa.pub ]; then
        echo "Please first run: utils_setup_ssh_keys"
        return
    fi
    
    echo "Enter IP address of Raspberry Pi to gain access to: "
    read ip
    cat ~/.ssh/id_dsa.pub | ssh $ip 'mkdir -p /home/pi/.ssh && cat >> /home/pi/.ssh/authorized_keys'
    
    # These lines aren't necessary but they will allow the remote Pi to SSH on to this Pi
    cat ~/.ssh/id_dsa.pub | ssh $ip 'cat >> /home/pi/.ssh/id_dsa.pub'
    cat ~/.ssh/id_dsa | ssh $ip 'cat >> /home/pi/.ssh/id_dsa'

    echo "If successful, you should now be able to SSH/SCP without a password"
}

# Writes zero to free disk space. Means the OS image will compress better 
utils_clean_free_disk_space() {
    sudo sfill -l -l -z /
}

# This will copy this script to the pi (paths below may need adjusting based on setup)
utils_copy_utils_to_pi() {
    echo "Please ensure you have remote control of the target Raspberry Pi"
    echo "Enter IP address of Raspberry Pi to copy script to: "
    read ip
    ssh $ip "mkdir -p $utils_script_dir"
    scp $utils_script_path $ip:$utils_script_path
    ssh $ip "bash $utils_script_path install"
}

# EXPERIMENTAL: Copy this OS image to another Raspberry IN PLACE
utils_copy_os_image_to_pi() {
    echo "Please ensure you have remote control of the target Raspberry Pi"
    echo "Enter IP address of Raspberry Pi to copy OS image to: "
    read ip

    # Alter fstab entry so that the other Pi will reboot with SD card read only
    ssh $ip "sudo sed -i 's/noatime/noatime,ro/g' /etc/fstab"
    if [ $? -ne 0 ]; then echo "SSH failed"; exit $?; fi
    ssh $ip "sudo reboot"
    echo "Pi rebooting in read only mode..."
    
    # Wait for it to come back up
    sleep 60
    
    # Prepare target for instant reboot
    ssh $ip "sudo bash -c 'echo 1 > /proc/sys/kernel/sysrq'"
    
    # Sync local filesystem so that it is intact
    sync
    
    # We can now write the image to the other Pi
    echo "Copying image..."
    sudo pv /dev/mmcblk0 | ssh $ip 'sudo bash -c "cat > /dev/mmcblk0"'
    
    # Reboot magically
    ssh $ip "sudo bash -c 'echo b > /proc/sysrq-trigger'" &
    echo "Pi rebooting with new image..."
}

# Start DHCP server role so other pi's can obtain IP addresses
utils_start_dhcp_server() {
    sudo sed -i "s/iface eth0 inet dhcp/iface eth0 inet static\naddress $dhcp_server_ip\nnetmask 255.255.255.0/g" /etc/network/interfaces
    sudo ifdown eth0
    sudo sleep 1
    sudo ifup eth0
    sudo sed -i 's/DHCPD_ENABLED="no"/DHCPD_ENABLED="yes"/g' /etc/default/udhcpd
    sudo service udhcpd start
    echo "DHCP server started and will ALSO be enabled after reboot"
}

# Stop DHCP server role
utils_stop_dhcp_server() {
    sudo service udhcpd stop
    sudo sed -i 's/DHCPD_ENABLED="yes"/DHCPD_ENABLED="no"/g' /etc/default/udhcpd
    # This will hard to write, forgive me...
    sudo perl -0007 -i -pe "s{iface eth0 inet static\naddress $dhcp_server_ip\nnetmask 255.255.255.0}{iface eth0 inet dhcp}gsmi" /etc/network/interfaces
    sudo ifdown eth0
    sleep 1
    sudo ifup eth0     # This cause problems when no DHCP servers are available (it will hang)
    echo "DHCP server permanently disabled"
}

# Get the IP in CIDR notation i.e. 192.168.1.7/24
utils_get_local_ip_cidr() {
    ip=$(ip addr show eth0 | grep inet | awk '{print $2}')
    echo $ip
}

# Get the IP by itself i.e. 192.168.1.7
utils_get_local_ip() {
    ip=$(hostname -I)
    echo $ip
}

# Uses nmap to look for other pis on this subnet
# Human readable output, usage: utils_find_pis
# Machine readable list usage:  utils_find_pis ip_list
utils_find_pis() {
    local_ip_cidr=$(utils_get_local_ip_cidr)
    local_ip=$(utils_get_local_ip)

    if [ "$1" != "ip_list" ]; then
        echo "Looking for other pis"
        echo "Local IP: $local_ip"
    fi

    # Scan the subnet and save the output to a file
    sudo nmap -sn -sP $local_ip_cidr > ~/scan.txt

    while read line; do
        if [[ $line == Nmap\ scan* ]]; then
            ip=${line##* }
            ip=${ip/\(/}
            ip=${ip/\)/}

            read line

            # Local IP has entry with only two lines so we need to watch out for this
            if [ $ip != $local_ip ]; then
                read line
                mac=${line##*Address: }
                mac=${mac:0:17}
        
                if [ "$1" == "ip_list" ]; then
                    if [ ${mac:0:8} == "$mac_address_prefix" ]; then
                        echo $ip
                    fi
                else
                    echo "=============================="
                    echo "IP  Address: $ip"        
                    echo "MAC Address: $mac"

                    # It is a Raspberry Pi
                    if [ ${mac:0:8} == "$mac_address_prefix" ]; then
                        echo -e '--- \E[47;35m'"\033[1mThis is a Raspberry Pi\033[0m ---"
                    else
                        echo "This is another kind of device"
                    fi

                    echo "=============================="
                fi
            fi

        fi
    done < ~/scan.txt

    rm ~/scan.txt
}

# Do an Rsync operation to all visible Raspberry Pis
utils_batch_rsync() {
    utils_find_pis ip_list | while read ip; do
        echo "IP Address: $ip"
        rsync -avh --exclude ".*" ~ $ip:
    done
}
