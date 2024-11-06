#!/bin/bash

AXIOM_PATH="$HOME/.axiom"
source "$AXIOM_PATH/interact/includes/vars.sh"

region=""
provider=""
profile=""
ibm_cloud_api_key=""
vpc=""
zone=""

BASEOS="$(uname)"
case $BASEOS in
'Linux')
    BASEOS='Linux'
    ;;
'FreeBSD')
    BASEOS='FreeBSD'
    alias ls='ls -G'
    ;;
'WindowsNT')
    BASEOS='Windows'
    ;;
'Darwin')
    BASEOS='Mac'
    ;;
'SunOS')
    BASEOS='Solaris'
    ;;
'AIX') ;;
*) ;;
esac


installed_version=$(ibmcloud version 2>/dev/null | cut -d ' ' -f 2 | cut -d + -f 1 | head -n 1)

# Check if the installed version matches the recommended version
if [[ "$(printf '%s\n' "$installed_version" "$IBMCloudCliVersion" | sort -V | head -n 1)" != "$IBMCloudCliVersion" ]]; then
    echo -e "${Yellow}ibmcloud cli is either not installed or version is lower than the recommended version in ~/.axiom/interact/includes/vars.sh${Color_Off}"

    if [[ $BASEOS == "Mac" ]]; then
        # macOS installation/update
        echo -e "${BGreen}Installing/updating ibmcloud-cli on macOS...${Color_Off}"
        whereis brew
        if [ ! $? -eq 0 ] || [[ ! -z ${AXIOM_FORCEBREW+x} ]]; then
            echo -e "${BGreen}Installing Homebrew...${Color_Off}"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        else
            echo -e "${BGreen}Checking for Homebrew... already installed.${Color_Off}"
        fi
        echo -e "${BGreen}Installing ibmcloud-cli...${Color_Off}"
        curl -fsSL https://clis.cloud.ibm.com/install/osx | sh
        echo -e "${BGreen}Installing ibmcloud vpc plugin...${Color_Off}"
        ibmcloud plugin install vpc-infrastructure -q -f
    elif [[ $BASEOS == "Linux" ]]; then
        if uname -a | grep -qi "Microsoft"; then
            OS="UbuntuWSL"
        else
            OS=$(lsb_release -i | awk '{ print $3 }')
            if ! command -v lsb_release &> /dev/null; then
                OS="unknown-Linux"
                BASEOS="Linux"
            fi
        fi
        if [[ $OS == "Arch" ]] || [[ $OS == "ManjaroLinux" ]]; then
            echo "Needs Conversation for Arch or ManjaroLinux"
        elif [[ $OS == "Ubuntu" ]] || [[ $OS == "Debian" ]] || [[ $OS == "Linuxmint" ]] || [[ $OS == "Parrot" ]] || [[ $OS == "Kali" ]] || [[ $OS == "unknown-Linux" ]] || [[ $OS == "UbuntuWSL" ]]; then
            echo -e "${BGreen}Installing ibmcloud-cli on Linux...${Color_Off}"
            curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
            echo -e "${BGreen}Installing ibmcloud vpc plugin...${Color_Off}"
            ibmcloud plugin install vpc-infrastructure -q -f
        elif [[ $OS == "Fedora" ]]; then
            echo "Needs Conversation for Fedora"
        fi
    fi

    echo "ibmcloud-cli updated to version $IBMCloudCliVersion."
else
    echo "ibmcloud-cli is already at or above the recommended version $IBMCloudCliVersion."
fi

# Install IBM Cloud Packer Plugin
echo -e "${BGreen}Installing IBM Cloud Packer Builder Plugin${Color_Off}"
packer plugins install github.com/IBM/ibmcloud

function apikeys {
    echo -e -n "${Green}Create an IBM Cloud IAM API key (for ibmcloud cli) here: https://cloud.ibm.com/iam/apikeys (required): \n>> ${Color_Off}"
    read ibm_cloud_api_key
    while [[ "$ibm_cloud_api_key" == "" ]]; do
        echo -e "${BRed}Please provide a valid IBM Cloud API key.${Color_Off}"
        read ibm_cloud_api_key
    done
    ibmcloud login --apikey=$ibm_cloud_api_key --no-region
}

function create_apikey {
    echo -e -n "${Green}Creating an IAM API key for this profile \n>> ${Color_Off}"
    name="axiom-$(date +%FT%T%z)"
    key_details=$(ibmcloud iam api-key-create "$name" --output json)
    ibm_cloud_api_key=$(echo "$key_details" | jq -r .apikey)
    ibmcloud login --apikey=$ibm_cloud_api_key --no-region
}

function specs {
    echo -e -n "${BGreen}Printing available resource groups...\n${Color_Off}"
    ibmcloud resource groups
    echo -e -n "${BGreen}Please enter the resource groups to use (press enter for 'Default'): \n>> ${Color_Off}"
    read resource_group
    resource_group=${resource_group:-Default}

    echo -e -n "${Green}Printing available regions..\n${Color_Off}"
    ibmcloud regions
    echo -e -n "${BGreen}Please enter your default region (press enter for 'us-south'): \n>> ${Color_Off}"
    read region
    region=${region:-us-south}
    ibmcloud target -r $region -g $resource_group

    echo -e -n "${Green}Printing available zones in region selected..\n${Color_Off}"
    ibmcloud is zones
    echo -e -n "${BGreen}Please enter your default zone in region (press enter for 'us-south-1'): \n>> ${Color_Off}"
    read zone
    zone=${zone:-us-south-1}

    echo -e -n "${BGreen}Printing available instance profiles in zone/region...\n${Color_Off}"
    ibmcloud is instance-profiles
    echo -e -n "${BGreen}Please enter instance profile for your device to use (press enter for 'bx2-2x8'): \n>> ${Color_Off}"
    read profile
    profile=${profile:-bx2-2x8}
}

function setVPC {
    echo -e -n "${Green}Printing IBM Cloud VPCs ${Color_Off}"
    ibmcloud is vpcs
    echo -e -n "${Green}What VPC would you like to use? (press enter to create a new one): \n>> ${Color_Off}"
    read vpc
    if [[ "$vpc" == "" ]]; then
     name="axiom-$(date +%m-%d-%H-%M-%S-%1N)"
     new_vpc_data=$(ibmcloud is vpcc $name --output json)
     echo -e -n "${Green}Created VPC${Color_Off}"
     echo $new_vpc_data | jq
     vpc=$(echo $new_vpc_data | jq -r .id)
    else
     vpc=$vpc
   fi

}

function setprofile {
    data="{\"ibm_cloud_api_key\":\"$ibm_cloud_api_key\",\"default_size\":\"$profile\",\"resource_group\":\"$resource_group\",\"region\":\"$region\",\"zone\":\"$zone\",\"provider\":\"ibm-vpc\",\"vpc\":\"$vpc\"}"
    echo -e "${BGreen}Profile settings below:${Color_Off}"
    echo $data | jq ' .ibm_cloud_api_key = "********"'
    echo -e "${BWhite}Press enter to save these to a new profile, type 'r' to start over.${Color_Off}"
    read ans
    if [[ "$ans" == "r" ]]; then
        $0
        exit
    fi
    echo -e -n "${BWhite}Please enter your profile name (e.g. 'ibm-vpc'):\n>> ${Color_Off}"
    read title
    title=${title:-ibm-vpc}
    echo $data | jq > "$AXIOM_PATH/accounts/$title.json"
    echo -e "${BGreen}Saved profile '$title' successfully!${Color_Off}"
    $AXIOM_PATH/interact/axiom-account $title
}

prompt="Choose how to authenticate to IBM Cloud:"
PS3=$prompt
types=("SSO" "Username & Password" "API Keys")
select opt in "${types[@]}"
do
    case $opt in
        "SSO")
            echo "Attempting to authenticate with SSO!"
            ibmcloud login --no-region --sso
            create_apikey
            specs
            setVPC
            setprofile
            break
            ;;
        "Username & Password")
            ibmcloud login --no-region
            create_apikey
            specs
            setVPC
            setprofile
            break
            ;;
        "API Keys")
            apikeys
            specs
            setVPC
            setprofile
            break
            ;;
        *)
            echo "Invalid option $REPLY"
            ;;
    esac
done
