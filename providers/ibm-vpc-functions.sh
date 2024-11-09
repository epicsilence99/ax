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
    boot_script="$5"
    zone="$(ibmcloud is zones --region $region | grep -v ID | awk '{print $1}' | head -1)"
    subnet_id="$(ibmcloud is subnets --zone $zone | grep -v ID | awk '{print $1}' | head -1)"
    vpc_id="$(ibmcloud is vpcs | grep -v ID | awk '{print $1}' | head -1)"
    key_id="$(ibmcloud is keys | grep -v ID | awk '{print $1}' | head -1)"

    ibmcloud is instance-create "$name" "$vpc_id" "$zone" "$profile" "$subnet_id" --image-id "$image_id" --key-ids "$key_id" --user-data "$boot_script" --wait 2>&1 >> /dev/null
    sleep 260
}

###################################################################
# deletes instance, if the second argument is set to "true", will not prompt
# used by axiom-rm
#
delete_instance() {
    name="$1"
    force="$2"
    id="$(instance_id $name)"
    if [ "$force" == "true" ]
    then
        ibmcloud is instance-delete "$id" --force --output json >/dev/null 2>&1
    else
        ibmcloud is instance-delete "$id" --output json
    fi
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
    instances | jq -r ".[] | select(.name==\"$host\") | .primary_network_interface.primary_ipv4_address"
}

# used by axiom-select axiom-ls
instance_list() {
    instances | jq -r '.[].name'
}

# used by axiom-ls
instance_pretty() {
    data=$(instances)
    # number of instances
    instances=$(echo $data | jq -r '.[] | .name' | wc -l)

    hourly_cost=0
    for f in $(echo $data | jq -r '.[].profile'); do
        new=$(bc <<< "$hourly_cost + $f")
        hourly_cost=$new
    done
    totalhourly_Price=$hourly_cost

    vpc_hours_used=0
    for f in $(echo $data | jq -r '.[].created_at'); do
        # Convert created_at to timestamp and calculate hours used
        start=$(date -d "$f" +%s)
        now=$(date +%s)
        hours_used=$(bc <<< "scale=2; ($now - $start) / 3600")
        new=$(bc <<< "$vpc_hours_used + $hours_used")
        vpc_hours_used=$new
    done
    totalhours_used=$(printf "%.2f" $vpc_hours_used)

    # VPC does not have recurring monthly cost per instance, so setting it to 0
    monthly_cost=0

    header="Instance,Primary Ip,Zone,Memory,CPU,Status,Hours used,\$/H,\$/M"
    fields=".[] | [.name, .primary_network_interface.primary_ipv4_address, .zone.name, .memory, .vcpu_count, .status, (now - (.created_at | fromdate)) / 3600 | floor, (.profile | tonumber) ] | @csv"
    totals="_,_,_,_,Instances,$instances,Total Hours,$totalhours_used,\$$totalhourly_Price/hr,\$$monthly_cost/mo"

    # Data is sorted by default by field name
    data=$(echo $data | jq -r "$fields" | sed 's/^,/0,/; :a;s/,,/,0,/g;ta')
    (echo "$header" && echo "$data" && echo $totals) | sed 's/"//g' | column -t -s,
}

###################################################################
#  Dynamically generates axiom's SSH config based on your cloud inventory
#  Choose between generating the sshconfig using private IP details, public IP details or optionally lock
#  Lock will never generate an SSH config and only used the cached config ~/.axiom/.sshconfig
#  Used for axiom-exec axiom-fleet axiom-ssh
#
generate_sshconfig() {
    accounts=$(ls -l "$AXIOM_PATH/accounts/" | grep "json" | grep -v 'total ' | awk '{ print $9 }' | sed 's/\.json//g')
    current=$(readlink -f "$AXIOM_PATH/axiom.json" | rev | cut -d / -f 1 | rev | cut -d . -f 1)> /dev/null 2>&1
    instances="$(instances)"
    sshnew="$AXIOM_PATH/.sshconfig.new$RANDOM"
    echo -n "" > $sshnew
    echo -e "\tServerAliveInterval 60\n" >> $sshnew
    sshkey="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.sshkey')"
    echo -e "IdentityFile $HOME/.ssh/$sshkey" >> $sshnew
    generate_sshconfig="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.generate_sshconfig')"

    if [[ "$generate_sshconfig" == "private" ]]; then
        echo -e "Warning your SSH config generation toggle is set to 'Private' for account : $(echo $current)."
        echo -e "axiom will always attempt to SSH into the instances from their private backend network interface. To revert run: axiom-ssh --just-generate"
        for name in $(echo "$instances" | jq -r '.[].name')
        do
            ip=$(echo "$instances" | jq -r ".[] | select(.name==\"$name\") | .primary_network_interface.primary_ipv4_address")
            echo -e "Host $name\n\tHostName $ip\n\tUser op\n\tPort 2266\n" >> $sshnew
        done
        mv $sshnew  $AXIOM_PATH/.sshconfig

    elif [[ "$generate_sshconfig" == "cache" ]]; then
        echo -e "Warning your SSH config generation toggle is set to 'Cache' for account : $(echo $current)."
        echo -e "axiom will never attempt to regenerate the SSH config. To revert run: axiom-ssh --just-generate"

    else
        for name in $(echo "$instances" | jq -r '.[].name')
        do
            ip=$(echo "$instances" | jq -r ".[] | select(.name==\"$name\") | .primary_network_interface.primary_ipv4_address")
            echo -e "Host $name\n\tHostName $ip\n\tUser op\n\tPort 2266\n" >> $sshnew
        done
        mv $sshnew  $AXIOM_PATH/.sshconfig
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
			selected="$selected $(echo $droplets | jq -r '.[].hostname' | grep "$var")"
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
		selected="$selected $(echo $droplets | jq -r '.[].hostname' | grep -w "$query")"
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
    images=$(ibmcloud is images --output json | jq '.[] | select(.visibility == "private")')
    name=$(echo $images | jq -r ".[].name" | grep -wx "$query" | tail -n 1)
    id=$(echo $images | jq -r ".[] | select(.name==\"$name\") | .id")

    echo $id
}

###################################################################
# Manage snapshots
# used for axiom-images
#
get_snapshots() {
        ibmcloud is images --output json | jq '.[] | select(.visibility == "private")'
}

# axiom-images
delete_snapshot() {
 name=$1
 image_id=$(get_image_id "$name")
 ibmcloud is image-delete "$image_id"
}

# axiom-images
snapshots() {
        ibmcloud is images --output json | jq '.[] | select(.visibility == "private")'
}

# axiom-images
create_snapshot() {
    instance_id="$1"
    snapshot_name="$2"

    # Capture the snapshot
    ibmcloud is instance-create-snapshot "$instance_id" --name "$snapshot_name"
}

###################################################################
# Get data about regions
# used by axiom-regions
#
list_regions() {
    regions=$(ibmcloud is regions --output json | jq -r '.[].name' | tr '\n' ',')
}

regions() {
    regions=$(ibmcloud is regions --output json | jq -r '.[].name' | tr '\n' ',')
}

###################################################################
#  Manage power state of instances
#  Used for axiom-power
#
poweron() {
instance_name="$1"
force="$2"
instance_id=$(ibmcloud is instances --output json | jq -r ".[] | select(.name == \"$instance_name\") | .id")
if [ "$force" == "true" ];
then
ibmcloud is instance-action "$instance_id" start --force
else
ibmcloud is instance-action "$instance_id" start
fi
}

# axiom-power
poweroff() {
instance_name="$1"
force="$2"
instance_id=$(ibmcloud is instances --output json | jq -r ".[] | select(.name == \"$instance_name\") | .id")
if [ "$force" == "true" ];
then
ibmcloud is instance-action "$instance_id" stop --force
else
ibmcloud is instance-action "$instance_id" stop
fi
}

# axiom-power
reboot(){
instance_name="$1"
force="$2"
instance_id=$(ibmcloud is instances --output json | jq -r ".[] | select(.name == \"$instance_name\") | .id")
if [ "$force" == "true" ];
then
ibmcloud is instance-action "$instance_id" reboot --force
else
ibmcloud is instance-action "$instance_id" reboot
fi
}

# axiom-power axiom-images
instance_id() {
    name="$1"
    ibmcloud is instances --output json | jq -r ".[] | select(.name==\"$name\") | .id"
}
