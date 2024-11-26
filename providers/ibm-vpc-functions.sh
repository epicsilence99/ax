#!/bin/bash

AXIOM_PATH="$HOME/.axiom"

###################################################################
#  Create Instance is likely the most important provider function :)
#  needed for init and fleet
#
create_instance() {
    name="$1"
    image_id="$2"
    profile="$3"
    region="$4"
    vpc_id="$(jq -r '.vpc' "$AXIOM_PATH"/axiom.json)"
    subnet_id="$(jq -r '.vpc_subnet' "$AXIOM_PATH"/axiom.json)"
    security_group_name="$(jq -r '.security_group' "$AXIOM_PATH"/axiom.json)"
    ibmcloud is instance-create "$name" "$vpc_id" "$region" "$profile" "$subnet_id" --image "$image_id" --pnac-vni-name "$name"-vni  --pnac-name "$name"-pnac --pnac-vni-sgs "$security_group_name" 2>&1 >>/dev/null && \
     ibmcloud is floating-ip-reserve "$name"-ip --vni "$name"-vni --in "$name" >>/dev/null
    sleep 260
}

###################################################################
# deletes instance, if the second argument is set to "true", will not prompt
# used by axiom-rm
#
delete_instance() {
    name="$1"
    force="$2"

    if [ "$force" != "true" ]; then
        read -p "Are you sure you want to delete instance '$name'? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Instance deletion aborted."
            return 1
        fi
    fi

    ibmcloud is instance-delete "$name" --force >/dev/null 2>&1
    ibmcloud is floating-ip-release "$name"-ip --force >/dev/null 2>&1
}

###################################################################
# Instances functions
# used by many functions in this file
instances() {
ibmcloud is instances --output json
}

# takes one argument, name of instance, returns raw IP address
# used by axiom-ls axiom-init
instance_ip() {
    host="$1"
    instances | jq -r '.[] | select(.name == "'"$host"'") | (
        [
            .primary_network_attachment?.virtual_network_interface?.floating_ips[0]?.address,
            .network_interfaces[]?.floating_ips[]?.address
        ] | map(select(. != null and . != "")) | .[0] // ""
    )' | head -n 1
}

# used by axiom-select axiom-ls
instance_list() {
    instances | jq -r '.[].name'
}

# used by axiom-ls
instance_pretty() {
    data=$(instances)
    current_time=$(date +%s)  # Get the current time in seconds since epoch
    header="Instance,Primary Ip,Backend Ip,Zone,Memory,CPU,Status,Profile,Active Hours"
    fields='.[] | [
        .name // "",
        (
            [
                .primary_network_attachment?.virtual_network_interface?.floating_ips[0]?.address,
                .network_interfaces[]?.floating_ips[]?.address
            ] | map(select(. != null and . != "")) | .[0] // ""
        ),
        .primary_network_interface?.primary_ip?.address // "",
        .zone?.name // "",
        .memory // "",
        .vcpu?.count // "",
        .status // "",
        .profile?.name // "",
        .created_at // ""
    ] | @csv'

    # Process and print data
    data=$(echo "$data" | jq -r "$fields" | sed 's/^,/0,/; :a;s/,,/,0,/g;ta')

    # Calculate active hours and total hours
    total_active_hours=0
    data=$(echo "$data" | while IFS=',' read -r name primary_ip backend_ip zone memory cpu status profile created_at; do
        created_ts=$(date -d "${created_at//\"/}" +%s)
        active_hours=$(( (current_time - created_ts) / 3600 ))
        total_active_hours=$((total_active_hours + active_hours))
        echo "$name,$primary_ip,$backend_ip,$zone,$memory,$cpu,$status,$profile,$active_hours"
    done)

    # Sum total active hours
    total_active_hours=$(echo "$data" | awk -F, '{sum+=$9} END {print sum}')

    # Totals
    totals="Total Instances: $instances,_,_,_,_,_,_,_,Total Active Hours: $total_active_hours"

    # Print header, data, and totals
    (echo "$header" && echo "$data" && echo "$totals") | sed 's/"//g' | column -t -s,
}

###################################################################
#  Dynamically generates axiom's SSH config based on your cloud inventory
#  Choose between generating the sshconfig using private IP details, public IP details or optionally lock
#  Lock will never generate an SSH config and only used the cached config ~/.axiom/.sshconfig
#  Used for axiom-exec axiom-fleet axiom-ssh
#
generate_sshconfig() {
    accounts=$(ls -l "$AXIOM_PATH/accounts/" | grep "json" | grep -v 'total ' | awk '{ print $9 }' | sed 's/\.json//g')
    current=$(readlink -f "$AXIOM_PATH/axiom.json" | rev | cut -d / -f 1 | rev | cut -d . -f 1) > /dev/null 2>&1
    instances="$(instances)"
    sshnew="$AXIOM_PATH/.sshconfig.new$RANDOM"
    echo -n "" > $sshnew
    echo -e "\tServerAliveInterval 60\n" >> $sshnew
    sshkey="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.sshkey')"
    echo -e "IdentityFile $HOME/.ssh/$sshkey" >> $sshnew
    generate_sshconfig="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.generate_sshconfig')"

    if [[ "$generate_sshconfig" == "private" ]]; then
        echo -e "Warning your SSH config generation toggle is set to 'Private' for account: $(echo $current)."
        echo -e "Axiom will always attempt to SSH into the instances from their private backend network interface. To revert, run: axiom-ssh --just-generate"
        for name in $(echo "$instances" | jq -r '.[].name'); do
            primary_ip=$(echo "$instances" | jq -r ".[] | select(.name==\"$name\") | .primary_network_attachment.virtual_network_interface.floating_ips[0]?.address // empty")
            network_ip=$(echo "$instances" | jq -r ".[] | select(.name==\"$name\") | .network_interfaces[].floating_ips[]?.address // empty")
            ip=$(echo -e "$primary_ip\n$network_ip" | grep -v "^$" | head -n 1)
            ip=${ip:-"null"}  # Assign "null" if both IPs are empty
            echo -e "Host $name\n\tHostName $ip\n\tUser op\n\tPort 2266\n" >> $sshnew
        done
        mv $sshnew $AXIOM_PATH/.sshconfig

    elif [[ "$generate_sshconfig" == "cache" ]]; then
        echo -e "Warning your SSH config generation toggle is set to 'Cache' for account: $(echo $current)."
        echo -e "Axiom will never attempt to regenerate the SSH config. To revert, run: axiom-ssh --just-generate"

    else
        for name in $(echo "$instances" | jq -r '.[].name'); do
            primary_ip=$(echo "$instances" | jq -r ".[] | select(.name==\"$name\") | .primary_network_attachment.virtual_network_interface.floating_ips[0]?.address // empty")
            network_ip=$(echo "$instances" | jq -r ".[] | select(.name==\"$name\") | .network_interfaces[].floating_ips[]?.address // empty")
            ip=$(echo -e "$primary_ip\n$network_ip" | grep -v "^$" | head -n 1)
            ip=${ip:-"null"}  # Assign "null" if both IPs are empty
            echo -e "Host $name\n\tHostName $ip\n\tUser op\n\tPort 2266\n" >> $sshnew
        done
        mv $sshnew $AXIOM_PATH/.sshconfig
    fi
}

###################################################################
# takes any number of arguments, each argument should be an instance or a glob, say 'omnom*', returns a sorted list of instances based on query
# $ query_instances 'john*' marin39
# Resp >>  john01 john02 john03 john04 nmarin39
# used by axiom-ls axiom-select axiom-fleet axiom-rm axiom-power
#
query_instances() {
        droplets="$(instances)"
        selected=""

        for var in "$@"; do
                if [[ "$var" =~ "*" ]]
                then
                        var=$(echo "$var" | sed 's/*/.*/g')
                        selected="$selected $(echo $droplets | jq -r '.[].name' | grep "$var")"
                else
                        if [[ $query ]];
                        then
                                query="$query\|$var"
                        else
                                query="$var"
                        fi
                fi
        done

        if [[ "$query" ]]
        then
                selected="$selected $(echo $droplets | jq -r '.[].name' | grep -w "$query")"
        else
                if [[ ! "$selected" ]]
                then
                        echo -e "${Red}No instance supplied, use * if you want to delete all instances...${Color_Off}"
                        exit
                fi
        fi

        selected=$(echo "$selected" | tr ' ' '\n' | sort -u)
        echo -n $selected
}

###################################################################
#
# used by axiom-fleet axiom-init
get_image_id() {
    query="$1"
    images=$(ibmcloud is images --visibility private --output json)
    id=$(echo "$images" | jq -r '.[] | select(.name=="'"$query"'") | .id')

    echo "$id"
}

###################################################################
# Manage snapshots
# used for axiom-images
#
get_snapshots(){
    ibmcloud is snapshots
}

# axiom-images
delete_snapshot() {
    name=$1
    force="$2"
    snapshot_id=$(snapshots | jq -r '.[] | select(.name=="'"$name"'") | .id')
    if [ "$force" == "true" ]
    then
    ibmcloud is snapshot-delete "$snapshot_id" --force
    else
    ibmcloud is snapshot-delete "$snapshot_id"
    fi
}

# axiom-images
snapshots() {
        ibmcloud is snapshots --output json
}

# axiom-images
create_snapshot() {
       instance="$1"
       snapshot_name="$2"
       volume_id=$(ibmcloud is instances --output json | jq -r '.[] | select(.name=="'"$instance"'") | .volume_attachments[0].volume.id')
      ibmcloud is snapshot-create --volume "$volume_id" --name "$snapshot_name"
}

###################################################################
# Get data about regions
# used by axiom-regions
#
list_regions() {
    ibmcloud is regions --output json | jq -r '.[].name' | tr '\n' ','
}
regions() {
    ibmcloud is regions --output json | jq -r '.[].name' | tr '\n' ','
}

###################################################################
#  Manage power state of instances
#  Used for axiom-power
#
poweron() {
instance_name="$1"
instance_id=$(ibmcloud is instances --output json | jq -r ".[] | select(.name == \"$instance_name\") | .id")
ibmcloud is instance-start "$instance_id"
}

# axiom-power
poweroff() {
instance_name="$1"
force="$2"
instance_id=$(ibmcloud is instances --output json | jq -r ".[] | select(.name == \"$instance_name\") | .id")
if [ "$force" == "true" ];
then
ibmcloud is instance-stop "$instance_id" --force
else
ibmcloud is instance-stop "$instance_id"
fi
}

# axiom-power
reboot(){
instance_name="$1"
force="$2"
instance_id=$(ibmcloud is instances --output json | jq -r ".[] | select(.name == \"$instance_name\") | .id")
if [ "$force" == "true" ];
then
ibmcloud is instance-reboot "$instance_id" --force
else
ibmcloud is instance-reboot "$instance_id"
fi
}

# axiom-power axiom-images
instance_id() {
    name="$1"
    ibmcloud is instances --output json | jq -r ".[] | select(.name==\"$name\") | .id"
}
