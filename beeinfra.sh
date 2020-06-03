#!/usr/bin/env bash

set -euo pipefail

#/
#/ Usage: 
#/ ./beeinfra.sh ACTION [OPTION]
#/ 
#/ Description:
#/ Spinup local k8s infra and run beekeeper tests
#/ 
#/ Examples:
#/ ./beeinfra.sh 
#/ ./beeinfra.sh 
#/
#/ Actions:

# parse file and print usage text
usage() { grep '^#/' "$0" | cut -c4- ; exit 0 ; }
expr "$*" : ".*-h" > /dev/null && usage
expr "$*" : ".*--help" > /dev/null && usage

declare -x REPLICA="3"
declare -x DOMAIN="localhost"
declare -x REGISTRY="registry.${DOMAIN}:5000"
declare -x SKYDNS=""
declare -x REPO="ethersphere/bee"
declare -x HELM_SET_REPO="${REPO}"
declare -x CHART="${REPO}"
#declare -x CHART="./charts/bee"
declare -x NAMESPACE="bee"
declare -x RUN_TESTS=""
declare -x DNS_DISCO=""
declare -x ACTION=""
declare -x CHAOS=""
declare -x DESTROY=""
declare -x LOCAL=""
declare -x IMAGE_TAG="latest"

_revdomain() {
    for((i=$#;i>0;i--));do printf "%s/" ${!i}; done
}

# arch discovers the architecture for this system
_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    armv6*) ARCH="armv6";;
    aarch64) ARCH="arm64";;
    x86) ARCH="386";;
    x86_64) ARCH="amd64";;
    i686) ARCH="386";;
    i386) ARCH="386";;
  esac
}

# os discovers the operating system for this system
_os() {
  OS=$(uname|tr '[:upper:]' '[:lower:]')
}

_install_beekeeper() {
    echo "installing beekeeper..."
    _arch
    _os
    curl -Ls https://github.com/ethersphere/beekeeper/releases/download/"${1}"/beekeeper-"${OS}"-"${ARCH}" -o beekeeper
    chmod +x beekeeper
}

_check_beekeeper() {
    TAG=$(curl -s https://api.github.com/repos/ethersphere/beekeeper/releases/latest | jq -r .tag_name)
    if [[ -f "beekeeper" ]]; then
        VERSION=$(./beekeeper version 2>&1)
        if [[ "${VERSION%%-*}" !=  "${TAG##v}" ]]; then
            rm beekeeper
            _install_beekeeper "${TAG}"
        fi
    else
        _install_beekeeper "${TAG}"
    fi
}

_check_deps() {
    if ! grep -qE "docker|admin" <<< "$(id "$(whoami)")"; then
        if (( EUID != 0 )); then
            echo "$(whoami) not member of docker group..."
            exit 1
        fi
    fi
    if ! command -v jq &> /dev/null; then
        echo "jq is missing..."
        exit 1
    elif ! command -v curl &> /dev/null; then
        echo "curl is missing..."
        exit 1
    elif ! command -v kubectl &> /dev/null; then
        echo "curl is missing..."
        exit 1
    elif ! command -v helm &> /dev/null; then
        echo "curl is missing..."
        exit 1
    fi

    if ! command -v k3d &> /dev/null; then
        echo "k3d installing..."
        curl -s https://raw.githubusercontent.com/rancher/k3d/master/install.sh | bash
    fi
}

_prepare() {
    echo "starting k3d cluster..."
    k3d create --publish="80:80" --enable-registry --registry-name registry."${DOMAIN}" &> /dev/null &

    until k3d get-kubeconfig --name='k3s-default' &> /dev/null; do echo "waiting for the cluster..."; sleep 1; done

    KUBECONFIG="$(k3d get-kubeconfig --name='k3s-default')"
    export KUBECONFIG
    kubectl create ns "${NAMESPACE}" &> /dev/null
    helm repo add ethersphere https://ethersphere.github.io/helm &> /dev/null
    helm repo update &> /dev/null

    if [[ -n $CHAOS ]]; then
        _chaos
    fi

    until kubectl get svc traefik -n kube-system &> /dev/null; do echo "waiting for the kube-system..."; sleep 1; done

    if [[ -n $DNS_DISCO ]]; then
        kubectl get configmaps --namespace=kube-system coredns -o yaml | sed "s/reload$/reload 2s/" | kubectl apply -f - &> /dev/null
        kubectl create ns etcd &> /dev/null
        helm repo add bitnami https://charts.bitnami.com/bitnami &> /dev/null
        helm repo update &> /dev/null
        helm install etcd bitnami/etcd --namespace=etcd -f helm-values/etcd.yaml &> /dev/null
        until kubectl get svc etcd -n etcd &> /dev/null; do echo "waiting for the etcd..."; sleep 1; done
        until kubectl exec -ti etcd-0 -n etcd -- sh -c "curl http://127.0.0.1:2379/version" &> /dev/null; do echo "waiting for the etcd..."; sleep 1; done
        ETCD_IP=$(kubectl get svc etcd -n etcd -o=custom-columns=IP:.spec.clusterIP --no-headers)
        ## Configure cluster coredns to query etcd for custom domain
        kubectl get configmaps --namespace=kube-system coredns -o yaml | sed -e '/  Corefile: |/{r hack/Customfile' -e 'd' -e '}' | sed "s/{ETCD_IP}/${ETCD_IP}/; s/{DOMAIN}/${DOMAIN}/" | kubectl apply -f - &> /dev/null
        kubectl delete pod --namespace kube-system -l k8s-app=kube-dns &> /dev/null
        until [[ $(kubectl get pod --namespace kube-system -l k8s-app=kube-dns -o json | jq .items[0].status.containerStatuses[0].ready 2>/dev/null) == "true" ]]; do echo "waiting for the coredns..."; sleep 1; done
    fi
    echo "cluster running..."
}

_build() {
    cd "${GOPATH}"/src/github.com/ethersphere/bee
    make lint vet test-race
    docker build --network=host -t "${REGISTRY}"/"${REPO}":"${IMAGE_TAG}" .
    docker push "${REGISTRY}"/"${REPO}":"${IMAGE_TAG}"
    cd - &> /dev/null
}

# if dns-discovery is enabled delete all records because of the upgrade/uninstallation
_clear_dns() {
    SKYDNS=$(_revdomain ${DOMAIN/./ })
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl del --prefix /skydns/${SKYDNS} --user=root --password=secret" &> /dev/null
}

# after every pod is started get all values and populate dns
_populate_dns() {
    i="${1}"
    SKYDNS=$(_revdomain ${DOMAIN/./ })
    # shellcheck disable=SC1117,SC2059
    MOD=$(printf "\x6$((i % 4 + 1))")
    UNDERLAY_TCP=$(curl -s bee-"${i}"-debug.${DOMAIN}/addresses | jq -r '.underlay | .[] | [match("\/ip4\/(192.168|10.|172.1[6789].|172.2[0-9].|172.3[01].).*\/tcp\/\\d{1,5}\/p2p\/[a-zA-Z0-9]*")] | .[] | .string')
    UNDERLAY_UDP=$(curl -s bee-"${i}"-debug.${DOMAIN}/addresses | jq -r '.underlay | .[] | [match("\/ip4\/(192.168|10.|172.1[6789].|172.2[0-9].|172.3[01].).*\/udp\/\\d{1,5}\/quic\/p2p\/[a-zA-Z0-9]*")] | .[] | .string')
    IFS=/ read -r _ _ ip lay4 port prot hash <<< "${UNDERLAY_TCP}"
    IFS=/ read -r _ _ _ lay4_u _ prot1_u prot2_u _ <<< "${UNDERLAY_UDP}"
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}_dnsaddr/a${i} '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/'$MOD'.'$DOMAIN'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}${MOD}/_dnsaddr/a${i} '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/bee-'$i'.'$DOMAIN'/'$lay4'/'$port'/'$prot'/'$hash'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}${MOD}/_dnsaddr/b${i} '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/bee-'$i'.'$DOMAIN'/'$lay4_u'/'$port'/'$prot1_u'/'$prot2_u'/'$hash'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}bee-${i}/_dnsaddr/a${i} '{\"ttl\":1,\"text\":\"dnsaddr=/ip4/'$ip'/'$lay4'/'$port'/'$prot'/'$hash'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}bee-${i}/_dnsaddr/b${i} '{\"ttl\":1,\"text\":\"dnsaddr=/ip4/'$ip'/'$lay4_u'/'$port'/'$prot1_u'/'$prot2_u'/'$hash'\"}' --user=root --password=secret" &> /dev/null
}

_helm() {
    if [[ -n $DNS_DISCO ]]; then
        _clear_dns
    fi
    LAST_BEE=$((REPLICA-1))
    if [[ $ACTION == "upgrade" ]]; then
        BEES=$(seq $LAST_BEE -1 0)
    else
        BEES=$(seq 0 1 $LAST_BEE)
    fi
    helm "${1}" bee -f helm-values/bee.yaml "${CHART}" --namespace "${NAMESPACE}" --set image.repository="${HELM_SET_REPO}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" &> /dev/null

    for i in ${BEES}; do
        echo "waiting for the bee-${i}..."
        until [[ "$(curl -s bee-"${i}"-debug."${DOMAIN}"/readiness | jq -r .status 2>/dev/null)" == "ok" ]]; do
            sleep .1
        done
        if [[ -n $DNS_DISCO ]]; then
            _populate_dns "${i}"
        fi
        # sleep 2
    done
}

_helm_uninstall() {
    helm uninstall bee --namespace "${NAMESPACE}" #&> /dev/null

    if [[ -n $DNS_DISCO ]]; then
        _clear_dns
    fi
    echo "uninstalling bee pods.."    
}

_helm_on_delete() {
    if [[ -n $DNS_DISCO ]]; then
        _clear_dns
    fi
    helm upgrade bee -f helm-values/bee.yaml "${CHART}" --namespace "${NAMESPACE}" --set image.repository="${HELM_SET_REPO}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" &> /dev/null
    for ((i=0; i<REPLICA; i++)); do
        kubectl delete pod --namespace "${NAMESPACE}" bee-"${i}" &> /dev/null
        echo "waiting for the bee-${i}..."
        until [[ "$(curl -s bee-"${i}"-debug."${DOMAIN}"/readiness | jq -r .status 2>/dev/null)" == "ok" ]]; do
            sleep .1
        done
        if [[ -n $DNS_DISCO ]]; then
            _populate_dns "${i}"
        fi
        sleep 3
    done
}

_helm_upgrade_check() {
    if ! helm get values bee -n "${NAMESPACE}" -o json &> /dev/null; then
        echo "no release, use install..."
        exit 1
    fi
    STRATEGY=$(helm get values bee -n "${NAMESPACE}" -o json | jq -r .updateStrategy.type)
    if [[ $STRATEGY == "OnDelete" ]]; then
        _helm_on_delete
    else
        _helm upgrade
    fi
}

_chaos() {
    echo "installing chaos-mesh..."
    if [ ! -d "chaos-mesh" ]; then
        git clone https://github.com/pingcap/chaos-mesh.git &> /dev/null
    fi
    cd chaos-mesh &> /dev/null
    echo "apply crds for chaos-mesh..."
    kubectl apply -f manifests/crd.yaml &> /dev/null
    kubectl create ns chaos-testing &> /dev/null
    echo "install chaos-mesh operator..."
    helm install chaos-mesh helm/chaos-mesh --namespace=chaos-testing --set chaosDaemon.runtime=containerd --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock &> /dev/null
    echo "installed chaos-mesh..."
    cd .. &> /dev/null
}

_test() {
    _check_beekeeper
    echo "executing beekeeper tests..."
    sleep 5
    ./beekeeper check fullconnectivity --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}"
    ./beekeeper check pingpong --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}"
    ./beekeeper check pushsync --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}" --upload-node-count "${REPLICA}" --chunks-per-node 3
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then

    _check_deps

    while [[ $# -gt 0 ]]; do
        key="$1"

        case "${key}" in
#/   install    helm install bee
            install)
                ACTION="install"
                shift
            ;;
#/   upgrade    helm upgrade bee
            upgrade)
                ACTION="upgrade"
                shift
            ;;
#/   uninstall  helm uninstall bee
            uninstall)
                ACTION="uninstall"
                shift
            ;;
#/   test       run only tests
            test)
                ACTION="test"
                shift
            ;;
# chaos will install chaos-mesh https://github.com/pingcap/chaos-mesh
#/   chaos    install chaos-mesh
            chaos)
                ACTION="chaos"
                shift
            ;;
#/   destroy    destroy k3d cluster
            destroy)
                DESTROY="true"
                ACTION="destroy"
                shift
            ;;
#/
#/ Options:
#/   -d, --domain fqdn  set domain (default is localhost)
            -d|--domain)
                DOMAIN="${2}"
                shift 2
            ;;
#/   -r, --replica n    set number of bee replicas (default is 3)
            -r|--replica)
                REPLICA="${2}"
                shift 2
            ;;
#/   --test             run beekeeper tests at the end (default is false)
            --test)
                RUN_TESTS="true"
                shift
            ;;
#/   --chaos            run beekeeper chaoss at the end (default is false)
            --chaos)
                CHAOS="true"
                shift
            ;;
#/   --dns-disco        enable dns-discovery infra for bee (default is false)
            --dns-disco)
                DNS_DISCO="true"
                shift
            ;;
#/   --local            use local bee code, build it and deploy it (default is false)
            --local)
                HELM_SET_REPO="${REGISTRY}"/"${REPO}"
                LOCAL="true"
                shift
            ;;
#/   -h, --help         display this help message
            *)
                usage
            ;;
        esac
    done

    if [[ -z $ACTION ]]; then
        usage
    fi

    if [[ $ACTION == "test" ]]; then
        _test
        exit 0
    fi

    if [[ -n $DESTROY ]]; then
        echo "destroying k3d cluster..."
        k3d d &> /dev/null
        exit 0
    fi

    if [[ $ACTION == "chaos" ]]; then
        _chaos
        exit 0
    fi

    if k3d ls &> /dev/null; then
        echo "cluster running..."
    else
        _prepare
    fi

    if [[ -n $LOCAL ]] && [[ ! $ACTION == "uninstall" ]]; then
        IMAGE_TAG=$(date +%s)
        _build
    fi

    if [[ $ACTION == "upgrade" ]]; then
        _helm_upgrade_check
    elif [[ $ACTION == "uninstall" ]]; then
        _helm_uninstall
    else
        _helm "${ACTION}"
    fi

    if [[ -n $RUN_TESTS ]] && [[ ! $ACTION == "uninstall" ]]; then
        _test
    fi
fi
