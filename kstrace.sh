#!/usr/bin/env bash

if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "This script requires BASH v4+"
    exit 1
fi

NAMESPACE=default
CONTEXT=$(kubectl config current-context)
while getopts ":n:c:" opt; do
    case $opt in
        n)
            NAMESPACE=$OPTARG
            ;;
        c)
            CONTEXT=$OPTARG
            ;;
        \?)
            echo "Invalid Option -$OPTARG"
            echo "Usage: $0 [-c context] [-n namespace] pod-name"
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument."
            echo "Usage: $0 [-c context] [-n namespace] pod-name"
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))
if [ ${1:-nope} == "nope" ]; then
    echo "Usage: $0 [-c context] [-n namespace] pod-name"
    exit 1
fi
POD=$1
NODE=$(kubectl --context $CONTEXT -n $NAMESPACE get po $POD -o json | jq -r '.spec.nodeName')

function get-containers() {
    if [[ $(kubectl get po --context $CONTEXT -n $NAMESPACE $POD -o json | jq -r '.spec.containers | length') -eq 1 ]]; then
        TARGET_CONTAINER=$(kubectl get po --context $CONTEXT -n $NAMESPACE $POD -o json | jq -r '.spec.containers[0].name')
    elif [[ $(kubectl get po --context $CONTEXT -n $NAMESPACE $POD -o json | jq -r '.spec.containers | length') -gt 1 ]]; then
        CONTAINER_LIST=( $(kubectl get po --context $CONTEXT -n $NAMESPACE $POD -o json | jq -r '.spec.containers[].name') )
    else
        echo "Unable to retrieve container list for target pod"
        exit 1;
    fi
}

function choose-containers() {
    x=0
    for container in ${CONTAINER_LIST[@]}; do
        printf "$x: $container\t\n"
        x=$(( $x + 1 ))
    done
    echo "Which container do you wish to strace?" && read TARGET_CONTAINER_SELECTION
    TARGET_CONTAINER=${CONTAINER_LIST[$TARGET_CONTAINER_SELECTION]%$'\r'}
}

function get-child-pids() {
    HAS_CHILDREN="false"
    DOCKER_ID=$(kubectl --context $CONTEXT -n $NAMESPACE get po $POD -o json | jq -r --arg "CONTAINER" "$TARGET_CONTAINER" '.status.containerStatuses | map(select(.name == $CONTAINER)) | .[].containerID' | sed 's#docker://##')
    PARENT_PID=$(ssh -o StrictHostKeyChecking=no -t $(grep "$NODE" ~/.ssh/config | awk '{print $2}') -- /usr/bin/docker inspect --format '{{.State.Pid}}' ${DOCKER_ID})
    PARENT_PID=${PARENT_PID%$'\r'}
    touch pid_temp
    ssh -o StrictHostKeyChecking=no $(grep "$NODE" ~/.ssh/config | awk '{print $2}') -- /bin/ps -o pid,cmd --ppid ${PARENT_PID} | tail -n +2 > pid_temp
    NUMBER_CHILDREN=$(wc -l < pid_temp)
    mapfile -t CHILDREN_PID < pid_temp
    rm pid_temp
    if [[ ! -z ${CHILDREN_PID} ]]; then
        HAS_CHILDREN="true"
    fi
}

function choose-child-pid() {
    x=0
    for child in "${CHILDREN_PID[@]}"; do
        printf "$x: $child\t\n"
        x=$(( $x + 1 ))
    done
    echo "Which child PID do you wish to strace?" && read TARGET_CHILD_PID_SELECTION
    CHILD_PID=${CHILDREN_PID[$TARGET_CHILD_PID_SELECTION]%$'\r'}
    CHILD_PID=$(echo $CHILD_PID | cut -d' ' -f1)
}

function strace-pid() {
    install-strace
    ssh  -o StrictHostKeyChecking=no -t $(grep "$NODE" ~/.ssh/config | awk '{print $2}') -- toolbox strace -p ${1%$'\r'}
}

function install-strace() {
echo "Installing strace..."
ssh  -o StrictHostKeyChecking=no -t $(grep "$NODE" ~/.ssh/config | awk '{print $2}') -- "toolbox apt-get update"
ssh  -o StrictHostKeyChecking=no -t $(grep "$NODE" ~/.ssh/config | awk '{print $2}') -- "toolbox apt-get install strace"
}

# MAIN
get-containers
if [[ ! -z ${CONTAINER_LIST} ]]; then
    choose-containers
fi

get-child-pids
if [[ $HAS_CHILDREN == "true" ]]; then
    printf "The target process has %d child processes, do you wish to trace the parent? y/N" $NUMBER_CHILDREN && read yn
    yn=${yn:-no}
    yn=$(echo $yn | tr '[:upper:]' '[:lower:]')
    if [[ $yn == "y" ]] || [[ $yn == "yes" ]]; then
        strace-pid $PARENT_PID
    elif [[ $yn == "n" ]] || [[ $yn == "no" ]]; then
        choose-child-pid
        strace-pid $CHILD_PID
    fi
elif [[ $HAS_CHILDREN == "false" ]]; then
    strace-pid $PARENT_PID
fi

