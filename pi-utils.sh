#!/bin/bash

# Author: Chris Dell (cjdell@gmail.com) @cjdell

# USAGE: source ./pi-utils.sh
# All functions are prefixed with "util_" prefix (Use bash completion/tabbing to display them all)

# NOTICE: Make sure this is the correct path for this script
utils_script_path=~/Sync/pi-utils/pi-utils.sh

# This is the address this Pi will assume when acting as a DHCP server
dhcp_server_ip=192.168.0.10

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

    cat ~/.ssh/id_dsa.pub >> ~/.ssh/authorized_keys
}

# This will allow remote control of another Raspberry Pi
utils_setup_ssh_remote_control() {
    echo "Enter IP address of Raspberry Pi to gain access to: "
    read ip
    cat ~/.ssh/id_dsa.pub | ssh $ip 'cat >> /home/pi/.ssh/authorized_keys'

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
    ssh $ip 'mkdir -p /home/pi/Sync/pi-utils'
    scp $utils_script_path $ip:~/Sync/pi-utils/pi-utils.sh
}

# EXPERIMENTAL: Copy this OS image to another Raspberry IN PLACE
utils_copy_os_image_to_pi() {
    echo "Please ensure you have remote control of the target Raspberry Pi"
    echo "Enter IP address of Raspberry Pi to copy OS image to: "
    read ip
    
    # If we're cloning the OS then this security check can cause problems
    #rm ~/.ssh/known_hosts

    # Alter fstab entry so that the other Pi will reboot with SD card read only
    ssh $ip "sudo sed -i 's/noatime/noatime,ro/g' /etc/fstab"
    if [ $? -ne 0 ]; then echo "SSH failed"; exit $?; fi
    ssh $ip "sudo reboot"
    echo "Pi rebooting in read only mode..."
    sleep 60
    sync
    # We can now write the image to the other Pi
    echo "Copying image..."
    sudo pv /dev/mmcblk0 | gzip --fast | ssh $ip 'sudo bash -c "gzip -d > /dev/mmcblk0"'
    ssh $ip "sudo reboot"
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
utils_find_pis() {
    echo "Looking for other pis"

    local_ip_cidr=$(utils_get_local_ip_cidr)
    local_ip=$(utils_get_local_ip)

    echo "Local IP: $local_ip"

    # Scan the subnet and save the output to a file
    sudo nmap -sn -sP $local_ip_cidr > ~/scan.txt

    echo "=============================="
    while read line; do
        if [[ $line == Nmap\ scan* ]]; then
            ip=${line##* }
            ip=${ip/\(/}
            ip=${ip/\)/}

            read line

            # Local IP has entry with only two lines so we need to watch out for this
            if [ $ip != $local_ip ]; then
                echo "IP  Address: $ip"
                read line
                mac=${line##*Address: }
                mac=${mac:0:17}
                echo "MAC Address: $mac"

                if [ ${mac:0:8} == "B8:27:EB" ]; then
                    echo -e '--- \E[47;35m'"\033[1mThis is a Raspberry Pi\033[0m ---"
                else
                    echo "This is another kind of device"
                fi

                echo "=============================="
            fi

        fi
    done < ~/scan.txt

    rm ~/scan.txt
}

